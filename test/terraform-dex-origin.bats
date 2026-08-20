#!/usr/bin/env bats
#
# scripts/lib/dex-origin.sh — the one origin-injection mechanism.
#
# Dex has exactly ONE issuer and one registered callback list, so the demo can
# be published on exactly one origin at a time. Four access methods want to
# publish it (IAP tunnel, ngrok, Tailscale, Tailscale Funnel) and the failure
# mode when two of them collide is the worst one available: the loser's users
# get a login that fails behind a tunnel that reports healthy, so it presents as
# a broken application rather than as a configuration collision. Nothing logs an
# error. This suite is what makes that collision impossible to reach.
#
# Entirely offline. A stateful fake kubectl and flux stand in for the cluster
# (test/helpers/fake-cluster-cli.bash) — stateful because idempotence and the
# lease are both questions about what the PREVIOUS call wrote, and a forgetful
# stub cannot answer either.
#
# Registered by the `test/terraform-*.bats` glob in `make gcp-tf-validate`; see
# test/terraform-suite-registration.bats, which fails if that glob is ever
# replaced by a hand-maintained list.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export LIB="${REPO_ROOT}/scripts/lib/dex-origin.sh"
  export EXPOSE="${REPO_ROOT}/scripts/lib/expose.sh"
  export BASELINE="https://dashboard.osramp.acme.local:30754"
}

setup() {
  # Presence first, always. A correct test can run happily against a tree that
  # no longer contains the thing under test and report a pass — this repo has
  # already been bitten by exactly that, which is why every suite here asserts
  # its own subject exists before asserting anything about it.
  [ -f "$LIB" ]
  [ -x "$LIB" ]
  [ -f "$EXPOSE" ]

  load helpers/fake-cluster-cli.bash
  fake_cluster_install "$BATS_TEST_TMPDIR"

  # A freshly built cluster: the ConfigMap exists in all three namespaces and
  # has never had an origin published to it.
  fake_cluster_configmap flux-system
  fake_cluster_configmap inf-signalloom
  fake_cluster_configmap fe-signalloom

  export DEX_ORIGIN_OWNER="tester@testhost"
  NGROK="https://ab-12-34.ngrok-free.app"
  TSNET="https://nuc.taild4da3.ts.net"
}

# ── The mechanism exists and is wired in ─────────────────────────────

@test "the library exposes the documented verbs" {
  # A verb interface is the contract every access method codes against. If one
  # is renamed, the caller that used it fails at runtime on a cluster, not here.
  for verb in apply restore current holder status validate; do
    run "$LIB" "$verb" --nonsense-argument-that-cannot-be-valid
    # The usage block is what a missing verb produces; anything else means the
    # verb was dispatched, which is all this asserts.
    if [[ "$output" == *"Usage: "* ]]; then
      echo "verb '${verb}' is not dispatched — it fell through to usage"
      return 1
    fi
  done
}

@test "expose.sh delegates to the mechanism rather than patching in parallel" {
  # `make public` is in use and must behave identically, which it only can if
  # there is exactly ONE implementation. A second, private copy of the patch
  # logic in expose.sh would drift and reintroduce the collision.
  run grep -c 'dex-origin.sh' "$EXPOSE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]

  # The specific regression: expose.sh going back to patching the ConfigMap
  # itself. Asserted as a POSITIVE match on the offending shape so that
  # deleting the file cannot make it pass.
  local body; body="$(cat "$EXPOSE")"
  [ -n "$body" ]
  if [[ "$body" == *'kubectl patch configmap'* ]]; then
    echo "expose.sh patches the ConfigMap directly again — that is the second implementation"
    return 1
  fi
}

# ── Validation, pure and offline ─────────────────────────────────────

