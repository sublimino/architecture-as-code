#!/usr/bin/env bats
# Recovered 2026-10-06 from integration/stun-under-flux (tip 5482e79b,
# STUN-P6-1 containment-evidence-ownership classification). Pure, offline,
# no cluster: proves the generator's own --check mode is non-vacuous — it
# must accept the committed pair and reject any divergence between the JSON
# source of record and its rendered markdown.
#
# @id      stun-evidence-ownership-generator
# @target  scripts/render-stun-evidence-ownership.mjs
# @doc     docs/signalloom/stun-evidence-ownership.md
# @spec    docs/signalloom/stun-evidence-ownership.json

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  generator="$root/scripts/render-stun-evidence-ownership.mjs"
  source_json="$root/docs/signalloom/stun-evidence-ownership.json"
  committed_md="$root/docs/signalloom/stun-evidence-ownership.md"
}

@test "EVIDENCE-OWNERSHIP-GEN committed markdown matches its JSON source of record" {
  run node "$generator" --check
  [ "$status" -eq 0 ]
}

@test "EVIDENCE-OWNERSHIP-GEN re-render is byte-identical to the committed file" {
  tmp_root="$BATS_TEST_TMPDIR/render-root"
  mkdir -p "$tmp_root/docs/signalloom" "$tmp_root/scripts"
  cp "$source_json" "$tmp_root/docs/signalloom/stun-evidence-ownership.json"
  cp "$generator" "$tmp_root/scripts/render-stun-evidence-ownership.mjs"
  run node "$tmp_root/scripts/render-stun-evidence-ownership.mjs"
  [ "$status" -eq 0 ]
  run diff "$committed_md" "$tmp_root/docs/signalloom/stun-evidence-ownership.md"
  [ "$status" -eq 0 ]
}

@test "EVIDENCE-OWNERSHIP-GEN --check rejects a divergent JSON source (fail/fix proof)" {
  tmp_root="$BATS_TEST_TMPDIR/divergent-root"
  mkdir -p "$tmp_root/docs/signalloom" "$tmp_root/scripts"
  jq '.introduction = "mutated for test"' "$source_json" >"$tmp_root/docs/signalloom/stun-evidence-ownership.json"
  cp "$committed_md" "$tmp_root/docs/signalloom/stun-evidence-ownership.md"
  cp "$generator" "$tmp_root/scripts/render-stun-evidence-ownership.mjs"

  # Red: the stale committed .md no longer matches the mutated .json.
  run node "$tmp_root/scripts/render-stun-evidence-ownership.mjs" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not generated from"* ]]

  # Green: regenerating from the mutated source makes --check pass again.
  run node "$tmp_root/scripts/render-stun-evidence-ownership.mjs"
  [ "$status" -eq 0 ]
  run node "$tmp_root/scripts/render-stun-evidence-ownership.mjs" --check
  [ "$status" -eq 0 ]
}
