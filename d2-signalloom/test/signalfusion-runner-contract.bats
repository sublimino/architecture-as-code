#!/usr/bin/env bats
#
# Signal Fusion demo wiring: code, image, manifest and route must agree.
#
# The defect this pins, reproduced on the live demo lane 2026-08-23: all three
# acts at /weave returned
#
#   503 {"error":{"code":"demo_root_unresolved","message":"Demo runner cannot
#        locate the repo root: this deployment must set SIGNALFUSION_DEMO_CWD
#        ..."}}
#
# The message named an unset environment variable, which invites a one-line
# fix. That fix would have been wrong, and the reason is the whole point of
# this file: SIGNALFUSION_DEMO_CWD was unset on a pod that could not have run
# the demo whatever it was set to.
#
# What was actually measured, in the running cluster, before anything changed:
#
#   * src/api/signalFusionDemo.ts called /api/demo/signalfusion -- the runner's
#     INTERNAL mount -- while its own docstring described a /demo-api/
#     proxy. The live HTTPRoute signalloom-api had ONE rule,
#     `/api -> fe-signalloom-api:8000`, so Signal Fusion was served by
#     fe-signalloom, NOT by the demo runner that serves SuperCred. nginx's
#     /demo-api/ block rewrote unconditionally to /api/demo/supercred, so the
#     documented path would not have worked either.
#   * fe-signalloom's image is `WORKDIR /app` + `COPY src/ .`. In the running
#     pod, /app/scripts and /repo both did not exist, and the only one of
#     {kubectl, curl, bash} present was bash. It cannot execute a demo script.
#   * supercred-demo-runner's /repo/scripts/ held four supercred-* scripts and
#     lib/. signalfusion-demo.sh was in NO image in the estate.
#
# So the 503 was honest. Setting SIGNALFUSION_DEMO_CWD on fe-signalloom would
# have resolved the root and then failed on a missing script, on a pod with no
# kubectl -- converting a 503 that names its own fix into a 503 that does not.
#
# WHY THIS SUITE EXISTS RATHER THAN MORE PYTHON TESTS
#
# src/tests/test_demo_runner_repo_root.py already covers this code path well:
# it asserts the container layout resolves to None, that _repo_root_for raises
# demo_root_unresolved, and that the message names the variable. Those tests
# were green for the entire life of the defect and would have stayed green
# through any fix, because the missing value was never in the Python. It was in
# a manifest, an image, and a route -- three artifacts no Python test reads.
#
# A test of the code alone cannot fail on this class of defect. That is the
# gap. Every assertion below therefore reads a DEPLOYED artifact, and the
# load-bearing ones join two artifacts together so neither can drift alone:
#
#   * the Dockerfile's COPY destination is compared against the path
#     demo_runner.py computes (env value + DemoConfig.default_script), not
#     against a string repeated from it;
#   * the client's base prefix is compared against the rewrite in nginx.conf,
#     so neither end can be re-pointed on its own.
#
# One more thing this suite learned the hard way: the first attempt at the fix
# added a Gateway HTTPRoute to the runner, which is forbidden by ISC-14 and was
# caught only by a LIVE-cluster test, a full pipeline run later. That
# prohibition is now also asserted statically here, at commit time.
#
# Matchers are ANCHORED. An earlier guard in this repo matched an object name
# as a substring, so renaming the object left all five of its tests green.

setup() {
	repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	d2="$repo_root/d2-signalloom"
	runner_deploy="$d2/apps/supercred-demo-runner/base/deployment.yaml"
	runner_dockerfile="$d2/apps/supercred-demo-runner/Dockerfile"
	runner_service="$d2/apps/supercred-demo-runner/base/service.yaml"
	nginx_conf="$d2/apps/dashboard-signalloom/nginx.conf"
	sf_client="$d2/apps/dashboard-signalloom/src/api/signalFusionDemo.ts"
	demo_runner_py="$d2/apps/fe-signalloom/src/demo_runner.py"
	demo_script="$repo_root/scripts/signalfusion-demo.sh"
}