@test "every real access method's origin validates" {
  # The actual shapes in use, one per access method. A validator that rejects
  # one of them blocks a working access method at the door.
  #
  #   BASELINE               the resting origin the manifests default to
  #   http://localhost:8080  IAP, through the tunnel to the dashboard nginx
  #   ngrok / ts.net         the two TLS-terminating methods
  #
  # `http://34.89.1.2:31080` used to be in this list, for expose.sh's `nodeport`
  # strategy. It is now REFUSED on purpose — see the insecure-origin test below
  # — and that strategy has no caller anywhere in the repo.
  for origin in \
      "$BASELINE" \
      "http://localhost:8080" \
      "http://localhost:18080" \
      "http://127.0.0.1:8080" \
      "https://ab-12-34.ngrok-free.app" \
      "https://nuc.taild4da3.ts.net"; do
    run "$LIB" validate "$origin"
    if [ "$status" -ne 0 ]; then
      echo "rejected a legitimate origin: ${origin}"
      echo "$output"
      return 1
    fi
  done
}

@test "an insecure origin is refused on any host but loopback" {
  # nginx serves cleartext on 8080, so `http://` is genuinely correct for the
  # IAP path: the origin is loopback and the IAP tunnel is the confidentiality
  # boundary. The same shape on a routable host means Dex hands its
  # authorisation code, its ID token and every later bearer to the wire in the
  # clear, and the browser additionally drops the Secure session cookie — half
  # silent interception, half a login that will not stick.
  #
  # Refused rather than warned about, because no legitimate caller produces one:
  # Tailscale and Funnel get a real certificate from `tailscale serve`, ngrok
  # terminates TLS at its edge, and IAP is loopback.
  local bad=(
    "http://34.89.1.2:31080"
    "http://demo.example.com"
    "http://nuc.taild4da3.ts.net"
    "http://dashboard.osramp.acme.local:30754"
    "http://192.168.1.10:8080"
    "http://127x0x0x1"
  )
  local origin
  for origin in "${bad[@]}"; do
    run "$LIB" validate "$origin"
    if [ "$status" -eq 0 ]; then
      echo "accepted a cleartext origin on a routable host: '${origin}'"
      return 1
    fi
  done

  # Its OWN diagnostic, asserted separately from the rejection. Every one of
  # those is a WELL-FORMED origin, so the generic "expected scheme://host[:port]"
  # trailer would send a reader to check a shape that is already correct — and
  # they would retype the same URL and watch it be refused again.
  run "$LIB" validate "http://demo.example.com"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not loopback"* ]] || {
    echo "the refusal did not say what was wrong with the host: ${output}"
    return 1
  }
  [[ "$output" == *"cleartext"* ]] || {
    echo "the refusal did not say why cleartext is the problem: ${output}"
    return 1
  }

  # And the loopback exemption is real, not a claim in a comment. Without this
  # the whole rule could be "reject every http:// origin" and the IAP path would
  # be dead — a test that only checks refusals cannot tell those apart.
  run "$LIB" validate "http://localhost:8080"
  [ "$status" -eq 0 ] || {
    echo "loopback cleartext was refused, which kills the IAP path: ${output}"
    return 1
  }
  run "$LIB" validate "http://127.0.0.2:8080"
  [ "$status" -eq 0 ] || {
    echo "127.0.0.0/8 is loopback too; refusing it rejects a correct origin: ${output}"
    return 1
  }
}

@test "a malformed origin is rejected" {
  # Trailing slash first, because it is the one that does not look like an
  # error: it yields the issuer https://host//dex, which Dex serves happily and
  # every token consumer then rejects as a mismatched `iss`.
  local bad=(
    "https://x.example.com/"
    "https://x.example.com/dex"
    "https://x.example.com?a=b"
    "https://x.example.com#f"
    "https://user@x.example.com"
    "ftp://x.example.com"
    "x.example.com"
    ""
    "https://"
    "https://x.example.com:0"
    "https://x.example.com:99999"
    "https://x.example.com:abc"
    "https://a b.example.com"
    "https://-x.example.com"
  )
  for origin in "${bad[@]}"; do
    run "$LIB" validate "$origin"
    if [ "$status" -eq 0 ]; then
      echo "accepted a malformed origin: '${origin}'"
      return 1
    fi
  done

  # The trailing slash gets its OWN diagnostic, and that has to be asserted
  # separately from the rejection.
  #
  # Found by the mutation proof: deleting the path rule entirely leaves every
  # case above still REJECTED, because the host-shape check downstream refuses
  # `x.example.com/` as an invalid host. So the rule earns its place purely
  # through the sentence it produces — without this assertion it is a rule whose
  # removal no test can detect, which is the definition of decoration.
  # "invalid host 'x.example.com/'" does not tell the reader to drop the slash.
  run "$LIB" validate "https://x.example.com/"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not contain a path or a trailing slash"* ]]
}

