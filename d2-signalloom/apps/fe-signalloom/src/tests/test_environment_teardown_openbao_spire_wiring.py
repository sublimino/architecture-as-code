# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_environment_teardown_openbao_spire_wiring.py
#
# Recovered from the stranded SLRC-P1 mission (environment_teardown_adapters.py,
# f5c140aa "harden teardown adapters fail-closed security"). On the base,
# environment_teardown_adapters.OpenBaoHTTPClient and SpireCLIClient had zero
# importers outside their own test file -- nothing in production ever built
# one. environment_teardown.py's own shred_openbao()/revoke_svid() already
# accept an explicit `client` kwarg, but every real caller (EnvironmentRegistry
# .teardown(), the CLI, the network-teardown API route) used to leave it as
# the default None, which reported success without verifying anything
# happened.
#
# This suite proves the opt-in real-provider path AND the fail-closed-by-
# default contract that replaced the old silent pass:
#   build_default_openbao_shred_client() / build_default_spire_revoke_client()
#     - return None when SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER is unset.
#     - build a real, verifying client when the operator opts in.
#   shred_openbao()/revoke_svid(), given that None:
#     - report StageOutcome.FAILED by default -- no provider means nothing
#       verifies the shred/revoke actually happened, so it is not reported
#       as complete.
#     - report StageOutcome.COMPLETED with "UNVERIFIED" in the detail only
#       when the caller explicitly sets SIGNALLOOM_TEARDOWN_ALLOW_UNVERIFIED=1
#       (demo/fixture escape hatch, never the default).
#   With a configured client, shred_openbao()/revoke_svid() genuinely fail
#   when the provider cannot prove the postcondition, instead of fabricating
#   StageOutcome.COMPLETED regardless of what the provider did.
# ==============================================================================
from __future__ import annotations

import pytest

from environment_teardown import (
    StageOutcome,
    _ConfiguredOpenBaoShredClient,
    _ConfiguredSpireRevokeClient,
    build_default_openbao_shred_client,
    build_default_spire_revoke_client,
    revoke_svid,
    shred_openbao,
)

H = "0123abcd"


class FakeBao:
    """Same shape as test_environment_teardown_adapters.FakeBao."""

    def __init__(self, *, survives=False, decrypt_fails=True):
        self.survives = survives
        self.decrypt_failure = decrypt_fails
        self.delete_called = False

    def delete_tenant_material(self, customer_hash, timeout):
        self.delete_called = True

    def key_exists(self, customer_hash, timeout):
        return self.survives

    def secret_exists(self, customer_hash, timeout):
        return self.survives

    def decrypt_fails(self, customer_hash, timeout):
        return self.decrypt_failure


class FakeSpire:
    """Same shape as test_environment_teardown_adapters.FakeSpire."""

    def __init__(self, entries):
        self.entries = list(entries)

    def list_entries(self, timeout):
        return list(self.entries)

    def delete_entry(self, entry_id, timeout):
        self.entries = [entry for entry in self.entries if entry["id"] != entry_id]


# ------------------------------------------------------------------------------
# Opt-in gating: None unless explicitly configured (zero blast radius)
# ------------------------------------------------------------------------------

def test_openbao_shred_client_builder_defaults_to_none(monkeypatch):
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER", raising=False)
    assert build_default_openbao_shred_client() is None


def test_spire_revoke_client_builder_defaults_to_none(monkeypatch):
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER", raising=False)
    assert build_default_spire_revoke_client() is None


def test_openbao_shred_client_builder_warns_and_returns_none_on_partial_config(monkeypatch):
    """Provider selected but env vars incomplete: fail closed to None, not a crash."""
    monkeypatch.setenv("SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER", "openbao-spire")
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_OPENBAO_URL", raising=False)
    assert build_default_openbao_shred_client() is None


