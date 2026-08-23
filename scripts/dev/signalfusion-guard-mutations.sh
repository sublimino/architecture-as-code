#!/usr/bin/env bash
# Mutation sweep for d2-signalloom/test/signalfusion-runner-contract.bats.
#
# Each case mutates a REAL file, runs the suite, and records which tests failed.
# A guard that stays green under the mutation it exists to catch is not a guard.
#
# Restore is by saved file CONTENT, not `git checkout` -- a harness that reverts
# tracked files would eat any uncommitted work in the tree it runs in.
#
# Not wired into CI: this proves the guards once, on demand. Run from anywhere.

set -eo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
d2="$repo_root/d2-signalloom"
suite="test/signalfusion-runner-contract.bats"

deploy="$d2/apps/supercred-demo-runner/base/deployment.yaml"
dockerfile="$d2/apps/supercred-demo-runner/Dockerfile"
route="$d2/apps/fe-signalloom/base/gateway-route.yaml"
nginx_conf="$d2/apps/dashboard-signalloom/nginx.conf"
sf_client="$d2/apps/dashboard-signalloom/src/api/signalFusionDemo.ts"
runner_py="$d2/apps/fe-signalloom/src/demo_runner.py"
script="$repo_root/scripts/signalfusion-demo.sh"
extra_rbac="$d2/apps/supercred-demo-runner/base/mutation-probe-rbac.yaml"

backup_dir="$(mktemp -d)"
declare -a touched=()

save() {
	local f="$1"
	local key="${f//\//_}"
	cp -p "$f" "$backup_dir/$key"
	touched+=("$f")
}

restore_all() {
	local f key
	for f in "${touched[@]}"; do
		key="${f//\//_}"
		[ -f "$backup_dir/$key" ] && cp -p "$backup_dir/$key" "$f"
	done
	rm -f "$extra_rbac"
	touched=()
}

# Runs on SIGKILL's siblings but NOT on SIGKILL. If this harness is -9'd the
# tree is left mutated -- `git status` is the check.
trap 'restore_all; rm -rf "$backup_dir"' EXIT INT TERM

# Asserts a pattern exists before substituting it. sed reports success when it
# matches nothing, which would silently make a mutation a no-op and the guard
# look weak-but-passing.
must_sed() {
	local expr="$1" file="$2" probe="$3"
	grep -Eq "$probe" "$file" || { echo "PRECONDITION FAILED: no match for '$probe' in $file" >&2; exit 1; }
	sed -i "$expr" "$file"
	grep -Eq "$probe" "$file" && { echo "MUTATION NO-OP: '$probe' still present in $file" >&2; exit 1; }
	return 0
}

failed_tests() {
	(cd "$d2" && bats "$suite" 2>&1 | sed -n 's/^not ok [0-9]* //p') || true
}

run_case() {
	local name="$1"; shift
	restore_all
	"$@"
	local out
	out="$(failed_tests)"
	if [ -z "$out" ]; then
		printf '\n### %s\n    *** SURVIVED — no test failed ***\n' "$name"
	else
		printf '\n### %s\n' "$name"
		printf '    RED: %s\n' "$out"
	fi
	restore_all
}

# ── Mutations ────────────────────────────────────────────────────────────────

m_drop_cwd() {
	save "$deploy"
	python3 - "$deploy" <<-'PY'
		import re, sys
		p = sys.argv[1]
		s = open(p).read()
		new = re.sub(r'\n *- name: SIGNALFUSION_DEMO_CWD\n *value: [^\n]*', '', s, count=1)
		assert new != s, "SIGNALFUSION_DEMO_CWD not found"
		open(p, 'w').write(new)
	PY
}

m_wrong_cwd() {
	save "$deploy"
	python3 - "$deploy" <<-'PY'
		import re, sys
		p = sys.argv[1]
		s = open(p).read()
		new = re.sub(r'(- name: SIGNALFUSION_DEMO_CWD\n( *)value: )/repo', r'\1/wrong', s, count=1)
		assert new != s, "SIGNALFUSION_DEMO_CWD=/repo not found"
		open(p, 'w').write(new)
	PY
}

m_drop_script_copy() {
	save "$dockerfile"
	must_sed '\|^COPY scripts/signalfusion-demo.sh |d' "$dockerfile" '^COPY scripts/signalfusion-demo\.sh '
}

m_drop_lib_copy() {
	save "$dockerfile"
	must_sed '\|^COPY scripts/lib |d' "$dockerfile" '^COPY scripts/lib '
}

m_drop_nginx_rewrite() {
	save "$nginx_conf"
	must_sed '\|rewrite \^/demo-api/signalfusion|d' "$nginx_conf" 'rewrite \^/demo-api/signalfusion'
}

# Order matters: the SuperCred rewrite is unconditional on /demo-api, so if it
# comes first every Signal Fusion path is rewritten onto the supercred mount.
# The result is a 404 from the correct pod, which reads as an app bug.
m_swap_rewrite_order() {
	save "$nginx_conf"
	python3 - "$nginx_conf" <<-'PY'
		import re, sys
		p = sys.argv[1]
		lines = open(p).read().split("\n")
		sf = next(i for i, l in enumerate(lines) if re.search(r'rewrite \^/demo-api/signalfusion', l))
		sc = next(i for i, l in enumerate(lines) if re.search(r'rewrite \^/demo-api\(', l))
		assert sf < sc, "expected signalfusion rewrite to precede supercred"
		lines[sf], lines[sc] = lines[sc], lines[sf]
		open(p, "w").write("\n".join(lines))
	PY
}

