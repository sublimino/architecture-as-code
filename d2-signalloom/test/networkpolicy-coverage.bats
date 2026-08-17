#!/usr/bin/env bats
#
# The general form of a defect that reached the cluster: a workload landed in a
# default-deny namespace carrying no NetworkPolicy of its own.
#
# signal-ingest was the instance. fe-signalloom's default-deny policy has an
# empty podSelector, so it applies to every pod in the namespace and denies
# both directions unless some other policy grants them. signal-ingest's
# kustomization listed deployment.yaml and service.yaml and nothing else, which
# left it with no egress at all -- not even DNS. Because its DATABASE_URL comes
# from a secretKeyRef the DSN was always set, so it always tried Postgres, the
# SYN was DROPPED rather than refused, and the unbounded db.Ping() never
# returned. It never bound its port; the startup probe killed it at ~19s.
#
# Nothing in the suite caught that, because nothing asserted the invariant that
# actually matters. A test naming signal-ingest would have caught this one
# workload and missed the next, so these tests are written over EVERY workload
# the namespace renders. Adding a Deployment with no policy fails them; so does
# deleting the networkpolicy.yaml line from any kustomization.
#
# The check is on the rendered manifests, not the live cluster: the defect is
# in what GitOps ships, and it must fail in CI on a laptop with no kind node.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  overlay="$repo_root/d2-signalloom/apps/fe-signalloom/local"
  infra_overlay="$repo_root/d2-signalloom/infra/inf-signalloom/configs/local"
  command -v kubectl >/dev/null || skip "kubectl is required to render the overlay"
  command -v jq >/dev/null || skip "jq is required to evaluate label selectors"
  command -v yq >/dev/null || skip "yq is required to convert the render to JSON"
}

# render_json emits the whole overlay as a JSON array of objects.
render_json() {
  kubectl kustomize "$overlay" | yq -o=json -I=0 'select(. != null)' | jq -s '.'
}

# render_infra_json does the same for the inf-signalloom configs, which hold
# the ingress side of every cross-namespace path out of fe-signalloom.
render_infra_json() {
  kubectl kustomize "$infra_overlay" | yq -o=json -I=0 'select(. != null)' | jq -s '.'
}

