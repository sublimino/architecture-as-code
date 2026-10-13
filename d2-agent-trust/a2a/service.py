"""A2A receiver: SPIRE identity is authenticated separately from signed context."""
import base64, hashlib, json, secrets, subprocess, tempfile, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from adapters.spire_workload_api import fetch_jwt_svid

ISSUER = "signalloom-platform-authz"; AUDIENCE = "agent-trust-triage"
PLANNER = "spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner"
TRIAGE = "spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/triage"
def _b64(v): return base64.urlsafe_b64encode(v).rstrip(b"=").decode()
def _unb64(v): return base64.urlsafe_b64decode(v + "=" * (-len(v) % 4))
def request_hash(request): return hashlib.sha256(json.dumps(request, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
def valid_resource(resource): return isinstance(resource,str) and len(resource) <= 128 and __import__('re').fullmatch(r"case/[A-Za-z0-9_-]+",resource)
def mint_authorization_context_fixture(private_key, claims):
    """Deterministic platform authorization-context fixture, never a SPIFFE proof."""
    h = _b64(b'{"alg":"RS256","typ":"JWT"}'); p = _b64(json.dumps(claims, sort_keys=True, separators=(",", ":")).encode())
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", private_key], input=f"{h}.{p}".encode(), capture_output=True, check=True, timeout=5.0).stdout
    return f"{h}.{p}.{_b64(sig)}"
class ReplayStore:
    """Bounded, expiry-aware replay cache; saturation fails closed."""
    def __init__(self, max_entries=10000): self.seen={}; self.max_entries=max_entries
    def consume(self, jti, expires_at=None, now=None):
        now=time.time() if now is None else now
        self.seen={key: expiry for key,expiry in self.seen.items() if expiry > now}
        if not isinstance(jti,str) or not jti or jti in self.seen: return False
        if not isinstance(expires_at,(int,float)) or expires_at <= now or len(self.seen) >= self.max_entries: return False
        self.seen[jti]=expires_at; return True
def validate_openbao_identity(url, jwt_svid, role, expected_spiffe, opener=urllib.request.urlopen):
    """Real code seam: OpenBao JWT login validates a SPIRE JWT-SVID exact role."""
    req=urllib.request.Request(f"{url.rstrip('/')}/v1/auth/jwt/login", data=json.dumps({"role":role,"jwt":jwt_svid}).encode(), headers={"Content-Type":"application/json"}, method="POST")
    try: response=json.loads(opener(req, timeout=5).read())
    except Exception as exc: raise PermissionError("OpenBao JWT validation failed") from exc
    auth=response.get("auth",{})
    if not isinstance(auth.get("client_token"),str) or not auth["client_token"]: raise PermissionError("OpenBao did not authenticate JWT-SVID")
    try: subject=json.loads(_unb64(jwt_svid.split('.')[1])).get("sub")
    except Exception as exc: raise PermissionError("JWT-SVID subject unreadable") from exc
    if subject != expected_spiffe: raise PermissionError("OpenBao identity scope")
    return expected_spiffe
def authenticate_spiffe_via_openbao(audience, openbao_url, role, expected_spiffe, *, fetcher=fetch_jwt_svid, opener=urllib.request.urlopen):
    """Live integration seam: Workload API JWT-SVID then OpenBao exact-role login."""
    svid=fetcher(audience)
    if svid.spiffe_id != expected_spiffe: raise PermissionError("Workload API SPIFFE mismatch")
    return validate_openbao_identity(openbao_url,svid.token,role,expected_spiffe,opener)
def verify_and_authorize(context, public_key, request, peer_spiffe, replay, now=None, *, receiver_instance):
    now=time.time() if now is None else now
    if not isinstance(request, dict): raise PermissionError("malformed request payload")
    try:
        h,p,s=context.split("."); claims=json.loads(_unb64(p)); valid=json.loads(_unb64(h)).get("alg")=="RS256"
        with tempfile.NamedTemporaryFile() as f:
            f.write(_unb64(s)); f.flush(); valid &= subprocess.run(["openssl","dgst","-sha256","-verify",public_key,"-signature",f.name],input=f"{h}.{p}".encode(),capture_output=True,timeout=5.0).returncode==0
    except Exception as exc: raise PermissionError("malformed authorization context") from exc
    required={"iss":ISSUER,"aud":AUDIENCE,"actor":PLANNER,"receiver":TRIAGE,"instance":receiver_instance,"tenant":"acme","project":"payments","action":request.get("action"),"resource":request.get("resource"),"requestHash":request_hash(request)}
    if not valid or not valid_resource(request.get("resource")) or request.get("action") != "triage.analyze" or any(claims.get(k)!=v for k,v in required.items()): raise PermissionError("authorization context scope")
    if peer_spiffe != PLANNER or peer_spiffe != claims["actor"]: raise PermissionError("authenticated peer mismatch")
    if not (claims.get("nbf",now+1)<=now<claims.get("exp",0)) or not replay.consume(claims.get("jti"),claims.get("exp"),now): raise PermissionError("authorization context time/replay")
    return {"caller":peer_spiffe,"receiver":TRIAGE,"decision":"allow"}
def serve(public_key, port=8080, *, identity_validator=None, openbao_url=None, openbao_role="agent-trust-planner", receiver_instance=None):
    card=Path(__file__).with_name("agent-card.json").read_bytes(); replay=ReplayStore(); instance=receiver_instance or secrets.token_urlsafe(16)
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split("?")[0].rstrip("/") or "/"
            if path in ("/health", "/healthz", "/readyz"):
                body = b'{"status":"ok"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if path == "/challenge":
                body=json.dumps({"instanceNonce":instance}).encode(); self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body); return
            if path == "/a2a":
                body = b'{"error":"method not allowed"}'
                self.send_response(405)
                self.send_header("Allow", "POST")
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if path not in ("/.well-known/agent-card.json","/.well-known/agent.json","/agent-card.json"): self.send_error(404); return
            self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(card))); self.end_headers(); self.wfile.write(card)
        def do_HEAD(self):
            path = self.path.split("?")[0].rstrip("/") or "/"
            if path in ("/health", "/healthz", "/readyz"):
                body = b'{"status":"ok"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                return
            if path == "/challenge":
                body = json.dumps({"instanceNonce": instance}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                return
            if path == "/a2a":
                body = b'{"error":"method not allowed"}'
                self.send_response(405)
                self.send_header("Allow", "POST")
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                return
            if path not in ("/.well-known/agent-card.json", "/.well-known/agent.json", "/agent-card.json"):
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(card)))
            self.end_headers()
        def do_POST(self):
            path = self.path.split("?")[0].rstrip("/") or "/"
            if path in ("/health", "/healthz", "/readyz", "/challenge", "/.well-known/agent-card.json", "/.well-known/agent.json", "/agent-card.json"):
                body = b'{"error":"method not allowed"}'
                self.send_response(405)
                self.send_header("Allow", "GET, HEAD")
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if path != "/a2a": self.send_error(404); return
            raw_len = self.headers.get("Content-Length")
            if raw_len is None: self.send_error(400); return
            try:
                length = int(raw_len.strip())
            except ValueError:
                self.send_error(400); return
            if length <= 0 or length > 1048576: self.send_error(400); return
            try:
                raw_body = self.rfile.read(length)
                body = json.loads(raw_body)
            except (ValueError, json.JSONDecodeError):
                self.send_error(400); return
            if not isinstance(body, dict): self.send_error(400); return
            try:
                auth = self.headers.get("Authorization", "")
                if not auth.startswith("Bearer "): self.send_error(403); return
                context = auth.removeprefix("Bearer ").strip()
                jwt_svid = self.headers.get("X-SPIFFE-JWT-SVID")
                if not jwt_svid: self.send_error(403); return
                validator = identity_validator or (lambda token: validate_openbao_identity(openbao_url or "",token,openbao_role,PLANNER))
                decision = verify_and_authorize(context, public_key, body, validator(jwt_svid), replay, receiver_instance=instance)
                resp_data = json.dumps(decision).encode()
                self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(resp_data))); self.end_headers(); self.wfile.write(resp_data)
            except (KeyError, ValueError, AttributeError, PermissionError): self.send_error(403)
        def _handle_unsupported_method(self):
            path = self.path.split("?")[0].rstrip("/") or "/"
            if path in ("/health", "/healthz", "/readyz", "/challenge", "/.well-known/agent-card.json", "/.well-known/agent.json", "/agent-card.json"):
                body = b'{"error":"method not allowed"}'
                self.send_response(405)
                self.send_header("Allow", "GET, HEAD")
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)
                return
            if path == "/a2a":
                body = b'{"error":"method not allowed"}'
                self.send_response(405)
                self.send_header("Allow", "POST")
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)
                return
            self.send_error(404)
        def do_PUT(self): self._handle_unsupported_method()
        def do_DELETE(self): self._handle_unsupported_method()
        def do_PATCH(self): self._handle_unsupported_method()
        def do_OPTIONS(self): self._handle_unsupported_method()
        def log_message(self,*_): pass
    class ReusableThreadingHTTPServer(ThreadingHTTPServer):
        allow_reuse_address = True
    return ReusableThreadingHTTPServer(("127.0.0.1",port),H)
