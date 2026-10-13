"""A2A receiver: SPIRE identity is authenticated separately from signed context."""
import base64, hashlib, json, math, re, secrets, subprocess, tempfile, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from adapters.spire_workload_api import fetch_jwt_svid

ISSUER = "signalloom-platform-authz"; AUDIENCE = "agent-trust-triage"
PLANNER = "spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner"
TRIAGE = "spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/triage"
_JWT = re.compile(r"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$")
_ROLE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
_SPIFFE = re.compile(r"^spiffe://[^\s]+$")

def _b64(v): return base64.urlsafe_b64encode(v).rstrip(b"=").decode()
def _unb64(v): return base64.urlsafe_b64decode(v + "=" * (-len(v) % 4))
def request_hash(request): return hashlib.sha256(json.dumps(request, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
def valid_resource(resource): return isinstance(resource,str) and len(resource) <= 128 and re.fullmatch(r"case/[A-Za-z0-9_-]+",resource)
def mint_authorization_context_fixture(private_key, claims):
    """Deterministic platform authorization-context fixture, never a SPIFFE proof."""
    h = _b64(b'{"alg":"RS256","typ":"JWT"}'); p = _b64(json.dumps(claims, sort_keys=True, separators=(",", ":")).encode())
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", private_key], input=f"{h}.{p}".encode(), capture_output=True, check=True, timeout=5.0).stdout
    return f"{h}.{p}.{_b64(sig)}"
class ReplayStore:
    """Bounded, expiry-aware replay cache; saturation fails closed."""
    def __init__(self, max_entries=10000): self.seen={}; self.max_entries=max_entries
    def consume(self, jti, expires_at=None, now=None):
        now = time.time() if now is None else now
        if isinstance(now, bool) or not isinstance(now, (int, float)) or not math.isfinite(now) or now <= 0:
            return False
        self.seen = {key: expiry for key, expiry in self.seen.items() if expiry > now}
        if not isinstance(jti, str) or not (0 < len(jti) <= 512) or jti in self.seen:
            return False
        if isinstance(expires_at, bool) or not isinstance(expires_at, (int, float)) or not math.isfinite(expires_at) or expires_at <= now or len(self.seen) >= self.max_entries:
            return False
        self.seen[jti] = expires_at
        return True
def validate_openbao_identity(url, jwt_svid, role, expected_spiffe, opener=urllib.request.urlopen):
    """Real code seam: OpenBao JWT login validates a SPIRE JWT-SVID exact role."""
    if not isinstance(url, str) or not (url.startswith("http://") or url.startswith("https://")) or any(c in url for c in " \r\n\t"):
        raise PermissionError("invalid OpenBao URL")
    if not isinstance(role, str) or not _ROLE.fullmatch(role):
        raise PermissionError("invalid OpenBao role")
    if not isinstance(jwt_svid, str) or not _JWT.fullmatch(jwt_svid):
        raise PermissionError("invalid JWT-SVID format")
    if not isinstance(expected_spiffe, str) or not _SPIFFE.fullmatch(expected_spiffe):
        raise PermissionError("invalid expected SPIFFE ID")
    req = urllib.request.Request(f"{url.rstrip('/')}/v1/auth/jwt/login", data=json.dumps({"role":role,"jwt":jwt_svid}).encode(), headers={"Content-Type":"application/json"}, method="POST")
    try: response = json.loads(opener(req, timeout=5).read())
    except Exception as exc: raise PermissionError("OpenBao JWT validation failed") from exc
    auth = response.get("auth",{})
    if not isinstance(auth.get("client_token"),str) or not auth["client_token"]: raise PermissionError("OpenBao did not authenticate JWT-SVID")
    try:
        parts = jwt_svid.split('.')
        if len(parts) != 3: raise ValueError("malformed JWT")
        subject = json.loads(_unb64(parts[1])).get("sub")
    except Exception as exc: raise PermissionError("JWT-SVID subject unreadable") from exc
    if not isinstance(subject, str) or not _SPIFFE.fullmatch(subject):
        raise PermissionError("invalid JWT-SVID subject format")
    if subject != expected_spiffe: raise PermissionError("OpenBao identity scope")
    return expected_spiffe
def authenticate_spiffe_via_openbao(audience, openbao_url, role, expected_spiffe, *, fetcher=fetch_jwt_svid, opener=urllib.request.urlopen):
    """Live integration seam: Workload API JWT-SVID then OpenBao exact-role login."""
    svid = fetcher(audience)
    if svid.spiffe_id != expected_spiffe: raise PermissionError("Workload API SPIFFE mismatch")
    return validate_openbao_identity(openbao_url, svid.token, role, expected_spiffe, opener)
def verify_and_authorize(context, public_key, request, peer_spiffe, replay, now=None, *, receiver_instance):
    now = time.time() if now is None else now
    if isinstance(now, bool) or not isinstance(now, (int, float)) or not math.isfinite(now) or now <= 0:
        raise PermissionError("invalid current time")
    if not isinstance(request, dict): raise PermissionError("malformed request payload")
    if not isinstance(context, str) or not context: raise PermissionError("missing authorization context")
    parts = context.split(".")
    if len(parts) != 3: raise PermissionError("malformed authorization context")
    h, p, s = parts
    try:
        header = json.loads(_unb64(h))
        claims = json.loads(_unb64(p))
        if not isinstance(header, dict) or not isinstance(claims, dict):
            raise PermissionError("malformed authorization context")
        if header.get("alg") != "RS256" or header.get("typ") != "JWT":
            raise PermissionError("invalid header algorithm or type")
        with tempfile.NamedTemporaryFile() as f:
            f.write(_unb64(s))
            f.flush()
            res = subprocess.run(["openssl","dgst","-sha256","-verify",public_key,"-signature",f.name],input=f"{h}.{p}".encode(),capture_output=True,timeout=5.0)
            if res.returncode != 0:
                raise PermissionError("signature verification failed")
    except PermissionError:
        raise
    except Exception as exc:
        raise PermissionError("malformed authorization context") from exc
    actor = claims.get("actor")
    receiver = claims.get("receiver")
    tenant = claims.get("tenant")
    project = claims.get("project")
    if not isinstance(actor, str) or not _SPIFFE.fullmatch(actor):
        raise PermissionError("authorization context actor invalid")
    if not isinstance(receiver, str) or not _SPIFFE.fullmatch(receiver):
        raise PermissionError("authorization context receiver invalid")
    if not isinstance(tenant, str) or not re.fullmatch(r"^[a-zA-Z0-9_-]{1,64}$", tenant):
        raise PermissionError("authorization context tenant invalid")
    if not isinstance(project, str) or not re.fullmatch(r"^[a-zA-Z0-9_-]{1,64}$", project):
        raise PermissionError("authorization context project invalid")
    required = {
        "iss": ISSUER, "aud": AUDIENCE, "actor": PLANNER, "receiver": TRIAGE,
        "instance": receiver_instance, "tenant": "acme", "project": "payments",
        "action": request.get("action"), "resource": request.get("resource"),
        "requestHash": request_hash(request)
    }
    if not valid_resource(request.get("resource")) or request.get("action") != "triage.analyze" or any(claims.get(k) != v for k, v in required.items()):
        raise PermissionError("authorization context scope")
    if peer_spiffe != PLANNER or peer_spiffe != claims.get("actor"):
        raise PermissionError("authenticated peer mismatch")
    nbf = claims.get("nbf")
    exp = claims.get("exp")
    if isinstance(nbf, bool) or not isinstance(nbf, (int, float)) or not math.isfinite(nbf) or nbf <= 0:
        raise PermissionError("authorization context time/replay")
    if isinstance(exp, bool) or not isinstance(exp, (int, float)) or not math.isfinite(exp) or exp <= 0:
        raise PermissionError("authorization context time/replay")
    if nbf >= exp or (exp - nbf) > 86400:
        raise PermissionError("authorization context time/replay")
    if not (nbf <= now < exp) or not replay.consume(claims.get("jti"), exp, now):
        raise PermissionError("authorization context time/replay")
    return {"caller": peer_spiffe, "receiver": TRIAGE, "decision": "allow"}
def serve(public_key, port=8080, *, identity_validator=None, openbao_url=None, openbao_role="agent-trust-planner", receiver_instance=None):
    card = Path(__file__).with_name("agent-card.json").read_bytes(); replay = ReplayStore(); instance = receiver_instance or secrets.token_urlsafe(16)
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _drain_body(self) -> bool:
            if not hasattr(self, "headers") or not self.headers:
                return True
            te = self.headers.get("Transfer-Encoding", "").lower()
            has_cl = "content-length" in [k.lower() for k in self.headers.keys()]
            if ("chunked" in te and has_cl) or (te and has_cl):
                self.close_connection = True
                return False
            if "chunked" in te:
                try:
                    total = 0
                    terminated = False
                    while total <= 1048576:
                        line = self.rfile.readline(1024)
                        if not line or not line.endswith(b"\n"):
                            self.close_connection = True
                            return False
                        chunk_len_str = line.split(b";")[0].strip()
                        if not chunk_len_str or not re.fullmatch(rb"[0-9a-fA-F]+", chunk_len_str):
                            self.close_connection = True
                            return False
                        try:
                            chunk_len = int(chunk_len_str, 16)
                        except ValueError:
                            self.close_connection = True
                            return False
                        if chunk_len < 0:
                            self.close_connection = True
                            return False
                        if chunk_len == 0:
                            trailer_count = 0
                            while trailer_count < 32:
                                trailer = self.rfile.readline(1024)
                                if not trailer or not trailer.endswith(b"\n"):
                                    self.close_connection = True
                                    return False
                                if trailer in (b"\r\n", b"\n"):
                                    break
                                trailer_count += 1
                            else:
                                self.close_connection = True
                                return False
                            terminated = True
                            break
                        total += chunk_len
                        if total > 1048576:
                            self.close_connection = True
                            return False
                        rem = chunk_len
                        while rem > 0:
                            b = self.rfile.read(min(rem, 65536))
                            if not b:
                                self.close_connection = True
                                return False
                            rem -= len(b)
                        crlf = self.rfile.readline(4)
                        if crlf not in (b"\r\n", b"\n"):
                            self.close_connection = True
                            return False
                    if not terminated:
                        self.close_connection = True
                        return False
                except Exception:
                    self.close_connection = True
                    return False
                return True

            raw_len = self.headers.get("Content-Length")
            if raw_len is None:
                return True
            try:
                length = int(raw_len.strip() if isinstance(raw_len, str) else (raw_len or 0))
            except (ValueError, TypeError):
                self.close_connection = True
                return False
            if length < 0 or length > 1048576:
                self.close_connection = True
                return False
            elif 0 < length <= 1048576:
                try:
                    rem = length
                    while rem > 0:
                        b = self.rfile.read(min(rem, 65536))
                        if not b:
                            self.close_connection = True
                            return False
                        rem -= len(b)
                except (OSError, ValueError):
                    self.close_connection = True
                    return False
            return True

        def _send_json(self, status: int, payload: dict, allow: str | None = None):
            try:
                self.send_response(status)
                if status in (204, 205, 304):
                    if allow:
                        self.send_header("Allow", allow)
                    if getattr(self, "close_connection", False):
                        self.send_header("Connection", "close")
                    self.end_headers()
                    return
                body = json.dumps(payload, separators=(',', ':')).encode()
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                if allow:
                    self.send_header("Allow", allow)
                if getattr(self, "close_connection", False):
                    self.send_header("Connection", "close")
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)
            except OSError:
                self.close_connection = True

        def do_OPTIONS(self):
            if not self._drain_body():
                self._send_json(400, {"error": "bad request: stream framing error or TE.CL conflict"})
                return
            path = (getattr(self, "path", None) or "/").split("?")[0].rstrip("/") or "/"
            if path in ("/health", "/healthz", "/readyz", "/challenge", "/.well-known/agent-card.json", "/.well-known/agent.json", "/agent-card.json"):
                self.send_response(204)
                self.send_header("Allow", "GET, HEAD, OPTIONS")
                self.send_header("Content-Length", "0")
                if getattr(self, "close_connection", False):
                    self.send_header("Connection", "close")
                self.end_headers()
                return
            if path == "/a2a":
                self.send_response(204)
                self.send_header("Allow", "POST, OPTIONS")
                self.send_header("Content-Length", "0")
                if getattr(self, "close_connection", False):
                    self.send_header("Connection", "close")
                self.end_headers()
                return
            self._send_json(404, {"error": "not found"})

        def do_GET(self):
            if not self._drain_body():
                self._send_json(400, {"error": "bad request: stream framing error or TE.CL conflict"})
                return
            path = (getattr(self, "path", None) or "/").split("?")[0].rstrip("/") or "/"
            if path in ("/health", "/healthz", "/readyz"):
                self._send_json(200, {"status": "ok"})
                return
            if path == "/challenge":
                self._send_json(200, {"instanceNonce": instance})
                return
            if path == "/a2a":
                self._send_json(405, {"error": "method not allowed"}, allow="POST, OPTIONS")
                return
            if path not in ("/.well-known/agent-card.json", "/.well-known/agent.json", "/agent-card.json"):
                self._send_json(404, {"error": "not found"})
                return
            try:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(card)))
                if getattr(self, "close_connection", False):
                    self.send_header("Connection", "close")
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(card)
            except OSError:
                self.close_connection = True

        def do_HEAD(self):
            if not self._drain_body():
                self._send_json(400, {"error": "bad request: stream framing error or TE.CL conflict"})
                return
            path = (getattr(self, "path", None) or "/").split("?")[0].rstrip("/") or "/"
            if path in ("/health", "/healthz", "/readyz"):
                self._send_json(200, {"status": "ok"})
                return
            if path == "/challenge":
                self._send_json(200, {"instanceNonce": instance})
                return
            if path == "/a2a":
                self._send_json(405, {"error": "method not allowed"}, allow="POST, OPTIONS")
                return
            if path not in ("/.well-known/agent-card.json", "/.well-known/agent.json", "/agent-card.json"):
                self._send_json(404, {"error": "not found"})
                return
            try:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(card)))
                if getattr(self, "close_connection", False):
                    self.send_header("Connection", "close")
                self.end_headers()
            except OSError:
                self.close_connection = True

        def do_POST(self):
            path = (getattr(self, "path", None) or "/").split("?")[0].rstrip("/") or "/"
            if path in ("/health", "/healthz", "/readyz", "/challenge", "/.well-known/agent-card.json", "/.well-known/agent.json", "/agent-card.json"):
                if not self._drain_body():
                    self._send_json(400, {"error": "bad request: stream framing error or TE.CL conflict"})
                    return
                self._send_json(405, {"error": "method not allowed"}, allow="GET, HEAD, OPTIONS")
                return
            if path != "/a2a":
                if not self._drain_body():
                    self._send_json(400, {"error": "bad request: stream framing error or TE.CL conflict"})
                    return
                self._send_json(404, {"error": "not found"})
                return
            te = self.headers.get("Transfer-Encoding", "").lower()
            has_cl = "content-length" in [k.lower() for k in self.headers.keys()]
            if (te and has_cl) or ("chunked" in te and has_cl):
                self.close_connection = True
                self._send_json(400, {"error": "unsupported Transfer-Encoding or TE.CL conflict"})
                return
            if te:
                self.close_connection = True
                self._send_json(400, {"error": "unsupported Transfer-Encoding"})
                return
            raw_len = self.headers.get("Content-Length")
            if raw_len is None:
                self.close_connection = True
                self._send_json(400, {"error": "missing Content-Length"})
                return
            try:
                length = int(raw_len.strip())
            except ValueError:
                self.close_connection = True
                self._drain_body()
                self._send_json(400, {"error": "invalid Content-Length"})
                return
            if length <= 0 or length > 1048576:
                if length < 0 or length > 1048576:
                    self.close_connection = True
                self._drain_body()
                self._send_json(400, {"error": "Content-Length out of range"})
                return
            try:
                raw_body = self.rfile.read(length)
                if len(raw_body) < length:
                    self.close_connection = True
                    self._send_json(400, {"error": "truncated request body"})
                    return
                body = json.loads(raw_body)
            except (OSError, ValueError, json.JSONDecodeError):
                self.close_connection = True
                self._send_json(400, {"error": "invalid JSON"})
                return
            if not isinstance(body, dict):
                self._send_json(400, {"error": "body must be an object"})
                return
            try:
                auth = self.headers.get("Authorization", "")
                if not auth.startswith("Bearer "):
                    self._send_json(403, {"error": "forbidden"})
                    return
                context = auth.removeprefix("Bearer ").strip()
                if not context or len(context) > 16384:
                    self._send_json(403, {"error": "empty or oversized authorization context"})
                    return
                jwt_svid = self.headers.get("X-SPIFFE-JWT-SVID")
                if not jwt_svid or not jwt_svid.strip() or len(jwt_svid.strip()) > 16384:
                    self._send_json(403, {"error": "missing or oversized SPIFFE JWT-SVID"})
                    return
                jwt_svid = jwt_svid.strip()
                validator = identity_validator or (lambda token: validate_openbao_identity(openbao_url or "",token,openbao_role,PLANNER))
                decision = verify_and_authorize(context, public_key, body, validator(jwt_svid), replay, receiver_instance=instance)
                self._send_json(200, decision)
            except (KeyError, ValueError, AttributeError, PermissionError):
                self._send_json(403, {"error": "forbidden"})

        def _handle_unsupported_method(self):
            if not self._drain_body():
                self._send_json(400, {"error": "bad request: stream framing error or TE.CL conflict"})
                return
            path = (getattr(self, "path", None) or "/").split("?")[0].rstrip("/") or "/"
            cmd = getattr(self, "command", "") or ""
            if path in ("/health", "/healthz", "/readyz", "/challenge", "/.well-known/agent-card.json", "/.well-known/agent.json", "/agent-card.json"):
                self._send_json(405, {"error": f"method {cmd} not allowed on {path}"}, allow="GET, HEAD, OPTIONS")
                return
            if path == "/a2a":
                self._send_json(405, {"error": f"method {cmd} not allowed on {path}"}, allow="POST, OPTIONS")
                return
            self._send_json(404, {"error": f"no route {cmd} {path}"})
        def send_error(self, code: int, message: str | None = None, explain: str | None = None):
            if not self._drain_body():
                self._send_json(400, {"error": "bad request: stream framing error or TE.CL conflict"})
                return
            path = (getattr(self, "path", None) or "/").split("?")[0].rstrip("/") or "/"
            cmd = getattr(self, "command", "") or ""
            if code in (405, 501):
                if path in ("/health", "/healthz", "/readyz", "/challenge", "/.well-known/agent-card.json", "/.well-known/agent.json", "/agent-card.json"):
                    self._send_json(405, {"error": f"method {cmd} not allowed on {path}"}, allow="GET, HEAD, OPTIONS")
                    return
                if path == "/a2a":
                    self._send_json(405, {"error": f"method {cmd} not allowed on {path}"}, allow="POST, OPTIONS")
                    return
                self._send_json(404, {"error": f"no route {cmd} {path}"})
                return
            msg = message or self.responses.get(code, ("error", ""))[0]
            self._send_json(code, {"error": msg})
        def do_PUT(self): self._handle_unsupported_method()
        def do_DELETE(self): self._handle_unsupported_method()
        def do_PATCH(self): self._handle_unsupported_method()
        def do_TRACE(self): self.send_error(501)
        def do_CONNECT(self): self.send_error(501)
        def log_message(self,*_): pass
    class ReusableThreadingHTTPServer(ThreadingHTTPServer):
        allow_reuse_address = True
    return ReusableThreadingHTTPServer(("127.0.0.1",port),H)
