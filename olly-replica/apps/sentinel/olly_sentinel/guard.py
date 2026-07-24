"""LLM Guard client: the model-based scanner on the Olly -> Orbit A2A hop.

Defence in depth behind the deterministic redactor. The redactor (redact.py)
holds the secret/PII boundary by fixed pattern and always runs; this layer runs
LLM Guard's model scanners over the same text to catch the shapes a regex
cannot: a novel prompt injection, model-detected PII, a malicious URL in a
reply. It scans the message Olly is about to send to Orbit (/analyze/prompt) and
Orbit's reply (/analyze/output) and reports, per direction, whether the text is
valid plus the per-scanner risk scores.

Trust boundary this enforces: output from one agent is untrusted input to the
next. An instruction an attacker planted in a log line, which the redactor
carries as harmless data, is exactly what could steer Orbit if it rode across
the hand-off unscanned. The guard is where that steering is caught before Orbit
sees it.

Layering and failure model: the redactor is the hard control. The guard is a
second opinion, so its availability must not gate the pipeline. A scan that
actually runs and trips is a real block; a guard that is disabled or unreachable
lets the hand-off proceed (the text was already scrubbed) and the outage is
recorded on the decision bus. No fabricated verdicts: a result is only "ran"
when LLM Guard actually answered."""

import logging
from dataclasses import dataclass, field

from . import config

log = logging.getLogger("olly-sentinel")


@dataclass
class ScanResult:
    """One direction of a scan. ``ran`` is False when the guard was disabled or
    could not be reached, so a caller can tell "scanned and clean" from "not
    scanned"."""

    ran: bool
    is_valid: bool
    sanitized: str = ""
    scanners: dict = field(default_factory=dict)
    error: str = ""

    @property
    def tripped(self) -> bool:
        """A scan actually ran and the guard rejected the text."""
        return self.ran and not self.is_valid

    def flagged(self) -> list[str]:
        """Scanner names that returned a positive risk score, highest first."""
        scored = [
            (name, score) for name, score in self.scanners.items()
            if isinstance(score, (int, float)) and score > 0
        ]
        scored.sort(key=lambda kv: kv[1], reverse=True)
        return [name for name, _ in scored]

    def summary(self) -> str:
        """A short, renderable reason line naming the scanners that fired."""
        if not self.ran:
            return "scan skipped: " + (self.error or "guard disabled")
        flagged = self.flagged()
        if not flagged:
            return "clean"
        return ", ".join(f"{n} {self.scanners[n]:.2f}" for n in flagged)


def enabled() -> bool:
    return config.LLM_GUARD_ENABLED


async def _post(path: str, body: dict) -> dict:
    import httpx

    headers = {"Authorization": f"Bearer {config.LLM_GUARD_TOKEN}"}
    async with httpx.AsyncClient(timeout=config.LLM_GUARD_TIMEOUT) as client:
        resp = await client.post(f"{config.LLM_GUARD_URL}{path}", json=body, headers=headers)
        resp.raise_for_status()
        return resp.json() or {}


async def scan_input(text: str) -> ScanResult:
    """Scan a message with the input scanners (/analyze/prompt): Secrets,
    Anonymize (PII), PromptInjection, Toxicity, Gibberish."""
    if not enabled():
        return ScanResult(ran=False, is_valid=True)
    try:
        data = await _post("/analyze/prompt", {"prompt": text})
    except Exception as exc:  # noqa: BLE001 - guard is best-effort, redactor is the hard control
        log.info("llm-guard input scan unavailable, proceeding: %s", exc)
        return ScanResult(ran=False, is_valid=True, error=str(exc)[:200])
    return ScanResult(
        ran=True,
        is_valid=bool(data.get("is_valid", True)),
        sanitized=data.get("sanitized_prompt", "") or "",
        scanners=data.get("scanners", {}) or {},
    )


async def scan_output(prompt: str, output: str) -> ScanResult:
    """Scan a reply with the output scanners (/analyze/output): Sensitive (PII),
    MaliciousURLs, NoRefusal, Deanonymize, Toxicity, Gibberish."""
    if not enabled():
        return ScanResult(ran=False, is_valid=True)
    try:
        data = await _post("/analyze/output", {"prompt": prompt, "output": output})
    except Exception as exc:  # noqa: BLE001 - guard is best-effort, redactor is the hard control
        log.info("llm-guard output scan unavailable, proceeding: %s", exc)
        return ScanResult(ran=False, is_valid=True, error=str(exc)[:200])
    return ScanResult(
        ran=True,
        is_valid=bool(data.get("is_valid", True)),
        sanitized=data.get("sanitized_output", "") or "",
        scanners=data.get("scanners", {}) or {},
    )


async def health() -> dict:
    """Liveness/readiness probe for the Security Sandbox surface. Returns
    ``{"reachable": bool, "enabled": bool, "detail": str}``."""
    import httpx

    result = {"reachable": False, "enabled": config.LLM_GUARD_ENABLED, "detail": ""}
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{config.LLM_GUARD_URL}/healthz")
            result["reachable"] = resp.status_code == 200
            result["detail"] = resp.text[:120]
    except Exception as exc:  # noqa: BLE001
        result["detail"] = str(exc)[:120]
    return result