def test_openbao_shred_client_builder_builds_real_client_when_configured(monkeypatch):
    monkeypatch.setenv("SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER", "openbao-spire")
    monkeypatch.setenv("SIGNALLOOM_TEARDOWN_OPENBAO_URL", "https://bao.internal:8200")
    monkeypatch.setenv("SIGNALLOOM_TEARDOWN_OPENBAO_TOKEN", "s.faketoken")
    monkeypatch.setenv("SIGNALLOOM_TEARDOWN_OPENBAO_TEST_CIPHERTEXT", "vault:v1:fake")
    client = build_default_openbao_shred_client()
    assert isinstance(client, _ConfiguredOpenBaoShredClient)


# ------------------------------------------------------------------------------
# Verified shred/revoke: the actual fail-closed behaviour, proven directly
# against the wrapper classes (no HTTP/CLI needed -- that's
# OpenBaoHTTPClient/SpireCLIClient's own job, already tested in
# test_environment_teardown_adapters.py).
# ------------------------------------------------------------------------------

def test_configured_openbao_shred_client_succeeds_when_postconditions_verified():
    bao = FakeBao(survives=False, decrypt_fails=True)
    _ConfiguredOpenBaoShredClient(bao).shred(H)
    assert bao.delete_called is True


def test_configured_openbao_shred_client_raises_when_key_survives():
    """The fail-closed guarantee: a provider that can't prove the key is gone
    must not let the caller believe the shred succeeded."""
    bao = FakeBao(survives=True, decrypt_fails=True)
    with pytest.raises(RuntimeError, match="postconditions unverified"):
        _ConfiguredOpenBaoShredClient(bao).shred(H)


def test_configured_spire_revoke_client_deletes_only_tenant_entries():
    spire = FakeSpire([
        {"id": "tenant", "spiffe_id": f"spiffe://signalloom.demo/ns/eap-{H}/sa/app"},
        {"id": "other", "spiffe_id": "spiffe://signalloom.demo/ns/eap-deadbeef/sa/app"},
    ])
    _ConfiguredSpireRevokeClient(spire).revoke(H)
    assert [e["id"] for e in spire.entries] == ["other"]


def test_configured_spire_revoke_client_raises_when_entry_survives():
    spire = FakeSpire([{"id": "stuck", "spiffe_id": f"spiffe://signalloom.demo/ns/eap-{H}/sa/app"}])
    spire.delete_entry = lambda entry_id, timeout: None  # delete is a no-op: entry "survives"
    with pytest.raises(RuntimeError, match="tenant SPIRE entries remain"):
        _ConfiguredSpireRevokeClient(spire).revoke(H)


# ------------------------------------------------------------------------------
# End-to-end through shred_openbao()/revoke_svid(): explicit client wins over
# the (unconfigured) builder, and a verifying client's failure surfaces as a
# real StageOutcome.FAILED instead of the unverified-default COMPLETED.
# ------------------------------------------------------------------------------

def test_shred_openbao_fails_closed_with_a_configured_client_that_cannot_verify(monkeypatch):
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER", raising=False)
    bad_client = _ConfiguredOpenBaoShredClient(FakeBao(survives=True))
    res = shred_openbao(H, client=bad_client)
    assert res.outcome is StageOutcome.FAILED
    assert "postconditions unverified" in res.detail


def test_shred_openbao_succeeds_with_a_configured_client_that_verifies(monkeypatch):
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER", raising=False)
    good_client = _ConfiguredOpenBaoShredClient(FakeBao(survives=False, decrypt_fails=True))
    res = shred_openbao(H, client=good_client)
    assert res.outcome is StageOutcome.COMPLETED


def test_revoke_svid_fails_closed_with_a_configured_client_that_cannot_verify(monkeypatch):
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER", raising=False)
    spire = FakeSpire([{"id": "stuck", "spiffe_id": f"spiffe://signalloom.demo/ns/eap-{H}/sa/app"}])
    spire.delete_entry = lambda entry_id, timeout: None
    res = revoke_svid(H, client=_ConfiguredSpireRevokeClient(spire))
    assert res.outcome is StageOutcome.FAILED
    assert "entries remain" in res.detail