# Value of `- name: KEY` / `value: X` from a deployment manifest.
#
# Anchored on `KEY$` so SIGNALFUSION_DEMO_CWD cannot be satisfied by a longer
# name that merely contains it, and bails at the next `- name:` so it can never
# return a neighbouring variable's value.
env_value() {
	local file="$1" key="$2"
	awk -v k="$key" '
		$0 ~ "^[[:space:]]*- name: " k "[[:space:]]*$" { want = 1; next }
		want && /^[[:space:]]*value:/ {
			sub(/^[[:space:]]*value:[[:space:]]*/, "")
			gsub(/^['"'"'"]|['"'"'"]$/, "")
			print; exit
		}
		want && /^[[:space:]]*- name:/ { exit }
	' "$file"
}

# Value of KEY from a Dockerfile `ENV KEY=VALUE` line, including the
# continuation form `ENV A=1 \` / `    KEY=2`.
dockerfile_env() {
	local file="$1" key="$2"
	sed -n "s/^[[:space:]]*\(ENV[[:space:]]\+\)\?${key}=\([^[:space:]\\\\]*\).*/\2/p" "$file" | head -1
}

# The literal assigned to `default_script=` inside the signalfusion DemoConfig.
# Scoped to that block so the supercred entry cannot answer for it.
signalfusion_default_script() {
	awk '
		/demo_type="signalfusion"/ { in_sf = 1 }
		in_sf && /default_script=/ {
			sub(/^.*default_script="/, "")
			sub(/".*$/, "")
			print; exit
		}
	' "$demo_runner_py"
}

@test "SIGNALFUSION-CONTRACT every artifact under test exists" {
	# If any of these paths moves, every assertion below would pass vacuously
	# against a file it never read. Fail here instead, loudly.
	[ -f "$runner_deploy" ]
	[ -f "$runner_dockerfile" ]
	[ -f "$runner_service" ]
	[ -f "$nginx_conf" ]
	[ -f "$sf_client" ]
	[ -f "$demo_runner_py" ]
	[ -f "$demo_script" ]
}

@test "SIGNALFUSION-CONTRACT the demo script is executable in the source tree" {
	# demo_runner.py execs it directly rather than via `bash <script>`, so a
	# non-executable bit is a runtime failure the image build would carry in.
	[ -x "$demo_script" ]
}

@test "SIGNALFUSION-CONTRACT the runner manifest declares SIGNALFUSION_DEMO_CWD" {
	# This is THE assertion that was missing. The variable was absent from
	# every manifest in the repo while the Python that reads it was fully
	# tested.
	run env_value "$runner_deploy" SIGNALFUSION_DEMO_CWD
	[ "$status" -eq 0 ]
	[ -n "$output" ]
}

@test "SIGNALFUSION-CONTRACT both demo roots point at the same in-image repo root" {
	# One image serves both demos, so two different roots would mean one of
	# them is wrong. Comparing them makes the pair drift-proof rather than
	# asserting /repo twice.
	local sf sc
	sf="$(env_value "$runner_deploy" SIGNALFUSION_DEMO_CWD)"
	sc="$(env_value "$runner_deploy" SUPERCRED_DEMO_CWD)"
	[ -n "$sf" ]
	[ -n "$sc" ]
	[ "$sf" = "$sc" ]
}

@test "SIGNALFUSION-CONTRACT the image and the manifest agree on the demo root" {
	# SuperCred deliberately restates its root in both places so the contract
	# is visible where it is operated. Restatement without an equality check is
	# how two copies silently diverge.
	local manifest image
	manifest="$(env_value "$runner_deploy" SIGNALFUSION_DEMO_CWD)"
	image="$(dockerfile_env "$runner_dockerfile" SIGNALFUSION_DEMO_CWD)"
	[ -n "$manifest" ]
	[ -n "$image" ]
	[ "$manifest" = "$image" ]
}

@test "SIGNALFUSION-CONTRACT demo_runner.py still derives the script from the root" {
	# Assert the MECHANISM, not just its effect. If default_script stopped
	# existing, the join asserted in the next test would compare against an
	# empty string and pass against a tree that no longer works this way.
	run signalfusion_default_script
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	[[ "$output" == *signalfusion-demo.sh ]]
}

@test "SIGNALFUSION-CONTRACT the image ships the script at exactly the path the code computes" {
	# The cross-artifact join: env value + default_script is the absolute path
	# demo_runner.py will exec. The Dockerfile must COPY the script THERE.
	# Deriving the expectation rather than hardcoding /repo/scripts/... means
	# moving either half breaks this test instead of breaking the demo.
	local root default_script expected
	root="$(env_value "$runner_deploy" SIGNALFUSION_DEMO_CWD)"
	default_script="$(signalfusion_default_script)"
	[ -n "$root" ]
	[ -n "$default_script" ]
	expected="${root}/${default_script}"

	run grep -Eq "^COPY[[:space:]]+scripts/signalfusion-demo\.sh[[:space:]]+${expected}[[:space:]]*$" "$runner_dockerfile"
	[ "$status" -eq 0 ]
}

@test "SIGNALFUSION-CONTRACT the image ships the library the script sources" {
	# signalfusion-demo.sh sources lib/wait.sh relative to its own directory.
	# It is already COPYd for SuperCred's benefit; assert it rather than
	# inherit it, so removing it for SuperCred reasons cannot silently break
	# Signal Fusion.
	grep -Eq '^COPY[[:space:]]+scripts/lib[[:space:]]' "$runner_dockerfile"
	grep -Eq '^[[:space:]]*source[[:space:]]+"\$\{SCRIPT_DIR\}/lib/wait\.sh"' "$demo_script"
}

@test "SIGNALFUSION-CONTRACT nginx rewrites the browser prefix onto the runner's mount" {
	# The half that decides WHICH pod answers. Signal Fusion is proxied by the
	# dashboard's nginx, exactly as SuperCred is, because ISC-14 forbids a
	# Gateway route to the runner (see the test below).
	#
	# Both rewrites are asserted, in order: the signalfusion one must come
	# first, because the SuperCred rewrite is unconditional on /demo-api and
	# would otherwise swallow every Signal Fusion path and send it to
	# /api/demo/supercred/signalfusion/... -- a 404 from the right pod, which
	# looks nothing like a routing bug.
	run python3 - "$nginx_conf" <<-'PY'
		import re, sys

		conf = open(sys.argv[1]).read()

		sf = re.search(r'^\s*rewrite\s+\^/demo-api/signalfusion\(/\.\*\)\s+/api/demo/signalfusion\$1\s+break;',
		               conf, re.M)
		sc = re.search(r'^\s*rewrite\s+\^/demo-api\(/\.\*\)\s+/api/demo/supercred\$1\s+break;',
		               conf, re.M)
		assert sf, "no /demo-api/signalfusion rewrite in nginx.conf"
		assert sc, "no /demo-api -> supercred rewrite in nginx.conf"
		assert sf.start() < sc.start(), (
		    "the signalfusion rewrite must precede the unconditional supercred one; "
		    f"found at {sf.start()} and {sc.start()}"
		)
		print("ok")
	PY
	[ "$status" -eq 0 ]
	[[ "$output" == *ok* ]]
}

@test "SIGNALFUSION-CONTRACT the client calls the browser-facing prefix, not the runner's mount" {
	# The other end of the same wire. Pointing this back at /api/demo/... is
	# not a loud failure: /api goes to the gateway and is served by
	# fe-signalloom, which answers 503 demo_root_unresolved. That is the exact
	# defect this suite exists for, so it is asserted against the nginx rewrite
	# rather than as a standalone string.
	run grep -Eo "^const SF_DEMO_API = '[^']+'" "$sf_client"
	[ "$status" -eq 0 ]
	[[ "$output" == "const SF_DEMO_API = '/demo-api/signalfusion'" ]]

	# And the prefix the client uses must be one nginx actually rewrites.
	local prefix
	prefix="$(printf '%s' "$output" | sed "s|.*'\(.*\)'|\1|")"
	grep -Fq "rewrite ^${prefix}(/.*) /api/demo/signalfusion\$1 break;" "$nginx_conf"
}

@test "SIGNALFUSION-CONTRACT no Gateway route targets the runner (ISC-14)" {
	# Restates ISC-14 statically, next to the change most likely to breach it.
	# supercred-demo-api.bats asserts this against a LIVE cluster, so it cannot
	# fail until a lane is standing -- which is how a breaching manifest got as
	# far as a full pipeline run before anything objected.
	#
	# A route here would put the demo control plane on the internet beside the
	# dashboard, bypassing the nginx block that forwards the bearer.
	run python3 - "$d2" <<-'PY'
		import pathlib, sys, yaml

		d2 = pathlib.Path(sys.argv[1])
		hits = []
		for path in d2.rglob("*.yaml"):
		    try:
		        docs = list(yaml.safe_load_all(path.read_text()))
		    except yaml.YAMLError:
		        continue
		    for doc in docs:
		        if not isinstance(doc, dict) or doc.get("kind") != "HTTPRoute":
		            continue
		        for rule in doc["spec"].get("rules", []):
		            for ref in rule.get("backendRefs", []):
		                if ref.get("name") == "supercred-demo-runner":
		                    hits.append(f'{path.name}:{doc["metadata"]["name"]}')
		assert not hits, f"HTTPRoute targets the runner directly, breaching ISC-14: {hits}"
		print("ok")
	PY
	[ "$status" -eq 0 ]
	[[ "$output" == *ok* ]]
}

@test "SIGNALFUSION-CONTRACT the runner reaches signal-ingest directly, not via port-forward" {
	# The script port-forwards svc/signal-ingest when run from a laptop. In
	# cluster that would need `create pods/portforward` in inf-signalloom --
	# measured as denied for this ServiceAccount, and a grant that would let
	# the holder reach ANY port on ANY pod in that namespace. The runner is
	# already inside the cluster, so it is given the Service URL instead and
	# the port-forward is skipped.
	#
	# Asserting the env var alone would go green if the script stopped honouring
	# it, so both halves are checked.
	local url
	url="$(env_value "$runner_deploy" SIGNAL_INGEST_URL)"
	[ -n "$url" ]
	[[ "$url" == *signal-ingest* ]]

	# The script must treat SIGNAL_INGEST_URL as an override of the localhost
	# default, and must skip the port-forward when it is set.
	grep -Eq '^INGEST_URL="\$\{SIGNAL_INGEST_URL:-http://localhost:\$\{SIGNAL_INGEST_LOCAL_PORT\}\}"' "$demo_script"
	grep -Eq 'SIGNAL_INGEST_URL' "$demo_script"
}

@test "SIGNALFUSION-CONTRACT no port-forward permission was granted to make this work" {
	# The negative half of the test above. If someone later "fixes" a
	# port-forward failure by granting the verb, this fails and points at the
	# direct-URL route instead. Anchored on the runner's ServiceAccount name so
	# an unrelated Role elsewhere cannot trip it.
	local sa
	sa="$(awk '/^[[:space:]]*serviceAccountName:/ { print $2; exit }' "$runner_deploy")"
	[ -n "$sa" ]

	run python3 - "$d2" "$sa" <<-'PY'
		import pathlib, sys, yaml

		d2, sa = pathlib.Path(sys.argv[1]), sys.argv[2]

		bindings, roles = [], {}
		for path in d2.rglob("*.yaml"):
		    try:
		        docs = list(yaml.safe_load_all(path.read_text()))
		    except yaml.YAMLError:
		        continue
		    for doc in docs:
		        if not isinstance(doc, dict):
		            continue
		        kind = doc.get("kind")
		        if kind in ("Role", "ClusterRole"):
		            roles[doc["metadata"]["name"]] = doc.get("rules") or []
		        elif kind in ("RoleBinding", "ClusterRoleBinding"):
		            bindings.append(doc)

		bound = [
		    b["roleRef"]["name"]
		    for b in bindings
		    for s in (b.get("subjects") or [])
		    if s.get("kind") == "ServiceAccount" and s.get("name") == sa
		]

		offending = [
		    (name, rule)
		    for name in bound
		    for rule in roles.get(name, [])
		    if any(r in ("pods/portforward", "pods/*", "*") for r in (rule.get("resources") or []))
		]
		assert not offending, f"{sa} was granted port-forward reach: {offending}"
		print("ok")
	PY
	[ "$status" -eq 0 ]
	[[ "$output" == *ok* ]]
}
