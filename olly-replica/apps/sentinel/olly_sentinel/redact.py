"""Strip secret- and PII-shaped strings from text before it can reach an
enrichment payload, the decision bus, or a work note.

This is the deterministic control. A fixed set of patterns is applied to every
untrusted string the agent ingests (log lines, change records) and every string
it emits (RCA summary, probable cause, evidence timeline, decision reason). It
runs before anything is published, so a secret or a piece of PII that an SRE
happened to log never leaves the agent. It is not a model and cannot be talked
out of a match by injected text, which is the point: the regex pass is the layer
that holds even when the log line is hostile.

Two classes are covered, drawn from what the MCP read tools actually surface
(ELK app/infra/audit logs, drift change records, ServiceNow work notes):

  secrets - cloud access keys, vendor API tokens (GitHub, Slack, Google),
            bearer / JWT tokens, private-key blocks, and credentials embedded
            in connection strings.
  PII     - email addresses, phone numbers, national IDs (US SSN), and
            financial identifiers (payment card numbers, IBANs).

Payment card numbers are Luhn-checked so a batch id or a byte count that merely
looks card-shaped is not redacted. The safety suite plants one of each class in
the seeded logs and asserts none survives scrubbing.

Scope, stated honestly: this catches the shapes above and nothing more. It is a
strong deterministic first pass, not a full DLP engine - a novel secret format
or an unlabelled identifier can still slip through. That residual is exactly why
the demo pairs this pass with the LLM Guard scanner (Secrets + Anonymize +
PromptInjection) between Olly and Orbit as defence in depth: output from one
model is untrusted input to the next, and a single regex layer is not enough to
carry that trust boundary alone."""

import re

PLACEHOLDER = "[REDACTED]"

# --- Secrets ---------------------------------------------------------------

# Multi-line PEM private-key blocks. Run first, before any other pass fragments
# the block across a placeholder.
_PEM = re.compile(
    r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"
    r".*?-----END (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----",
    re.DOTALL,
)

# bearer <token> / Basic <base64> authorization values. Keyed forms run before
# the bare-token pass so the whole "Bearer eyJ..." is replaced as one redaction.
_BEARER = re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._\-+/=]{12,}")

# key = value credentials. The value is a single unquoted token; the keyword is
# preserved so the log line still reads (e.g. "password=[REDACTED]").
_KV = re.compile(
    r"(?i)\b("
    r"aws_secret_access_key|aws_access_key_id"
    r"|secret[_-]?access[_-]?key|access[_-]?key[_-]?id|access[_-]?key"
    r"|api[_-]?key|apikey|es_api_key"
    r"|client[_-]?secret|access[_-]?token|refresh[_-]?token|id[_-]?token"
    r"|password|passwd|pwd|passphrase|secret|token"
    r")\s*[=:]\s*([^\s\"';,]+)"
)

# Bare vendor tokens with a recognizable prefix, plus JWTs. Matched whole.
_TOKENS = re.compile(
    r"\b("
    r"AKIA[0-9A-Z]{16}"                      # AWS access key id
    r"|ASIA[0-9A-Z]{16}"                     # AWS temporary access key id
    r"|gh[pousr]_[A-Za-z0-9]{36,}"           # GitHub token
    r"|github_pat_[A-Za-z0-9_]{22,}"         # GitHub fine-grained PAT
    r"|xox[baprs]-[A-Za-z0-9-]{10,}"         # Slack token
    r"|AIza[0-9A-Za-z_\-]{35}"               # Google API key
    r"|sk-[A-Za-z0-9]{32,}"                  # OpenAI-style secret key
    r"|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"  # JWT
    r")\b"
)

# Credentials embedded in a connection string: scheme://user:PASSWORD@host.
_URL_CREDS = re.compile(r"(?i)([a-z][a-z0-9+.\-]*://[^/\s:@\"']+:)[^@\s\"']+@")

# --- PII -------------------------------------------------------------------

_EMAIL = re.compile(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b")
# NANP / E.164-ish: three groups with real separators, guarded against being a
# slice of a longer digit run (a batch id, a byte count, a timestamp).
_PHONE = re.compile(r"(?<!\d)(?:\+?\d{1,2}[ .\-]?)?\(?\d{3}\)?[ .\-]\d{3}[ .\-]\d{4}(?!\d)")
_SSN = re.compile(r"\b\d{3}-\d{2}-\d{4}\b")
_IBAN = re.compile(r"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b")
# Payment-card candidate: 13-19 digits with optional single space/dash
# separators. Confirmed with a Luhn check before it is treated as a PAN.
_PAN = re.compile(r"(?<!\d)(?:\d[ \-]?){12,18}\d(?!\d)")


def _luhn(digits: str) -> bool:
    """True if the digit string passes the Luhn checksum (the check every real
    payment card satisfies), used to reject card-shaped-but-random numbers."""
    total, alt = 0, False
    for ch in reversed(digits):
        d = ord(ch) - 48
        if alt:
            d *= 2
            if d > 9:
                d -= 9
        total += d
        alt = not alt
    return total % 10 == 0


def scrub(text: str) -> tuple[str, int]:
    """Return the cleaned text and the number of redactions applied.

    Passes run in precedence order: keyed secrets first (so a labelled or
    prefixed token is replaced whole and counted once), then connection-string
    credentials, then PII. Each pass only ever adds placeholders, so the count
    is a lower bound on the sensitive tokens removed."""
    total = 0

    def _sub(pattern, repl, s: str) -> str:
        nonlocal total
        out, n = pattern.subn(repl, s)
        total += n
        return out

    def _pan_sub(m: "re.Match[str]") -> str:
        # subn counts every match, but a card-shaped run that fails Luhn is not
        # a card, so count only the runs actually redacted.
        nonlocal total
        digits = re.sub(r"[ \-]", "", m.group(0))
        if 13 <= len(digits) <= 19 and _luhn(digits):
            total += 1
            return PLACEHOLDER
        return m.group(0)

    out = text
    out = _sub(_PEM, PLACEHOLDER, out)
    out = _sub(_BEARER, lambda m: f"{m.group(1)} {PLACEHOLDER}", out)
    out = _sub(_KV, lambda m: f"{m.group(1)}={PLACEHOLDER}", out)
    out = _sub(_TOKENS, PLACEHOLDER, out)
    out = _sub(_URL_CREDS, lambda m: f"{m.group(1)}{PLACEHOLDER}@", out)
    out = _sub(_IBAN, PLACEHOLDER, out)
    out = _PAN.sub(_pan_sub, out)
    out = _sub(_EMAIL, PLACEHOLDER, out)
    out = _sub(_PHONE, PLACEHOLDER, out)
    out = _sub(_SSN, PLACEHOLDER, out)
    return out, total