@test "a malformed method name is rejected" {
  run "$LIB" apply "Not A Method" "$NGROK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid access-method name"* ]]
  # And nothing was published on the way to failing.
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN)" = "" ]
}

# ── Applying an origin ───────────────────────────────────────────────

@test "applying an origin patches every field that carries it" {
  run "$LIB" apply ngrok "$NGROK"
  [ "$status" -eq 0 ]

  # The origin itself, in flux-system (durable) and in BOTH tenant copies. The
  # tenant writes are the ones that take effect: measured 2026-08-03, the
  # copyFrom annotation does not reliably propagate an update, so writing
  # flux-system alone looks correct and silently serves a stale issuer.
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN)" = "$NGROK" ]
  [ "$(fake_cluster_get inf-signalloom PUBLIC_ORIGIN)" = "$NGROK" ]
  [ "$(fake_cluster_get fe-signalloom PUBLIC_ORIGIN)" = "$NGROK" ]

  # The lease, single-homed in flux-system.
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN_METHOD)" = "ngrok" ]
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN_OWNER)" = "tester@testhost" ]
  [ -n "$(fake_cluster_get flux-system PUBLIC_ORIGIN_SINCE)" ]

  # Single-homed means single-homed: a second copy of the holder is a second
  # answer to "who holds this" with no way to adjudicate when they disagree.
  run fake_cluster_has_key inf-signalloom PUBLIC_ORIGIN_METHOD
  [ "$status" -ne 0 ]
}

@test "applying an origin reconciles both consumers and restarts Dex" {
  run "$LIB" apply ngrok "$NGROK"
  [ "$status" -eq 0 ]

  local calls; calls="$(fake_cluster_calls)"
  [ -n "$calls" ]

  # The OCIRepository must be refreshed BEFORE the Kustomization or the new
  # substitution never reaches the manifest — reconciling the Kustomization
  # alone re-applies whatever its source already had.
  [[ "$calls" == *"flux reconcile source oci src-infra-configs -n inf-signalloom"* ]]
  [[ "$calls" == *"flux reconcile kustomization infra-configs -n inf-signalloom"* ]]
  [[ "$calls" == *"flux reconcile source oci src-apps -n fe-signalloom"* ]]
  [[ "$calls" == *"flux reconcile kustomization apps -n fe-signalloom"* ]]

  # Dex reads its config once, at process start — no watcher, no SIGHUP. Without
  # the restart the Secret in the cluster carries the new issuer while the
  # running process keeps rejecting the login with "Unregistered redirect_uri".
  [[ "$calls" == *"rollout restart deployment/dex"* ]]
  [[ "$calls" == *"rollout status deployment/dex"* ]]
}

@test "re-applying the same origin is a no-op" {
  run "$LIB" apply ngrok "$NGROK"
  [ "$status" -eq 0 ]

  fake_cluster_reset_log
  run "$LIB" apply ngrok "$NGROK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unchanged"* ]]

  # Not cosmetic. Dex runs `storage: type: memory`, so a needless restart
  # invalidates every in-flight login — a "no-op" that logs people out.
  local calls; calls="$(fake_cluster_calls)"
  [ -n "$calls" ]
  if [[ "$calls" == *"rollout restart"* ]]; then
    echo "re-applying restarted Dex; every in-flight login was invalidated:"
    echo "$calls"
    return 1
  fi
  if [[ "$calls" == *"patch configmap"* ]]; then
    echo "re-applying rewrote the ConfigMap:"
    echo "$calls"
    return 1
  fi
  if [[ "$calls" == *"flux reconcile"* ]]; then
    echo "re-applying reconciled Flux:"
    echo "$calls"
    return 1
  fi
}