# Rewrite onto the wrong demo type's mount.
m_nginx_wrong_target() {
	save "$nginx_conf"
	must_sed 's|rewrite \^/demo-api/signalfusion(/\.\*) /api/demo/signalfusion\$1 break;|rewrite ^/demo-api/signalfusion(/.*) /api/demo/supercred$1 break;|' \
		"$nginx_conf" 'rewrite \^/demo-api/signalfusion\(/\.\*\) /api/demo/signalfusion'
}

# The original defect, restored: point the client back at the runner's internal
# mount, which the gateway hands to fe-signalloom.
m_client_uses_internal_mount() {
	save "$sf_client"
	must_sed "s|^const SF_DEMO_API = '/demo-api/signalfusion'|const SF_DEMO_API = '/api/demo/signalfusion'|" \
		"$sf_client" "^const SF_DEMO_API = '/demo-api/signalfusion'"
}

# The ISC-14 breach this fix originally shipped, and which only a live-cluster
# test caught.
m_add_gateway_route() {
	save "$route"
	python3 - "$route" <<-'PY'
		import sys, yaml
		p = sys.argv[1]
		docs = list(yaml.safe_load_all(open(p)))
		hit = False
		for d in docs:
		    if d and d.get("kind") == "HTTPRoute" and d["metadata"]["name"] == "signalloom-api":
		        d["spec"]["rules"].insert(0, {
		            "matches": [{"path": {"type": "PathPrefix", "value": "/api/demo/signalfusion"}}],
		            "backendRefs": [{"name": "supercred-demo-runner", "port": 8000}],
		        })
		        hit = True
		assert hit, "signalloom-api route not found"
		open(p, "w").write(yaml.safe_dump_all(docs, sort_keys=False))
	PY
}

m_drop_ingest_url() {
	save "$deploy"
	python3 - "$deploy" <<-'PY'
		import re, sys
		p = sys.argv[1]
		s = open(p).read()
		new = re.sub(r'\n *- name: SIGNAL_INGEST_URL\n *value: [^\n]*', '', s, count=1)
		assert new != s, "SIGNAL_INGEST_URL not found"
		open(p, 'w').write(new)
	PY
}

m_script_ignores_url() {
	save "$script"
	must_sed 's|^INGEST_URL="\${SIGNAL_INGEST_URL:-http://localhost:\${SIGNAL_INGEST_LOCAL_PORT}}"|INGEST_URL="http://localhost:${SIGNAL_INGEST_LOCAL_PORT}"|' \
		"$script" '^INGEST_URL="\$\{SIGNAL_INGEST_URL:-'
}

m_script_not_executable() {
	save "$script"
	chmod -x "$script"
}

m_rename_default_script() {
	save "$runner_py"
	must_sed 's|default_script="scripts/signalfusion-demo.sh"|default_script="scripts/sf.sh"|' \
		"$runner_py" 'default_script="scripts/signalfusion-demo\.sh"'
}

m_grant_portforward() {
	cat > "$extra_rbac" <<-'YAML'
		apiVersion: rbac.authorization.k8s.io/v1
		kind: Role
		metadata:
		  name: mutation-probe-portforward
		  namespace: fe-signalloom
		rules:
		  - apiGroups: [""]
		    resources: ["pods/portforward"]
		    verbs: ["create"]
		---
		apiVersion: rbac.authorization.k8s.io/v1
		kind: RoleBinding
		metadata:
		  name: mutation-probe-portforward
		  namespace: fe-signalloom
		roleRef:
		  apiGroup: rbac.authorization.k8s.io
		  kind: Role
		  name: mutation-probe-portforward
		subjects:
		  - kind: ServiceAccount
		    name: supercred-demo-runner
		    namespace: fe-signalloom
	YAML
}

m_move_artifact() {
	save "$nginx_conf"
	rm -f "$nginx_conf"
}

echo "baseline (unmutated):"
base="$(failed_tests)"
[ -z "$base" ] && echo "    all green" || { echo "    NOT GREEN: $base"; exit 1; }

run_case "1  drop SIGNALFUSION_DEMO_CWD from the deployment"      m_drop_cwd
run_case "2  point SIGNALFUSION_DEMO_CWD at /wrong"               m_wrong_cwd
run_case "3  stop COPYing signalfusion-demo.sh into the image"    m_drop_script_copy
run_case "4  stop COPYing scripts/lib into the image"             m_drop_lib_copy
run_case "5  delete the nginx signalfusion rewrite"               m_drop_nginx_rewrite
run_case "6  put the unconditional supercred rewrite first"       m_swap_rewrite_order
run_case "7  rewrite signalfusion onto the supercred mount"       m_nginx_wrong_target
run_case "8  point the client back at the runner's mount"         m_client_uses_internal_mount
run_case "8b add a Gateway route to the runner (ISC-14)"          m_add_gateway_route
run_case "9  drop SIGNAL_INGEST_URL from the deployment"          m_drop_ingest_url
run_case "10 make the script ignore SIGNAL_INGEST_URL"            m_script_ignores_url
run_case "11 clear the script's executable bit"                   m_script_not_executable
run_case "12 rename DemoConfig.default_script"                    m_rename_default_script
run_case "13 grant pods/portforward to the runner SA"             m_grant_portforward
run_case "14 remove an artifact the suite reads"                  m_move_artifact

echo
echo "sweep complete; tree restored"
