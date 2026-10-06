#!/usr/bin/env bash
# Pure classifier for docs/signalloom/evidence/severance-probe-contract.json.
# Reads one record from stdin. It performs no cluster, process, or network I/O.

set -uo pipefail

emit_severed() {
  printf 'SEVERED\n'
  exit 0
}

emit_survived() {
  printf 'SURVIVED\n'
  exit 0
}

emit_unverified() {
  printf 'UNVERIFIED\n'
  exit 3
}

command -v jq >/dev/null 2>&1 || emit_unverified

record="$(</dev/stdin)"

# The witness is mandatory: absence cannot mean severance.
if ! jq -e 'type == "object" and has("witnessStream")' >/dev/null 2>&1 <<<"$record"; then
  emit_unverified
fi

classification="$({ jq -er '
  def nonempty_string:
    type == "string" and length > 0;

  def nonnegative_integer:
    type == "number" and floor == . and . >= 0;

  def positive_integer:
    type == "number" and floor == . and . >= 1;

  def arrival_shape:
    type == "object"
    and (keys_unsorted | sort) == ["receivedAt", "sequence"]
    and (.sequence | positive_integer)
    and (.receivedAt | nonempty_string);

  def stream_shape:
    type == "object"
    and (keys_unsorted | sort) == ["arrivals", "expectedCount", "receiverPod", "senderPod"]
    and (.senderPod | nonempty_string)
    and (.receiverPod | nonempty_string)
    and (.expectedCount | positive_integer)
    and (.arrivals | type == "array")
    and all(.arrivals[]; arrival_shape);

  def monotonic_arrivals:
    .arrivals as $arrivals
    | (($arrivals | length) == 0)
      or (
        $arrivals[0].sequence == 1
        and (reduce range(1; $arrivals | length) as $index
          (true; . and ($arrivals[$index].sequence == ($arrivals[$index - 1].sequence + 1))))
      );

  def healthy_witness:
    stream_shape
    and monotonic_arrivals
    and ((.arrivals | length) >= .expectedCount);

  def healthy_target:
    stream_shape
    and monotonic_arrivals
    and ((.arrivals | length) > 0);

  def silent_target:
    stream_shape and ((.arrivals | length) == 0);

  def conntrack_shape:
    type == "object"
    and (keys_unsorted | sort) == ["observedAt", "present"]
    and (.present | type == "boolean")
    and (.observedAt | nonempty_string);

  def counters_shape:
    type == "object"
    and (keys_unsorted | sort) == ["afterPackets", "beforePackets"]
    and (.beforePackets | nonnegative_integer)
    and (.afterPackets | nonnegative_integer);

  def restart_shape:
    type == "object"
    and (keys_unsorted | sort) == ["after", "before"]
    and (.before | nonnegative_integer)
    and (.after | nonnegative_integer);

  def required_fields:
    [
      "schemaVersion", "capturedAt", "cni", "cniVersion", "targetPod",
      "targetUID", "targetIP", "vethIfindex", "cgroupPath", "frozen",
      "witnessStream", "targetStream", "conntrackBefore", "conntrackAfter",
      "tcDropCounters", "verdict", "verdictReason", "clockId", "restartCount"
    ] as $required
    | (keys_unsorted | sort) == ($required | sort);

  . as $record
  | if (
      (type != "object")
      or (required_fields | not)
      or (.schemaVersion != "1.0.0")
      or (.capturedAt | nonempty_string | not)
      or (.cni | nonempty_string | not)
      or (.cniVersion | nonempty_string | not)
      or (.targetPod | nonempty_string | not)
      or (.targetUID | nonempty_string | not)
      or (.targetIP | nonempty_string | not)
      or (.vethIfindex | positive_integer | not)
      or (.cgroupPath | nonempty_string | not)
      or (.frozen != true)
      or (.clockId | nonempty_string | not)
      or (.conntrackBefore | conntrack_shape | not)
      or (.conntrackAfter | conntrack_shape | not)
      or (.tcDropCounters | counters_shape | not)
      or (.restartCount | restart_shape | not)
      or (.restartCount.before != .restartCount.after)
      or (.witnessStream | stream_shape | not)
      or (.targetStream | stream_shape | not)
      or (.witnessStream.senderPod == .targetPod)
      or (.targetStream.senderPod != .targetPod)
      or (.witnessStream.receiverPod != .targetStream.receiverPod)
      or ((["SEVERED", "SURVIVED", "UNVERIFIED"] | index($record.verdict)) == null)
    ) then
      "UNVERIFIED"
    elif (
      (.witnessStream | healthy_witness)
      and (.targetStream | silent_target)
      and (.conntrackBefore.present == true)
      and (.conntrackAfter.present == false)
      and (.tcDropCounters.afterPackets > .tcDropCounters.beforePackets)
    ) then
      "SEVERED"
    elif (
      (.witnessStream | healthy_witness)
      and (.targetStream | healthy_target)
      and (.conntrackAfter.present == true)
      and (.tcDropCounters.afterPackets == .tcDropCounters.beforePackets)
    ) then
      "SURVIVED"
    else
      "UNVERIFIED"
    end
  | . as $computed
  | if (
      $computed == "SEVERED"
      and $record.verdict == "SEVERED"
      and $record.verdictReason == "witness-healthy-target-silent-kernel-severed"
    ) then "SEVERED"
    elif (
      $computed == "SURVIVED"
      and $record.verdict == "SURVIVED"
      and $record.verdictReason == "witness-healthy-target-arrivals-observed"
    ) then "SURVIVED"
    elif (
      $computed == "UNVERIFIED"
      and $record.verdict == "UNVERIFIED"
      and $record.verdictReason == "insufficient-or-conflicting-evidence"
    ) then "UNVERIFIED"
    else "UNVERIFIED"
    end
' --argjson record "$record" <<<"$record"; })" || emit_unverified

case "$classification" in
  SEVERED) emit_severed ;;
  SURVIVED) emit_survived ;;
  UNVERIFIED) emit_unverified ;;
  *) emit_unverified ;;
esac