# ── Mutual exclusion ─────────────────────────────────────────────────

@test "a second, different access method is REFUSED and the holder is named" {
  run "$LIB" apply ngrok "$NGROK"
  [ "$status" -eq 0 ]

  run "$LIB" apply tailscale "$TSNET"
  [ "$status" -ne 0 ]

  # Naming the holder is the whole point. "Refused" on its own sends the reader
  # hunting; the message has to say who to tear down and how.
  [[ "$output" == *"already held by 'ngrok'"* ]]
  [[ "$output" == *"${NGROK}"* ]]
  [[ "$output" == *"tester@testhost"* ]]
  [[ "$output" == *"dex-origin.sh restore"* ]]

  # A refusal that half-applied would be worse than no refusal at all.
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN)" = "$NGROK" ]
  [ "$(fake_cluster_get inf-signalloom PUBLIC_ORIGIN)" = "$NGROK" ]
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN_METHOD)" = "ngrok" ]
}

@test "the same access method may re-publish on a NEW origin" {
  # ngrok mints a fresh hostname on every restart, so refusing here would break
  # `make public` re-up — which is a hard requirement, `make public` is in use.
  run "$LIB" apply ngrok "$NGROK"
  [ "$status" -eq 0 ]

  run "$LIB" apply ngrok "https://zz-99-88.ngrok-free.app"
  [ "$status" -eq 0 ]
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN)" = "https://zz-99-88.ngrok-free.app" ]
  [ "$(fake_cluster_get fe-signalloom PUBLIC_ORIGIN)" = "https://zz-99-88.ngrok-free.app" ]
}

@test "Funnel is refused while the private tailnet origin is held, and vice versa" {
  # Tailscale and Funnel can serve the SAME hostname, so this is the collision
  # most likely to be waved through by a naive origin comparison: the origins
  # match while the access methods do not, and only one of them is actually
  # serving.
  run "$LIB" apply tailscale "$TSNET"
  [ "$status" -eq 0 ]

  run "$LIB" apply funnel "$TSNET"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already held by 'tailscale'"* ]]
}

@test "an unlabelled origin is adopted with a warning rather than refused" {
  # Pre-lease state: a cluster published by an older public-tunnel.sh, or a
  # hand-patched ConfigMap. Refusing would produce "held by (nobody)", which
  # names no one to tear down and so cannot be acted on.
  fake_cluster_configmap flux-system "PUBLIC_ORIGIN=https://stale.ngrok-free.app"

  run "$LIB" apply tailscale "$TSNET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"adopting an unlabelled origin"* ]]
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN)" = "$TSNET" ]
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN_METHOD)" = "tailscale" ]
}

# ── Teardown ─────────────────────────────────────────────────────────

@test "restore returns the baseline exactly and releases the lease" {
  run "$LIB" apply tailscale "$TSNET"
  [ "$status" -eq 0 ]

  run "$LIB" restore
  [ "$status" -eq 0 ]

  # SET, not deleted. Deleting PUBLIC_ORIGIN does not unpublish: the tenant
  # copies keep their last value when the key disappears, so the demo stays
  # published on a dead origin while the cluster looks reset.
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN)" = "$BASELINE" ]
  [ "$(fake_cluster_get inf-signalloom PUBLIC_ORIGIN)" = "$BASELINE" ]
  [ "$(fake_cluster_get fe-signalloom PUBLIC_ORIGIN)" = "$BASELINE" ]

  # The lease keys, by contrast, are REMOVED — a released lease that reads back
  # as the string "null" would be indistinguishable from a holder called null.
  run fake_cluster_has_key flux-system PUBLIC_ORIGIN_METHOD
  [ "$status" -ne 0 ]
  run fake_cluster_has_key flux-system PUBLIC_ORIGIN_OWNER
  [ "$status" -ne 0 ]
  run fake_cluster_has_key flux-system PUBLIC_ORIGIN_SINCE
  [ "$status" -ne 0 ]
}

