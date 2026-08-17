#!/usr/bin/env bats
#
# Dex must actually restart when its config changes.
#
# Dex reads /etc/dex/config.yaml once at process start — no watcher, no SIGHUP
# reload. Kubernetes updates the mounted Secret file underneath the running
# process, so the file on disk and the config Dex is serving drift apart with
# nothing in the logs to mark it. Because nothing in the Deployment changes
# when only the Secret changes, no rollout is triggered.
#
# Two real incidents on 2026-08-03, same root cause:
#   * `viewer` was added to staticPasswords, landed in the Secret, and Dex kept
#     answering "Invalid username or password" — with NO failed-login line in
#     its log, because the user did not exist to the running process.
#   * The far worse variant: change PUBLIC_ORIGIN and Dex keeps minting tokens
#     with the old `iss` while every consumer has moved on. Every token is then
#     rejected as invalid_token, which looks like a broken login rather than a
#     stale process.
#
# The fix is two pod-template annotations. These tests exist because a
# hand-maintained hash that nothing enforces is worse than no hash at all — it
# reads as protection while silently rotting.

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  dex_manifest="$root/d2-signalloom/infra/inf-signalloom/base/dex.yaml"
  dex_ui_manifest="$root/d2-signalloom/infra/inf-signalloom/base/dex-ui.yaml"
}

# sha256 of the Secret's config.yaml exactly as authored, before Flux
# substitution. Deliberately pre-substitution: this hash's job is to catch
# hand-edits, and it must be computable from the repo alone with no cluster.
config_sha() {
  python3 -c "
import yaml, hashlib, sys
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get('kind') == 'Secret' and d['metadata']['name'] == 'dex-local-auth':
        print(hashlib.sha256(d['stringData']['config.yaml'].encode()).hexdigest())
        break
" "$dex_manifest"
}

# sha256 over the .html keys of the dex-ui ConfigMap, serialised with sorted
# keys so it is stable. Scoped to templates because Dex parses those once at
# boot; styles.css is served per-request off disk and needs no restart.
ui_sha() {
  python3 -c "
import yaml, hashlib, json, sys
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get('kind') == 'ConfigMap' and d['metadata']['name'] == 'dex-ui':
        tpls = {k: v for k, v in d['data'].items() if k.endswith('.html')}
        if not tpls:
            sys.exit('dex-ui ConfigMap has no .html keys')
        print(hashlib.sha256(json.dumps(tpls, sort_keys=True).encode()).hexdigest())
        break
else:
    sys.exit('no ConfigMap named dex-ui')
" "$dex_ui_manifest"
}

annotation() {
  python3 -c "
import yaml, sys
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get('kind') == 'Deployment' and d['metadata']['name'] == 'dex':
        print(d['spec']['template']['metadata'].get('annotations', {}).get(sys.argv[2], ''))
        break
" "$dex_manifest" "$1"
}

@test "DEXRELOAD the Dex pod template carries a config-sha annotation" {
  run annotation signalloom.ai/dex-config-sha
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "DEXRELOAD the config-sha annotation matches the config actually shipped" {
  # THE test. If someone edits staticPasswords, staticClients, connectors or
  # anything else in config.yaml without bumping this annotation, the pod
  # template is byte-identical, no rollout happens, and Dex serves the old
  # config forever. That is exactly how the `viewer` identity went missing.
  actual="$(config_sha)"
  declared="$(annotation signalloom.ai/dex-config-sha)"
  if [ "$actual" != "$declared" ]; then
    echo "dex config.yaml changed but the rollout annotation was not bumped."
    echo "  declared: $declared"
    echo "  actual:   $actual"
    echo "Set signalloom.ai/dex-config-sha to the actual value, or Dex will keep"
    echo "serving its old in-memory config after this change is applied."
    return 1
  fi
}

@test "DEXRELOAD the ui-sha annotation matches the templates actually shipped" {
  # The web templates have the identical defect to config.yaml, and neither of
  # the annotations above covers them. Dex calls loadWebConfig ONCE in newServer
  # and keeps the parsed *template.Template on the server struct — no watcher,
  # no re-parse. Kubernetes swaps the mounted files underneath the process and
  # nothing in the Deployment changes, so no rollout fires.
  #
  # This was not hypothetical. error.html rendered {{ .Error }}, a field dex has
  # never passed it, so every dropped auth request returned a truncated 1.2KB
  # page whose entire visible text was the word "Error". Fixing the ConfigMap
  # alone would have shipped that fix to git and to the cluster and to nobody.
  actual="$(ui_sha)"
  declared="$(annotation signalloom.ai/dex-ui-sha)"
  if [ "$actual" != "$declared" ]; then
    echo "dex-ui templates changed but the rollout annotation was not bumped."
    echo "  declared: $declared"
    echo "  actual:   $actual"
    echo "Set signalloom.ai/dex-ui-sha to the actual value, or Dex will keep"
    echo "rendering the templates it parsed at boot and your change reaches no one."
    return 1
  fi
}

@test "DEXRELOAD the Dex pod template carries the substituted origin" {
  # A content hash CANNOT cover the origin: hashing happens before Flux's
  # postBuild substitution, so the bytes are identical for every possible
  # PUBLIC_ORIGIN. Only a substituted annotation makes the rendered pod
  # template differ per-origin and force the rollout.
  run annotation signalloom.ai/dex-origin
  [ "$status" -eq 0 ]
  case "$output" in
    *'${PUBLIC_ORIGIN'*) ;;
    *) echo "dex-origin annotation must track PUBLIC_ORIGIN, got: $output"; return 1 ;;
  esac
}

@test "DEXRELOAD the origin annotation defaults to the same value as the issuer" {
  # A different default here would restart Dex onto an origin the issuer never
  # agreed to — the annotation would be actively lying about what is running.
  ann="$(annotation signalloom.ai/dex-origin)"
  run grep -F 'issuer: ${PUBLIC_ORIGIN:=https://dashboard.osramp.acme.local:30754}/dex' "$dex_manifest"
  [ "$status" -eq 0 ]
  [ "$ann" = 'https://dashboard.osramp.acme.local:30754' ] || \
    [ "$ann" = '${PUBLIC_ORIGIN:=https://dashboard.osramp.acme.local:30754}' ]
}

@test "DEXRELOAD Dex still reads its config from a file, so the reload problem is real" {
  # If Dex ever gains a watcher, or the config moves to env vars, these
  # annotations become unnecessary ceremony. Pin the assumption so that change
  # is a deliberate one rather than something that quietly leaves dead config.
  run grep -F 'args: ["dex", "serve", "/etc/dex/config.yaml"]' "$dex_manifest"
  [ "$status" -eq 0 ]
}