# The jq program below answers one question per workload: is there a policy
# that selects it AND grants the direction in question?
#
# "Grants" is defined behaviourally rather than by policy name. A policy
# contributes permission for a direction only if it (a) selects the pod, (b)
# lists that direction in policyTypes, and (c) carries a NON-EMPTY rule list
# for it. default-deny satisfies (a) and (b) for every pod in the namespace and
# fails (c), so it is excluded by what it does rather than by being named --
# which means renaming or duplicating it cannot smuggle a workload past this.
#
# Selector semantics follow Kubernetes: matchLabels is a conjunction, and an
# EMPTY podSelector selects every pod in the namespace.
JQ_COVERAGE='
  def pod_labels: .spec.template.metadata.labels // {};

  def selects($labels):
    (.spec.podSelector // {}) as $sel
    | ($sel.matchLabels // {}) as $ml
    | ($ml | length) == 0 or all($ml | to_entries[]; $labels[.key] == .value);

  def grants($dir; $labels):
    selects($labels)
    and ((.spec.policyTypes // []) | index($dir) != null)
    and (( if $dir == "Ingress" then (.spec.ingress // []) else (.spec.egress // []) end ) | length) > 0;

  [ .[] | select(.kind == "NetworkPolicy") ] as $policies
  | [ .[]
      | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet")
      | { kind: .kind,
          name: .metadata.name,
          labels: pod_labels }
    ]
  | map(. as $w | $w + {
      ingress_policies: [ $policies[] | select(grants("Ingress"; $w.labels)) | .metadata.name ],
      egress_policies:  [ $policies[] | select(grants("Egress";  $w.labels)) | .metadata.name ]
    })
'

@test "the fe-signalloom overlay renders and is default-deny" {
  run render_json
  [ "$status" -eq 0 ]

  # If this namespace ever stops being default-deny the tests below still pass
  # but stop meaning anything -- an uncovered workload would simply be allowed.
  # Assert the precondition so the suite cannot quietly become decoration.
  deny="$(echo "$output" | jq '[ .[]
    | select(.kind == "NetworkPolicy")
    | select((.spec.podSelector // {} | length) == 0)
    | select((.spec.ingress // []) | length == 0)
    | select((.spec.egress  // []) | length == 0)
  ] | length')"
  [ "$deny" -ge 1 ]
}

@test "the render contains the workloads under test" {
  # Guards against the whole suite passing vacuously because the render
  # produced nothing, or because signal-ingest was dropped from the
  # kustomization entirely rather than given a policy.
  run render_json
  [ "$status" -eq 0 ]

  workloads="$(echo "$output" | jq "$JQ_COVERAGE" | jq -r '.[].name' | sort)"
  echo "workloads: $workloads" >&2

  count="$(echo "$workloads" | grep -c .)"
  [ "$count" -ge 3 ]
  echo "$workloads" | grep -qx 'signal-ingest'
  echo "$workloads" | grep -qx 'fe-signalloom'
}

@test "every workload in default-deny fe-signalloom has an egress NetworkPolicy" {
  # This is the assertion that fails on the shipped tree. Without egress a pod
  # cannot resolve DNS, so it cannot reach anything by name -- the state
  # signal-ingest booted into.
  run render_json
  [ "$status" -eq 0 ]

  uncovered="$(echo "$output" | jq -r "$JQ_COVERAGE"' | .[] | select((.egress_policies | length) == 0) | "\(.kind)/\(.name) labels=\(.labels | tojson)"')"

  if [ -n "$uncovered" ]; then
    echo "workloads with NO egress NetworkPolicy in a default-deny namespace:" >&2
    echo "$uncovered" >&2
    echo "each of these has no egress at all, not even DNS; add a policy to its base/" >&2
    false
  fi
}

@test "every workload in default-deny fe-signalloom has an ingress NetworkPolicy" {
  # Weaker than the egress rule in consequence -- a workload nothing calls is a
  # legitimate design -- but every workload in this namespace is reached by
  # something (gateway, dashboard nginx, or the API pod), so a missing ingress
  # policy here means a service nobody can call.
  run render_json
  [ "$status" -eq 0 ]

  uncovered="$(echo "$output" | jq -r "$JQ_COVERAGE"' | .[] | select((.ingress_policies | length) == 0) | "\(.kind)/\(.name) labels=\(.labels | tojson)"')"

  if [ -n "$uncovered" ]; then
    echo "workloads with NO ingress NetworkPolicy in a default-deny namespace:" >&2
    echo "$uncovered" >&2
    false
  fi
}

@test "signal-ingest egress reaches DNS and Postgres, and nothing else" {
  # The coverage tests above prove a policy EXISTS. This one proves it grants
  # what the workload actually needs: a policy present but scoped to the wrong
  # port or namespace passes coverage and still leaves the pod unable to boot.
  run render_json
  [ "$status" -eq 0 ]

  policy="$(echo "$output" | jq '.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-signal-ingest-egress")')"
  [ -n "$policy" ]

  # DNS, or the DSN's hostname never resolves.
  echo "$policy" | jq -e '[ .spec.egress[]
    | select([.to[]? | select(.podSelector.matchLabels["k8s-app"] == "kube-dns")] | length > 0)
    | select([.ports[]? | select(.port == 53)] | length > 0)
  ] | length == 1'

  # Postgres, scoped to the postgresql pod in inf-signalloom.
  echo "$policy" | jq -e '[ .spec.egress[]
    | select([.to[]?
        | select(.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "inf-signalloom")
        | select(.podSelector.matchLabels["app.kubernetes.io/name"] == "postgresql")] | length > 0)
    | select([.ports[]? | select(.port == 5432)] | length > 0)
  ] | length == 1'

  # Least privilege, asserted as a count rather than left to review: a third
  # rule appearing here is a grant nobody argued for. signal-ingest makes no
  # outbound HTTP call of any kind.
  echo "$policy" | jq -e '(.spec.egress | length) == 2'

  # No unbounded rule. An egress entry with no `to` allows every destination,
  # which would pass every assertion above while granting the cluster.
  echo "$policy" | jq -e '[ .spec.egress[] | select(has("to") | not) ] | length == 0'
}

@test "fe-signalloom holds the egress half of the signal-ingest pair" {
  # A NetworkPolicy pair fails silently when only one half is present: the
  # caller's packets are dropped on the way out, the callee looks healthy, and
  # the feature just returns nothing. signal_fusion.py catches the connect
  # error and logs before degrading, so the dashboard shows an empty panel
  # rather than an error.
  run render_json
  [ "$status" -eq 0 ]

  policy="$(echo "$output" | jq '.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-portal-dependencies")')"
  [ -n "$policy" ]

  echo "$policy" | jq -e '[ .spec.egress[]
    | select([.to[]? | select(.podSelector.matchLabels["app.kubernetes.io/name"] == "signal-ingest")] | length > 0)
    | select([.ports[]? | select(.port == 8082)] | length > 0)
  ] | length == 1'

  # And the matching ingress half admits fe-signalloom specifically.
  ingress="$(echo "$output" | jq '.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-signal-ingest-ingress")')"
  [ -n "$ingress" ]
  echo "$ingress" | jq -e '[ .spec.ingress[]
    | select([.from[]? | select(.podSelector.matchLabels["app.kubernetes.io/name"] == "fe-signalloom")] | length > 0)
    | select([.ports[]? | select(.port == 8082)] | length > 0)
  ] | length == 1'
}

@test "inf-signalloom admits signal-ingest to Postgres, and only to Postgres" {
  # The third half. signal-ingest -> Postgres crosses a namespace boundary, so
  # it needs THREE rules, not two: egress from signal-ingest, and ingress at
  # inf-signalloom. The caller's own egress policy passing every assertion
  # above while the connection still times out is exactly what happened on the
  # cluster -- inf-signalloom's allow-dependency-traffic scoped its 5432 rule
  # to app.kubernetes.io/name=fe-signalloom, which signal-ingest is not.
  #
  # Reading either namespace alone shows nothing wrong, which is why this is
  # asserted rather than reviewed.
  run render_infra_json
  [ "$status" -eq 0 ]

  policy="$(echo "$output" | jq '.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-dependency-traffic")')"
  [ -n "$policy" ]

  echo "$policy" | jq -e '[ .spec.ingress[]
    | select([.from[]?
        | select(.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "fe-signalloom")
        | select(.podSelector.matchLabels["app.kubernetes.io/name"] == "signal-ingest")] | length > 0)
    | select([.ports[]? | select(.port == 5432)] | length > 0)
  ] | length == 1'

  # Least privilege: the signal-ingest rule must not have inherited the
  # neighbouring rule's Redis and MinIO ports. The service touches neither.
  echo "$policy" | jq -e '[ .spec.ingress[]
    | select([.from[]? | select(.podSelector.matchLabels["app.kubernetes.io/name"] == "signal-ingest")] | length > 0)
    | .ports[]? | select(.port == 6379 or .port == 9000)
  ] | length == 0'
}
