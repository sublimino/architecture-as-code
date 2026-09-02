#!/usr/bin/env bash
# scripts/netebpf-synthetic-generator.sh — Synthetic eBPF Socket Event Generator
# Emits JSON flow events and drop alerts for end-to-end testing and CI pipelines.

set -euo pipefail

COUNT="${1:-10}"
MODE="${2:-normal}" # normal, gap, or drop

cat << 'HEADER' > /dev/null
Synthetic eBPF Socket Event Generator
HEADER

seq_start=100
for ((i=1; i<=COUNT; i++)); do
  curr_seq=$((seq_start + i))
  if [[ "$MODE" == "gap" && i -eq 5 ]]; then
    # Skip sequence numbers to simulate gap
    curr_seq=$((curr_seq + 10))
    seq_start=$((seq_start + 10))
  fi

  provider="OpenAI"
  dst_ip="104.18.2.161"
  domain="api.openai.com"
  class="approved_model_egress"

  if (( i % 3 == 0 )); then
    provider="Anthropic"
    dst_ip="160.155.1.1"
    domain="api.anthropic.com"
  elif (( i % 5 == 0 )); then
    provider="C2_Exfiltration"
    dst_ip="198.51.100.42"
    domain="198.51.100.42"
    class="potential_exfiltration"
  fi

  cat << JSON
{
  "timestamp_ns": $(date +%s%N),
  "time": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "cgroup_id": 54321,
  "sock_cookie": $((1000 + i)),
  "seq_num": ${curr_seq},
  "src_ip": "10.244.0.22",
  "dst_ip": "${dst_ip}",
  "src_port": $((40000 + i)),
  "dst_port": 443,
  "family": 2,
  "bytes_sent": $((1024 * i)),
  "pod_name": "agent-cardvault-0",
  "pod_namespace": "fe-signalloom-agents",
  "pod_uid": "uid-cardvault-0",
  "service_account": "agent-cardvault-sa",
  "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
  "agent_role": "cardvault_operator",
  "provider": "${provider}",
  "classification": "${class}",
  "domain": "${domain}",
  "node_name": "osramp-control-plane"
}
JSON
done