@test "after restore another access method may take the origin" {
  run "$LIB" apply ngrok "$NGROK"
  [ "$status" -eq 0 ]
  run "$LIB" restore
  [ "$status" -eq 0 ]
  run "$LIB" apply funnel "$TSNET"
  [ "$status" -eq 0 ]
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN_METHOD)" = "funnel" ]
}

@test "restore is idempotent" {
  run "$LIB" apply ngrok "$NGROK"
  [ "$status" -eq 0 ]
  run "$LIB" restore
  [ "$status" -eq 0 ]

  fake_cluster_reset_log
  run "$LIB" restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"already at baseline"* ]]

  local calls; calls="$(fake_cluster_calls)"
  [ -n "$calls" ]
  if [[ "$calls" == *"rollout restart"* ]]; then
    echo "a second restore restarted Dex for nothing:"
    echo "$calls"
    return 1
  fi
}

@test "applying the resting baseline is a release, not a lease" {
  # The baseline is the RESTING origin — the value the manifests default to —
  # and it belongs to no access method. Letting any caller take a lease against
  # it would block every other method for no reason and break `make public`
  # after any run that touched it.
  #
  # This test used to be called "applying the IAP baseline", because IAP served
  # at this origin and therefore never needed a lease at all. It is renamed
  # rather than deleted: the RELEASE semantics it pins are unchanged and still
  # load-bearing; only the claim that this origin belongs to IAP has gone. What
  # IAP does now is asserted directly in the test below.
  run "$LIB" apply ngrok "$NGROK"
  [ "$status" -eq 0 ]
  run "$LIB" restore
  [ "$status" -eq 0 ]

  run "$LIB" apply iap "$BASELINE"
  [ "$status" -eq 0 ]
  run fake_cluster_has_key flux-system PUBLIC_ORIGIN_METHOD
  [ "$status" -ne 0 ]

  # And so the next method is free to take it.
  run "$LIB" apply ngrok "$NGROK"
  [ "$status" -eq 0 ]
}

@test "iap is an ordinary lease-taking method, not the baseline" {
  # The behavioural half of demoting IAP from "the baseline" to "a method".
  # Before this refactor IAP served at the origin the manifests already default
  # to, so it published nothing and held nothing, and every other method had to
  # work around a publisher it could not see. It now takes a lease like the
  # others — and the lease has to EXCLUDE the others, or it is decoration.
  local IAP="http://localhost:8080"

  run "$LIB" apply iap "$IAP"
  [ "$status" -eq 0 ]

  run "$LIB" current
  [ "$output" = "$IAP" ]
  run "$LIB" holder
  [ "$output" = "iap" ] || {
    echo "iap took the origin without recording itself as the holder: '${output}'"
    return 1
  }

  # A second method is refused, and told who to go and tear down.
  run "$LIB" apply ngrok "$NGROK"
  [ "$status" -ne 0 ] || {
    echo "ngrok published alongside a live IAP demo — one of the two logins now bounces"
    return 1
  }
  [[ "$output" == *"iap"* ]] || {
    echo "the refusal did not name iap as the holder: ${output}"
    return 1
  }

  # And the exclusion is symmetric — the previous behaviour was that IAP could
  # be trampled silently, so this direction is the one worth stating.
  run "$LIB" restore
  [ "$status" -eq 0 ]
  run "$LIB" apply ngrok "$NGROK"
  [ "$status" -eq 0 ]
  run "$LIB" apply iap "$IAP"
  [ "$status" -ne 0 ] || {
    echo "IAP took the issuer from a live ngrok demo"
    return 1
  }
  [[ "$output" == *"ngrok"* ]]
}

