#!/usr/bin/env bats
#
# The acceptance harness used `nc -z` as proof that localhost:30754 belonged to
# its Gateway forward. A gcloud IAP tunnel can hold that port and answer the
# dashboard health endpoint, so the harness tested a foreign listener. It also
# recorded preflight failure but launched Playwright regardless.

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	script="$root/scripts/acceptance-test.sh"
	bin="$BATS_TEST_TMPDIR/bin"
	marker="$BATS_TEST_TMPDIR/playwright-ran"
	kubectl_log="$BATS_TEST_TMPDIR/kubectl.log"
	gateway_terminated="$BATS_TEST_TMPDIR/gateway-terminated"
	mkdir -p "$bin"

	cat >"$bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_LOG"
case " $* " in
  *" get service -A "*)
    [ "${FAKE_REQUIRE_INGRESS_NAMESPACE:-0}" = 1 ] && exit 1
    printf 'gateway-ns gateway-svc\n'
    ;;
  *" -n ingress get service "*) printf 'gateway-ns gateway-svc\n' ;;
  *" get service gateway-svc "*) printf '31443' ;;
  *" get nodes "*) printf '172.18.0.2' ;;
  *" get svc "*|*" get deployment "*) exit 1 ;;
  *" port-forward "*) args="$*"; trap 'case "$args" in *gateway-svc*) : >"$GATEWAY_TERMINATED" ;; esac; exit 0' TERM INT; while :; do sleep 1; done ;;
esac
FAKE
	cat >"$bin/curl" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
  *"/readyz"*) printf 'ready\n'; exit 0 ;;
  *"/livez"*) exit "${FAKE_LIVEZ_STATUS:-0}" ;;
  *"openid-configuration"*) exit 0 ;;
esac
exit 0
FAKE

	cat >"$bin/nc" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
  *" 30754"*)
    [ "${FAKE_STALE_IAP_CHILD_KILLED:-0}" = 1 ] && exit 1
    exit "${FAKE_GATEWAY_PORT_BUSY:-1}"
    ;;
esac
exit 1
FAKE

	cat >"$bin/bunx" <<'FAKE'
#!/usr/bin/env bash
: >"$PLAYWRIGHT_MARKER"
exit 0
FAKE

	cat >"$bin/doctor.sh" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
	chmod +x "$bin"/*
	export PATH="$bin:$PATH"
	export PLAYWRIGHT_MARKER="$marker"
	export KUBECTL_LOG="$kubectl_log"
	export GATEWAY_TERMINATED="$gateway_terminated"
	# Keep the existing generic forward wait from dominating this focused test.
	export WAIT_TIMEOUT=1
}

teardown() {
	pkill -f "${bin}/kubectl" 2>/dev/null || true
}

@test "a foreign listener on 30754 is rejected before Gateway forwarding or Playwright" {
	run env FAKE_GATEWAY_PORT_BUSY=0 "$script" signalloom-test-1.spec.ts
	[ "$status" -ne 0 ]
	[[ "$output" == *"ERROR: localhost:30754 is already listening; refusing to adopt an unowned Gateway forward"* ]]
	[ ! -e "$marker" ]
	[ -z "$(grep 'port-forward.*svc/gateway-svc.*30754:443' "$kubectl_log" || true)" ]
}

@test "a failing Gateway TLS preflight prevents Playwright invocation" {
	run env FAKE_LIVEZ_STATUS=22 "$script" signalloom-test-1.spec.ts
	[ "$status" -ne 0 ]
	[[ "$output" == *"ERROR: shared Gateway is not reachable"* ]]
	[ ! -e "$marker" ]
}

@test "a healthy Gateway preflight permits Playwright invocation" {
	run "$script" signalloom-test-1.spec.ts
	[ "$status" -eq 0 ]
	[ -e "$marker" ]
	[ -e "$gateway_terminated" ]
}

@test "Gateway discovery requires only ingress namespace Service access" {
	run env FAKE_REQUIRE_INGRESS_NAMESPACE=1 "$script" signalloom-test-1.spec.ts
	[ "$status" -eq 0 ]
	[ -e "$marker" ]
	grep -F -- '-n ingress get service -l gateway.envoyproxy.io/owning-gateway-name=cluster' "$kubectl_log"
}

@test "a killed stale IAP child permits an owned Gateway forward" {
	run env FAKE_STALE_IAP_CHILD_KILLED=1 "$script" signalloom-test-1.spec.ts
	[ "$status" -eq 0 ]
	[ -e "$marker" ]
	grep -E -- 'port-forward.*svc/gateway-svc.*30754:443' "$kubectl_log"
}
