"""Authentic adapter for the existing SPIRE agent CLI and Workload API socket."""
import os
import json
import re
import subprocess
from dataclasses import dataclass

_AUDIENCE = re.compile(r"^[A-Za-z0-9._:/-]{1,256}$")
_SPIFFE = re.compile(r"^spiffe://[^\s]+$")
_JWT = re.compile(r"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$")

@dataclass(frozen=True)
class JwtSvid:
    spiffe_id: str
    token: str

def workload_api_socket() -> str:
    path = os.environ.get("SPIRE_AGENT_SOCKET", "/run/spire/sockets/agent.sock")
    if not os.path.exists(path): raise RuntimeError("SPIRE Workload API socket unavailable")
    return path

def fetch_jwt_svid(audience: str, *, timeout: float = 5, runner=subprocess.run) -> JwtSvid:
    """Fetch exactly one JWT-SVID using installed ``spire-agent``; fail closed."""
    if not isinstance(audience, str) or not _AUDIENCE.fullmatch(audience):
        raise ValueError("invalid SPIRE JWT-SVID audience")
    if not 0 < timeout <= 30: raise ValueError("invalid SPIRE command timeout")
    result = runner(
        ["spire-agent", "api", "fetch", "jwt", "-socketPath", workload_api_socket(), "-audience", audience, "-output", "json"],
        capture_output=True, text=True, timeout=timeout, check=False,
    )
    if result.returncode or len(result.stdout) > 16384 or len(result.stderr) > 4096:
        raise RuntimeError("SPIRE JWT-SVID fetch failed")
    try:
        payload=json.loads(result.stdout)
        svids=payload.get("svids", payload.get("jwt_svids", [])) if isinstance(payload,dict) else payload
        if not isinstance(svids,list) or len(svids) != 1: raise ValueError("SVID count")
        item=svids[0]; spiffe=[item[k] for k in ("spiffeID","spiffe_id") if k in item]; tokens=[item[k] for k in ("svid","jwt_svid","token") if k in item]
    except (ValueError, TypeError, json.JSONDecodeError):
        raise RuntimeError("SPIRE output was not one JSON JWT-SVID") from None
    if len(spiffe) != 1 or len(tokens) != 1 or not _SPIFFE.fullmatch(spiffe[0]) or not _JWT.fullmatch(tokens[0]):
        raise RuntimeError("SPIRE output did not contain exactly one valid JWT-SVID")
    return JwtSvid(spiffe[0], tokens[0])