@test "holder answers 'is anyone publishing', which current cannot" {
  # `current` falls back to the baseline at rest, so it is NEVER empty and
  # "non-empty means somebody holds it" is wrong. An out-of-process caller that
  # made that inference refused itself on every idle cluster, naming the
  # baseline as the holder — which is exactly what
  # scripts/gcp-tf/demo-up.sh did until the seam tests in
  # test/terraform-demo-driver.bats drove the two against each other.
  #
  # The distinction is the whole reason this verb exists, so it is asserted as a
  # pair: at rest, `current` is non-empty AND `holder` is empty.
  run "$LIB" current
  [ "$status" -eq 0 ]
  [ -n "$output" ] || {
    echo "current is empty at rest, so this verb would be unnecessary — re-derive the caller contract"
    return 1
  }
  [ "$output" = "$BASELINE" ]

  run "$LIB" holder
  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "holder named '${output}' on a cluster nobody has published to"
    return 1
  }

  run "$LIB" apply tailscale "$TSNET"
  [ "$status" -eq 0 ]
  run "$LIB" holder
  [ "$status" -eq 0 ]
  [ "$output" = "tailscale" ]

  # Released again, so a caller polling this can tell the lease really went.
  run "$LIB" restore
  [ "$status" -eq 0 ]
  run "$LIB" holder
  [ -z "$output" ] || {
    echo "holder still names '${output}' after restore"
    return 1
  }
}

# ── Reporting ────────────────────────────────────────────────────────

@test "current and status describe the resting state and the held state" {
  run "$LIB" current
  [ "$status" -eq 0 ]
  [ "$output" = "$BASELINE" ]

  run "$LIB" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"AVAILABLE"* ]]
  # The resting state must not name a METHOD. It used to say "method: iap",
  # which was true while IAP served here and is now a lie of the expensive kind:
  # an operator reading it concludes an IAP demo is live and goes looking for a
  # tunnel to tear down.
  [[ "$output" != *"method:  iap"* ]] || {
    echo "status still attributes the resting origin to iap: ${output}"
    return 1
  }
  [[ "$output" == *"held by nobody"* ]] || {
    echo "status did not say the resting origin is unheld: ${output}"
    return 1
  }

  run "$LIB" apply tailscale "$TSNET"
  [ "$status" -eq 0 ]

  run "$LIB" current
  [ "$status" -eq 0 ]
  [ "$output" = "$TSNET" ]

  run "$LIB" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"HELD"* ]]
  [[ "$output" == *"tailscale"* ]]
  [[ "$output" == *"tester@testhost"* ]]
}

@test "current falls back to the baseline when the ConfigMap does not exist" {
  # A cluster mid-build. Callers must never have to tell "not created yet" apart
  # from "resting state" — both mean nobody has published anything.
  rm -f "${FAKE_CLUSTER_STATE}/cm-flux-system.json"
  run "$LIB" current
  [ "$status" -eq 0 ]
  [ "$output" = "$BASELINE" ]
}

# ── Failure handling ─────────────────────────────────────────────────

@test "a failed write to the lease namespace is fatal, not silent" {
  # The tenant writes tolerate failure because a tenant namespace may legitimately
  # not exist yet. The flux-system write may not: if it fails, no origin is
  # published and no lease is held, and continuing to reconcile and restart Dex
  # would report success over a demo that is still on the old origin.
  FAKE_CLUSTER_PATCH_FAILS=1 run "$LIB" apply ngrok "$NGROK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not write"* ]]

  local calls; calls="$(fake_cluster_calls)"
  [ -n "$calls" ]
  if [[ "$calls" == *"rollout restart"* ]]; then
    echo "Dex was restarted after the origin write failed:"
    echo "$calls"
    return 1
  fi
}

@test "a missing Dex deployment is tolerated" {
  # infra-configs may not have reconciled yet on a cluster being built. There is
  # nothing to restart and nothing to fail about.
  FAKE_CLUSTER_NO_DEX=1 run "$LIB" apply ngrok "$NGROK"
  [ "$status" -eq 0 ]
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN)" = "$NGROK" ]
}

# ── The migrated caller: `make public` must behave identically ───────

