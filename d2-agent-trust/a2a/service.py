"""A2A receiver: SPIRE identity is authenticated separately from signed context."""
import base64, hashlib, json, subprocess, tempfile, time, urllib.request
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
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", private_key], input=f"{h}.{p}".encode(), capture_output=True, check=True).stdout
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
def verify_and_authorize(context, public_key, request, peer_spiffe, replay, now=None):
    now=time.time() if now is None else now
    try:
        h,p,s=context.split("."); claims=json.loads(_unb64(p)); valid=json.loads(_unb64(h)).get("alg")=="RS256"
        with tempfile.NamedTemporaryFile() as f:
            f.write(_unb64(s)); f.flush(); valid &= subprocess.run(["openssl","dgst","-sha256","-verify",public_key,"-signature",f.name],input=f"{h}.{p}".encode(),capture_output=True).returncode==0
    except Exception as exc: raise PermissionError("malformed authorization context") from exc
    required={"iss":ISSUER,"aud":AUDIENCE,"actor":PLANNER,"receiver":TRIAGE,"tenant":"acme","project":"payments","action":request.get("action"),"resource":request.get("resource"),"requestHash":request_hash(request)}
    if not valid or not valid_resource(request.get("resource")) or request.get("action") != "triage.analyze" or any(claims.get(k)!=v for k,v in required.items()): raise PermissionError("authorization context scope")
    if peer_spiffe != PLANNER or peer_spiffe != claims["actor"]: raise PermissionError("authenticated peer mismatch")
    if not (claims.get("nbf",now+1)<=now<claims.get("exp",0)) or not replay.consume(claims.get("jti"),claims.get("exp"),now): raise PermissionError("authorization context time/replay")
    return {"caller":peer_spiffe,"receiver":TRIAGE,"decision":"allow"}
def serve(public_key, port=8080, *, identity_validator=None, openbao_url=None, openbao_role="agent-trust-planner"):
    card=Path(__file__).with_name("agent-card.json").read_bytes(); replay=ReplayStore()
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ("/.well-known/agent-card.json","/.well-known/agent.json","/agent-card.json"): self.send_error(404); return
            self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers(); self.wfile.write(card)
        def do_POST(self):
            if self.path != "/a2a": self.send_error(404); return
            try:
                length=int(self.headers["Content-Length"]); body=json.loads(self.rfile.read(length))
                context=self.headers["Authorization"].removeprefix("Bearer ")
                jwt_svid=self.headers["X-SPIFFE-JWT-SVID"]
                validator=identity_validator or (lambda token: validate_openbao_identity(openbao_url or "",token,openbao_role,PLANNER))
                decision=verify_and_authorize(context, public_key, body, validator(jwt_svid), replay)
                self.send_response(200); self.end_headers(); self.wfile.write(json.dumps(decision).encode())
            except (KeyError, ValueError, PermissionError): self.send_error(403)
        def log_message(self,*_): pass
    return ThreadingHTTPServer(("127.0.0.1",port),H)
