#!/usr/bin/env bats
# d2-signalloom/test/kagent-contract.bats — Kagent Declarative Contract & Schema Tests
#
# IF YOU ARE ABOUT TO MUTATION-TEST THIS SUITE, START FROM GREEN.
# Every test here loops over all 8 agent directories in alphabetical order and
# returns on the first failure, so breaking one file while the suite is ALREADY
# red gives you a "not ok" that names kagent-chaos-prober — the pre-existing
# failure wearing your mutation's clothes. It looks like proof and is not.
# Cost a wasted falsification round on the SPIFFE trust-domain assertion:
# three mutations to kagent-k8s-reader all reported `card advertises :
# osramp.acme.local`, which was neither of the values injected.
# Fix everything first, confirm the suite passes, THEN break exactly one thing
# and check the failure names the thing you broke.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  # THE single place this suite learns the SPIFFE trust domain. Not a constant
  # duplicated into the test — this is the manifest that renders the
  # spire-server-config ConfigMap, so it is the same declaration the running
  # SPIRE server reads. Change SPIRE's domain and the agent cards are required
  # to follow, automatically, with no test edit.
  #
  # This suite must run WITHOUT a cluster (`make demo-kagent-test-config`), so
  # it reads the declaration rather than the live server. The two are tied
  # together by "declared SPIRE trust domain matches the live SPIRE server" in
  # test/kagent-credentials.bats, which is what makes reading the file here
  # trustworthy rather than merely convenient.
  SPIRE_CONFIG="${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-config.yaml"
}

# The server block's trust_domain. Scoped to `server {` deliberately: the agent
# block declares one too, and a config where they disagree is a real defect that
# must not be resolved by silently preferring whichever line matched first.
spire_trust_domain() {
  [ -f "$SPIRE_CONFIG" ] || return 0
  sed -n 's/.*server {[^}]*trust_domain[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$SPIRE_CONFIG" | head -1
}

@test "kagent-contract: Agent CR definitions are strictly fewer than 50 lines each across all agents" {
  count=0
  for f in "${REPO_ROOT}/d2-signalloom/infra/agent-swarm"/kagent-*/agent.yaml; do
    [ -f "$f" ]
    lines=$(wc -l < "$f")
    [ "$lines" -lt 50 ]

    # "Fewer than 50 lines" is satisfied by an empty file, which would make the
    # size-reduction claim simultaneously true and worthless. Require the file
    # to be a real Agent document before its brevity counts for anything.
    kind="$(yq -r 'select(.kind == "Agent") | .kind' "$f")"
    [ "$kind" = "Agent" ] || {
      echo "$f is under 50 lines but declares no Agent document"
      return 1
    }
    [ "$lines" -gt 5 ]

    count=$((count + 1))
  done
  [ "$count" -ge 8 ]
}

@test "kagent-contract: all Kagent agents declare signalloom.ai/agent label" {
  count=0
  for f in "${REPO_ROOT}/d2-signalloom/infra/agent-swarm"/kagent-*/agent.yaml; do
    # A grep for the bare string also matches a comment that merely mentions the
    # label, and '.' is a regex wildcard so "signalloomXai/agent" satisfies it.
    # Read the label's actual value out of the parsed document instead.
    value="$(yq -r 'select(.kind == "Agent") | .metadata.labels["signalloom.ai/agent"] // "ABSENT"' "$f")"
    [ "$value" = "true" ] || {
      echo "$f: signalloom.ai/agent = '$value' (expected \"true\")"
      return 1
    }
    count=$((count + 1))
  done
  [ "$count" -ge 8 ]
}

@test "kagent-contract: every Kagent agent declares a runtime, a ModelConfig and at least one tool" {
  # Was "K8s Reader uses Go runtime and ModelConfig": two greps against one of
  # the eight files. `grep -q "runtime: go"` matches a comment, matches any key
  # whose name ends in "runtime", and says nothing at all about the other seven
  # agents. The declarative claim in docs/kagent-d5.md is about all of them.
  count=0
  for f in "${REPO_ROOT}/d2-signalloom/infra/agent-swarm"/kagent-*/agent.yaml; do
    name="$(yq -r 'select(.kind == "Agent") | .metadata.name' "$f")"
    runtime="$(yq -r 'select(.kind == "Agent") | .spec.declarative.runtime // "ABSENT"' "$f")"
    model="$(yq -r 'select(.kind == "Agent") | .spec.declarative.modelConfig // "ABSENT"' "$f")"
    tools="$(yq -r 'select(.kind == "Agent") | (.spec.declarative.tools // []) | length' "$f")"

    [ "$runtime" = "go" ] || {
      echo "$name: runtime='$runtime' (expected go)"
      return 1
    }
    [ "$model" = "anthropic-claude" ] || {
      echo "$name: modelConfig='$model' (expected anthropic-claude)"
      return 1
    }
    [ "${tools:-0}" -ge 1 ] || {
      echo "$name: declares no tools — an agent with no tools cannot act"
      return 1
    }
    count=$((count + 1))
  done
  [ "$count" -ge 8 ]
}

