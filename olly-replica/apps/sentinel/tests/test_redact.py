from olly_sentinel import redact

# The planted secrets and PII from the seed corpus must never survive scrubbing.
# Each case pairs an input line with the sensitive substrings that must be gone.
PLANTED = [
    # --- secrets ---
    (
        "gateway client initialized with aws_access_key_id=AKIAIOSFODNN7EXAMPLE "
        "aws_secret_access_key=wJalrXUtnFEMIbPxRfiCYEXAMPLEKEY",
        ["AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMIbPxRfiCYEXAMPLEKEY"],
    ),
    (
        "retrying stock-db with dsn=postgres://svc_inventory:Sup3rSecretPlantedPw!@stock-db:5432/stock connect_timeout=5",
        ["Sup3rSecretPlantedPw"],
    ),
    (
        "api key rotation completed, previous key es_api_key=b2xseS1wbGFudGVkLWtleTpkZW1v retired",
        ["b2xseS1wbGFudGVkLWtleTpkZW1v"],
    ),
    (
        "sidecar re-authenticated: authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
        "eyJzdWIiOiJzdmMtaW52ZW50b3J5In0.7f3adPLANTEDsig9Xy0ZqAmsk20aQb1cD2eF3",
        ["eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9", "7f3adPLANTEDsig9Xy0ZqAmsk20aQb1cD2eF3"],
    ),
    (
        "image promoted using registry credential ghp_R2d2PLANTED9aBcDeF1234567890xyzABCDEfg",
        ["ghp_R2d2PLANTED9aBcDeF1234567890xyzABCDEfg"],
    ),
    (
        "webhook posted with slack token xoxb-2417823490-1234567890-abcDEF123456ghiJKLmno",
        ["xoxb-2417823490-1234567890-abcDEF123456ghiJKLmno"],
    ),
    # --- PII ---
    (
        "break reported by account holder email=amara.okafor@example.com phone=+1-415-555-0142 ssn=123-45-6789",
        ["amara.okafor@example.com", "+1-415-555-0142", "123-45-6789"],
    ),
    (
        "remittance advice: cardholder pan=4111 1111 1111 1111 iban=GB29NWBK60161331926819 contact email=settlement.ops@example.com",
        ["4111 1111 1111 1111", "GB29NWBK60161331926819", "settlement.ops@example.com"],
    ),
]

# Operational lines an SRE actually needs. None carries a secret or PII, so the
# scrubber must leave every one untouched (no over-redaction, no lost signal).
CLEAN = [
    "db connection pool exhausted: timeout acquiring connection to positions-ledger-db after 5000ms (pool size 20, waiters 30)",
    "settlement worker OOMKilled mid EOD batch: oom_kill=true, memory limit 512Mi exceeded (rss=548Mi) batch=900000",
    "unhandled NullPointerException in AccountSummaryController.render: account object was null (build v2.4.1)",
    "node ip-10-0-3-14 under MemoryPressure=true, pod payments-api-settlement evicted",
    "config change applied: connection_pool.max=20 (was 50) actor=deploy-pipeline change=CHG0044821",
    "2026-07-17T13:58:00Z incident INC0010001 opened, container restarted 6 times exit_code=137",
]


def test_scrub_planted_secrets_and_pii():
    for text, leaks in PLANTED:
        out, n = redact.scrub(text)
        assert n > 0, f"no redactions applied to {text!r}"
        for leak in leaks:
            assert leak not in out, f"sensitive value {leak!r} survived scrubbing: {out!r}"


def test_pan_luhn_check_ignores_non_card_digit_runs():
    # A 16-digit batch id that fails the Luhn check is not a card and must stay.
    line = "reindex job processed batch id 1234567890123456 across 3 shards"
    out, n = redact.scrub(line)
    assert n == 0
    assert "1234567890123456" in out


def test_scrub_leaves_normal_logs_alone():
    for line in CLEAN:
        out, n = redact.scrub(line)
        assert n == 0, f"over-redacted operational line: {line!r} -> {out!r}"
        assert out == line