@test "expose.sh publish_origin and unpublish_origin drive the mechanism end to end" {
  # `make public` is in use, so this is the hard requirement of the migration:
  # the ngrok path must publish, hold and release exactly as before, with the
  # lease as the only addition. Driven through expose.sh's own function names
  # because those are what public-tunnel.sh calls — testing dex-origin.sh alone
  # would leave the seam between them unmeasured.
  run bash -c '
    set -euo pipefail
    source "'"$EXPOSE"'"
    publish_origin "https://ab-12-34.ngrok-free.app"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"PUBLIC_ORIGIN=https://ab-12-34.ngrok-free.app"* ]]
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN)" = "https://ab-12-34.ngrok-free.app" ]

  # expose.sh publishes as `ngrok`, so the lease names the transport rather than
  # the library.
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN_METHOD)" = "ngrok" ]

  # And the tunnel is now protected from a Tailscale run stealing its issuer —
  # the collision that previously presented as a broken login behind a tunnel
  # still reporting HEALTHY.
  run "$LIB" apply tailscale "$TSNET"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already held by 'ngrok'"* ]]

  run bash -c '
    set -euo pipefail
    source "'"$EXPOSE"'"
    unpublish_origin
  '
  [ "$status" -eq 0 ]
  [ "$(fake_cluster_get flux-system PUBLIC_ORIGIN)" = "$BASELINE" ]
  run fake_cluster_has_key flux-system PUBLIC_ORIGIN_METHOD
  [ "$status" -ne 0 ]
}

@test "public-tunnel.sh still parses and its origin calls still resolve" {
  # public-tunnel.sh is not modified by this change, but it sources expose.sh
  # and calls publish_origin/unpublish_origin. A rename or a lost function there
  # would only surface at `make public` time, on a cluster, in front of whoever
  # was about to share a demo link.
  local tunnel="${REPO_ROOT}/scripts/public-tunnel.sh"
  [ -f "$tunnel" ]
  run bash -n "$tunnel"
  [ "$status" -eq 0 ]

  run bash -c '
    set -euo pipefail
    source "'"$EXPOSE"'"
    for fn in publish_origin unpublish_origin reconcile_origin_consumers \
              dex_origin_apply dex_origin_restore dex_origin_current dex_origin_status; do
      declare -F "$fn" >/dev/null || { echo "missing: $fn"; exit 1; }
    done
    echo ALL_PRESENT
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL_PRESENT"* ]]
}

# ── Drift ────────────────────────────────────────────────────────────

@test "the baseline still matches every manifest default that carries the origin" {
  # Five fields render from ${PUBLIC_ORIGIN:=<baseline>}. If any default drifts
  # from the baseline this library restores to, teardown lands on an origin no
  # manifest agrees with and the demo comes back up broken — with every
  # component reporting healthy.
  local files=(
    "d2-signalloom/infra/inf-signalloom/base/dex.yaml"
    "d2-signalloom/apps/fe-signalloom/base/deployment.yaml"
    "d2-signalloom/apps/supercred-demo-runner/base/deployment.yaml"
  )
  local total=0
  for f in "${files[@]}"; do
    [ -f "${REPO_ROOT}/${f}" ]
    local n
    n="$(grep -c -F '${PUBLIC_ORIGIN:=' "${REPO_ROOT}/${f}" || true)"
    local m
    m="$(grep -c -F "\${PUBLIC_ORIGIN:=${BASELINE}}" "${REPO_ROOT}/${f}" || true)"
    if [ "$n" -ne "$m" ]; then
      echo "${f}: ${n} PUBLIC_ORIGIN defaults but only ${m} use the baseline ${BASELINE}"
      return 1
    fi
    total=$((total + n))
  done

  # Assert the universe is non-empty before trusting the pass. A guard that
  # counts zero fields against zero mismatches passes vacuously, and would keep
  # passing if the substitution were removed from every manifest.
  [ "$total" -ge 5 ]

  # And the library's own default agrees with what was just counted.
  run grep -c -F "DEX_ORIGIN_BASELINE:-${BASELINE}" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}
