#!/usr/bin/env bats
# Runtime proof only. It does not deploy SuperCred resources: run
# `make demo-signalloom-supercred-1` explicitly before this target.

NAMESPACE_INFRA="inf-signalloom"
NAMESPACE_AGENTS="fe-signalloom-agents"

@test "SuperCred step one makes Cardvault available" {
	run kubectl -n "$NAMESPACE_INFRA" wait deployment/cardvault \
		--for=condition=available --timeout=30s
	[ "$status" -eq 0 ]
}

@test "SuperCred step one makes agent-cardvault available" {
	run kubectl -n "$NAMESPACE_AGENTS" wait pod/agent-cardvault \
		--for=condition=Ready --timeout=30s
	[ "$status" -eq 0 ]
}