def test_shred_openbao_unconfigured_default_now_fails_closed(monkeypatch):
    """Andy's fail-closed decision: the long-standing default (no provider, no
    explicit client, no opt-in) must never report a clean completion again --
    there is nothing backing the claim that anything was shredded. Every
    pre-existing caller that depended on the old silent pass
    (test_ordered_teardown_executes_all_five_stages_in_exact_order,
    EnvironmentRegistry.teardown() callers, etc.) has been updated to either
    configure a fake verifying provider or set the explicit unverified opt-in."""
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER", raising=False)
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_ALLOW_UNVERIFIED", raising=False)
    res = shred_openbao(H)
    assert res.outcome is StageOutcome.FAILED
    assert "SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER" in res.detail
    assert "SIGNALLOOM_TEARDOWN_ALLOW_UNVERIFIED" in res.detail


def test_revoke_svid_unconfigured_default_now_fails_closed(monkeypatch):
    """Same fail-closed contract as shred_openbao() above, for stage 3."""
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER", raising=False)
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_ALLOW_UNVERIFIED", raising=False)
    res = revoke_svid(H)
    assert res.outcome is StageOutcome.FAILED
    assert "SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER" in res.detail
    assert "SIGNALLOOM_TEARDOWN_ALLOW_UNVERIFIED" in res.detail


def test_shred_openbao_unverified_opt_in_completes_but_says_so(monkeypatch):
    """SIGNALLOOM_TEARDOWN_ALLOW_UNVERIFIED=1 is the loud, explicit opt-in for
    demo/fixture use: the stage reports COMPLETED (so a pipeline with no real
    OpenBao can still proceed) but the detail must say "UNVERIFIED", AND
    res.verified must be False -- machine-visible, not just free text, so a
    caller that only checks outcome/ok cannot read this as a clean,
    verified success."""
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER", raising=False)
    monkeypatch.setenv("SIGNALLOOM_TEARDOWN_ALLOW_UNVERIFIED", "1")
    res = shred_openbao(H)
    assert res.outcome is StageOutcome.COMPLETED
    assert "UNVERIFIED" in res.detail
    assert res.verified is False


def test_revoke_svid_unverified_opt_in_completes_but_says_so(monkeypatch):
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER", raising=False)
    monkeypatch.setenv("SIGNALLOOM_TEARDOWN_ALLOW_UNVERIFIED", "1")
    res = revoke_svid(H)
    assert res.outcome is StageOutcome.COMPLETED
    assert "UNVERIFIED" in res.detail
    assert res.verified is False


def test_shred_openbao_configured_provider_ignores_the_opt_in_flag(monkeypatch):
    """A configured provider keeps today's verified behaviour unchanged,
    regardless of whether the unverified opt-in happens to also be set."""
    monkeypatch.setenv("SIGNALLOOM_TEARDOWN_ALLOW_UNVERIFIED", "1")
    monkeypatch.setenv("SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER", "openbao-spire")
    monkeypatch.setenv("SIGNALLOOM_TEARDOWN_OPENBAO_URL", "https://bao.internal:8200")
    monkeypatch.setenv("SIGNALLOOM_TEARDOWN_OPENBAO_TOKEN", "s.faketoken")
    monkeypatch.setenv("SIGNALLOOM_TEARDOWN_OPENBAO_TEST_CIPHERTEXT", "vault:v1:fake")
    good_client = _ConfiguredOpenBaoShredClient(FakeBao(survives=False, decrypt_fails=True))
    res = shred_openbao(H, client=good_client)
    assert res.outcome is StageOutcome.COMPLETED
    assert "UNVERIFIED" not in res.detail
    assert res.verified is True