@test "kagent-contract: OpenBao secret path map covers all 8 Kagent agents" {
  cm="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/openbao-secret-paths.yaml"
  [ -f "$cm" ]

  # `grep -q "${agent}.json:"` treats '.' as a wildcard and matches anywhere in
  # the file, including inside the 15-line explanatory comment header. Read the
  # ConfigMap's real data keys once, then check membership exactly.
  keys="$(yq -r 'select(.kind == "ConfigMap") | .data | keys | .[]' "$cm")"
  [ -n "$keys" ] || {
    echo "$cm has no ConfigMap data keys"
    return 1
  }

  missing=""
  for agent in kagent-k8s-reader kagent-commit-summariser kagent-security-analyst kagent-network-auditor kagent-incident-responder kagent-compliance-checker kagent-finops-optimizer kagent-chaos-prober; do
    found=0
    while IFS= read -r k; do
      [ "$k" = "${agent}.json" ] && found=1
    done <<<"$keys"
    [ "$found" -eq 1 ] || missing+="${agent}.json "
  done

  if [ -n "$missing" ]; then
    echo "openbao-secret-paths.yaml is missing data keys: $missing"
    echo "keys present:"
    printf '  %s\n' $keys
  fi
  [ -z "$missing" ]
}

# ─── ServiceAccount-name derivation (SPIFFE identity integrity) ──────────────
#
# `_agent_from_kagent_cr` in apps/fake-integration-proxy/server.py reports
# `"service_account": <Agent CR metadata.name>`. It has no choice: an
# Agent.kagent.dev CR carries no ServiceAccount field, so the name is DERIVED,
# not observed.
#
# The dashboard turns that value into the second half of a SPIFFE ID
# (spiffe://<trust-domain>/ns/<ns>/sa/<sa>) in the Credential Inventory. So the
# moment one agent's ServiceAccount stops being named after the agent, the
# governance UI renders an identity SPIRE never issued — a fabricated
# credential, displayed with the same confidence as a real one, with nothing
# anywhere failing. The pod path refuses the analogous guess for exactly this
# reason ("Absent stays None — defaulting to 'default' would render a SPIFFE ID
# that was never registered", server.py).
#
# These tests are what make the derivation legitimate rather than lucky: they
# convert an unwritten naming convention into an enforced invariant, so a future
# agent that breaks it fails here instead of in the UI.

@test "kagent-contract: every Kagent agent's ServiceAccount is named after the agent" {
  count=0
  for dir in "${REPO_ROOT}/d2-signalloom/infra/agent-swarm"/kagent-*/; do
    agent_yaml="${dir}agent.yaml"
    sa_yaml="${dir}serviceaccount.yaml"
    [ -f "$agent_yaml" ] || continue

    # A missing ServiceAccount is a failure, not a skip: the proxy would still
    # emit a service_account for this agent, naming an SA that does not exist.
    [ -f "$sa_yaml" ] || {
      echo "no serviceaccount.yaml beside $(basename "$dir")agent.yaml"
      echo "(the proxy derives service_account for it regardless — see server.py)"
      return 1
    }

    agent_name="$(yq -r 'select(.kind == "Agent") | .metadata.name' "$agent_yaml")"
    sa_name="$(yq -r 'select(.kind == "ServiceAccount") | .metadata.name' "$sa_yaml")"
    [ -n "$agent_name" ] && [ "$agent_name" != "null" ]
    [ -n "$sa_name" ] && [ "$sa_name" != "null" ]

    [ "$agent_name" = "$sa_name" ] || {
      echo "SPIFFE derivation broken for $(basename "$dir")"
      echo "  Agent CR name  : $agent_name"
      echo "  ServiceAccount : $sa_name"
      echo "the proxy would report service_account=$agent_name, an SA that is not"
      echo "the one this workload runs as — a SPIFFE ID SPIRE never issued"
      return 1
    }
    count=$((count + 1))
  done
  [ "$count" -ge 8 ]
}

