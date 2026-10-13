"""Authentic adapter for the existing SPIRE agent CLI and Workload API socket."""
import json
import math
import os
import re
import stat
import subprocess
from dataclasses import dataclass

_AUDIENCE = re.compile(r"^[A-Za-z0-9._:/-]{1,256}$")
_SPIFFE = re.compile(r"^spiffe://[^\s]+$")
_JWT = re.compile(r"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$")

@dataclass(frozen=True)
class JwtSvid:
    spiffe_id: str
    token: str

def workload_api_socket(stat_fn=None) -> str:
    path = os.environ.get("SPIRE_AGENT_SOCKET", "").strip() or "/run/spire/sockets/agent.sock"
    if not os.path.exists(path):
        raise RuntimeError(f"SPIRE Workload API socket unavailable: {path}")
    try:
        fn = stat_fn or os.stat
        st = fn(path)
        if hasattr(stat, "S_ISSOCK") and not stat.S_ISSOCK(st.st_mode):
            raise RuntimeError(f"SPIRE Workload API socket path is not a socket: {path}")
    except OSError as exc:
        raise RuntimeError(f"SPIRE Workload API socket inaccessible: {exc}") from exc
    return path

def fetch_jwt_svid(audience: str, *, timeout: float = 5, runner=subprocess.run, stat_fn=None) -> JwtSvid:
    """Fetch exactly one JWT-SVID using installed ``spire-agent``; fail closed."""
    if not isinstance(audience, str) or not _AUDIENCE.fullmatch(audience):
        raise ValueError("invalid SPIRE JWT-SVID audience")
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or not (0 < timeout <= 30):
        raise ValueError("invalid SPIRE command timeout")
    socket_path = workload_api_socket(stat_fn=stat_fn)
    try:
        result = runner(
            ["spire-agent", "api", "fetch", "jwt", "-socketPath", socket_path, "-audience", audience, "-output", "json"],
            capture_output=True, text=True, timeout=timeout, check=False,
        )
    except (subprocess.SubprocessError, OSError) as exc:
        raise RuntimeError(f"SPIRE command execution failed: {exc}") from exc
    if result.returncode:
        detail = (result.stderr or "").strip() or f"exit status {result.returncode}"
        raise RuntimeError(f"SPIRE JWT-SVID fetch failed: {detail}")
    if len(result.stdout) > 16384 or len(result.stderr) > 4096:
        raise RuntimeError("SPIRE JWT-SVID fetch failed: output bounds exceeded")
    try:
        payload = json.loads(result.stdout)
        svids = payload.get("svids", payload.get("jwt_svids", [])) if isinstance(payload, dict) else payload
        if not isinstance(svids, list) or len(svids) != 1: raise ValueError("SVID count")
        item = svids[0]
        if not isinstance(item, dict): raise ValueError("SVID item type")
        spiffe = [item[k] for k in ("spiffeID", "spiffe_id") if k in item]
        tokens = [item[k] for k in ("svid", "jwt_svid", "token") if k in item]
    except (ValueError, TypeError, json.JSONDecodeError):
        raise RuntimeError("SPIRE output was not one JSON JWT-SVID") from None
    if len(spiffe) != 1 or len(tokens) != 1 or not isinstance(spiffe[0], str) or not isinstance(tokens[0], str) or not _SPIFFE.fullmatch(spiffe[0]) or not _JWT.fullmatch(tokens[0]):
        raise RuntimeError("SPIRE output did not contain exactly one valid JWT-SVID")
    return JwtSvid(spiffe[0], tokens[0])
