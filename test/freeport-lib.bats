#!/usr/bin/env bats
# @id     freeport-lib
# @target test/lib/freeport.bash
# @doc    docs/signalloom/runbooks/parallel-tests.md

setup() {
  load "${BATS_TEST_DIRNAME}/lib/freeport.bash"
}

@test "freeport: free_port returns one bindable port" {
  port="$(free_port)"
  [[ "$port" =~ ^[0-9]+$ ]]
  [ "$port" -ge 1024 ]
  [ "$port" -le 65535 ]
  # bindable is the actual claim, so bind it
  run python3 -c "import socket,sys
s=socket.socket(); s.bind(('127.0.0.1', int(sys.argv[1]))); s.close()" "$port"
  [ "$status" -eq 0 ]
}

@test "freeport: free_port N returns N distinct ports" {
  read -r -a ports <<<"$(free_port 5)"
  [ "${#ports[@]}" -eq 5 ]
  uniq_count="$(printf '%s\n' "${ports[@]}" | sort -u | wc -l | tr -d ' ')"
  [ "$uniq_count" -eq 5 ]
}

@test "freeport: FREE_PORT_EXCLUDE is never handed out" {
  held="$(free_port)"
  FREE_PORT_EXCLUDE="$held" read -r -a ports <<<"$(FREE_PORT_EXCLUDE="$held" free_port 10)"
  for p in "${ports[@]}"; do
    [ "$p" != "$held" ]
  done
}

@test "freeport: the bash fallback probe also returns a plausible port" {
  port="$(_free_port_probe)"
  [[ "$port" =~ ^[0-9]+$ ]]
  [ "$port" -ge 20000 ]
  [ "$port" -lt 60000 ]
}

@test "freeport: free_port does not return a port that is currently bound" {
  # The honest form of the claim: take a port, BIND it, then ask again and
  # require a different answer. A free_port that returns a constant passes a
  # "does not equal this one random held port" check by luck; it cannot pass
  # this one.
  first="$(free_port)"
  python3 -c 'import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1)
print("bound", flush=True)
time.sleep(30)' "$first" >"${BATS_TEST_TMPDIR}/bound" &
  holder=$!
  for _ in $(seq 1 100); do [ -s "${BATS_TEST_TMPDIR}/bound" ] && break; sleep 0.05; done
  [ -s "${BATS_TEST_TMPDIR}/bound" ]
  read -r -a ports <<<"$(free_port 10)"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  for p in "${ports[@]}"; do
    [ "$p" != "$first" ]
  done
}

@test "freeport: wait_for_port succeeds against a live listener and fails on a dead port" {
  python3 -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1",0)); s.listen(1)
print(s.getsockname()[1], flush=True)
time.sleep(30)' >"${BATS_TEST_TMPDIR}/live" &
  holder=$!
  for _ in $(seq 1 100); do [ -s "${BATS_TEST_TMPDIR}/live" ] && break; sleep 0.05; done
  live="$(cat "${BATS_TEST_TMPDIR}/live")"
  run wait_for_port 127.0.0.1 "$live" 5
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]

  dead="$(free_port)"
  run wait_for_port 127.0.0.1 "$dead" 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"never accepted"* ]]
}

@test "freeport: wait_for_listen observes a one-shot listener without consuming it" {
  command -v nc >/dev/null || skip "nc unavailable"
  port="$(free_port)"
  # `nc -l` without -k accepts exactly one connection and exits. A readiness
  # probe that DIALS would eat it; wait_for_listen must not.
  nc -l 127.0.0.1 "$port" </dev/null >/dev/null 2>&1 &
  pid=$!
  run wait_for_listen "$port" 5
  [ "$status" -eq 0 ]
  # still listening after the probe -- this is the whole point
  run bash -c "ss -tlnH | awk '{print \$4}' | grep -qE ':${port}\$'"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "freeport: wait_for_listen fails on a port nothing is bound to" {
  port="$(free_port)"
  run wait_for_listen "$port" 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing listening"* ]]
}