@test "kagent-contract: every agent-card spiffeId names this cluster's trust domain and the agent's own ServiceAccount" {
  # Independent second witness on the same invariant. The card's spiffeId is
  # the identity the A2A contract advertises; the SA is the identity SPIRE
  # actually issues against. They must name the same principal.
  #
  # THE TRUST DOMAIN IS THE HALF THAT MATTERS MOST, and the earlier version of
  # this test never looked at it: `"${spiffe_id##*/sa/}" = "$sa_name"` validates
  # the trailing segment and is satisfied by ANY authority. A card reading
  # spiffe://osramp.acme.local/ns/…/sa/kagent-k8s-reader passed it cleanly,
  # while SPIRE runs trust_domain = "signalloom.demo" and would never issue such
  # an SVID. The trust domain is what makes a SPIFFE ID belong to this cluster
  # at all; without it the check confirms the surname and ignores the country.
  expected_domain="$(spire_trust_domain)"

  # Guard the guard. If extraction failed, expected_domain would be empty and
  # every comparison below would be against "", which must not read as a pass.
  [ -n "$expected_domain" ] || {
    echo "could not read trust_domain from ${SPIRE_CONFIG}"
    return 1
  }
  [[ "$expected_domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || {
    echo "trust_domain '$expected_domain' from ${SPIRE_CONFIG} is not a plausible domain"
    return 1
  }

  count=0
  for card in "${REPO_ROOT}/d2-signalloom/infra/agent-swarm"/kagent-*/agent-card.json; do
    [ -f "$card" ] || continue
    dir="$(dirname "$card")"
    sa_name="$(yq -r 'select(.kind == "ServiceAccount") | .metadata.name' "${dir}/serviceaccount.yaml")"
    ns_name="$(yq -r 'select(.kind == "ServiceAccount") | .metadata.namespace' "${dir}/serviceaccount.yaml")"
    spiffe_id="$(jq -r '.spiffeId' "$card")"
    card_name="$(jq -r '.name' "$card")"

    [ "$card_name" = "$sa_name" ] || {
      echo "$(basename "$dir"): agent-card name '$card_name' != ServiceAccount '$sa_name'"
      return 1
    }

    # Authority compared as a WHOLE segment — everything between "spiffe://" and
    # the first "/". A substring test would accept signalloom.demo.evil.com and
    # evil-signalloom.demo alike; both are different trust domains entirely.
    rest="${spiffe_id#spiffe://}"
    [ "$rest" != "$spiffe_id" ] || {
      echo "$(basename "$dir"): spiffeId '$spiffe_id' does not start with spiffe://"
      return 1
    }
    authority="${rest%%/*}"

    [ "$authority" = "$expected_domain" ] || {
      echo "$(basename "$dir"): wrong SPIFFE trust domain"
      echo "  card advertises : $authority"
      echo "  SPIRE issues in : $expected_domain   (${SPIRE_CONFIG})"
      echo "  full spiffeId   : $spiffe_id"
      echo "an SVID for this identity will never be issued: SPIRE mints SVIDs"
      echo "only within its own trust domain, so any peer validating this card"
      echo "is checking a name no certificate in this cluster can carry."
      return 1
    }

    # Full path, not just the /sa/ tail. The live SPIRE entries are
    # spiffe://<domain>/ns/<namespace>/sa/<serviceaccount>; asserting the whole
    # shape means a card cannot name the right agent in the wrong namespace.
    [ "${spiffe_id}" = "spiffe://${expected_domain}/ns/${ns_name}/sa/${sa_name}" ] || {
      echo "$(basename "$dir"): spiffeId does not match the identity SPIRE would issue"
      echo "  card     : $spiffe_id"
      echo "  expected : spiffe://${expected_domain}/ns/${ns_name}/sa/${sa_name}"
      return 1
    }
    count=$((count + 1))
  done
  [ "$count" -ge 8 ]
}

@test "kagent-contract: A2A agent-cards exist and conform to schema" {
  count=0
  for card in "${REPO_ROOT}/d2-signalloom/infra/agent-swarm"/kagent-*/agent-card.json; do
    [ -f "$card" ] || continue
    jq -e ".name != null and .spiffeId != null and .runtime != null" "$card" >/dev/null
    count=$((count + 1))
  done
  [ "$count" -ge 8 ]
}
