#!/usr/bin/env bats
#
# json-schema-lite.jq is the only schema validator an auditor runs over an
# evidence bundle, so every keyword it claims must be enforced, and every
# keyword it does not implement must be refused rather than silently ignored
# (an ignored keyword is a constraint the schema author believes holds and
# nothing checks).
#
# @target scripts/lib/json-schema-lite.jq
# @spec   schemas/eap-evidence-bundle-schema.json

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	lib="$root/scripts/lib/json-schema-lite.jq"
}

# validate SCHEMA DOC [PTR]: run the validator; $output is the violation list.
validate() {
	printf '%s' "$1" >"$BATS_TEST_TMPDIR/s.json"
	printf '%s' "$2" >"$BATS_TEST_TMPDIR/d.json"
	run jq -n -r --slurpfile schema "$BATS_TEST_TMPDIR/s.json" --slurpfile doc "$BATS_TEST_TMPDIR/d.json" \
		--arg ptr "${3:-#}" -f "$lib"
}

conforms() {
	validate "$@"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

violates() { # SCHEMA DOC EXPECTED-SUBSTRING
	validate "$1" "$2"
	[ "$status" -eq 0 ]
	[[ "$output" == *"$3"* ]]
}

@test "type: string, integer vs number, and type arrays" {
	conforms '{"type":"string"}' '"x"'
	violates '{"type":"string"}' '1' '$: expected type string, got number'
	conforms '{"type":"integer"}' '3'
	violates '{"type":"integer"}' '1.5' 'expected type integer, got number'
	conforms '{"type":"number"}' '1.5'
	conforms '{"type":["string","null"]}' 'null'
	violates '{"type":["string","null"]}' 'true' 'expected type string|null, got boolean'
	violates '{"type":"object"}' '[]' 'expected type object, got array'
}

@test "const and enum compare whole values" {
	conforms '{"const":"ed25519"}' '"ed25519"'
	violates '{"const":"ed25519"}' '"Ed25519"' 'must equal "ed25519"'
	conforms '{"enum":["a",{"k":1}]}' '{"k":1}'
	violates '{"enum":["a","b"]}' '"c"' 'must be one of ["a","b"]'
}

@test "pattern and minLength apply to strings only" {
	conforms '{"pattern":"^[0-9a-f]{64}$"}' "\"$(printf 'a%.0s' {1..64})\""
	violates '{"pattern":"^[0-9a-f]{64}$"}' "\"$(printf 'A%.0s' {1..64})\"" 'does not match'
	violates '{"minLength":2}' '"x"' 'shorter than 2'
	conforms '{"minLength":2,"pattern":"^x$"}' '5'
}

@test "minimum and maximum are inclusive bounds" {
	conforms '{"minimum":1,"maximum":3}' '1'
	conforms '{"minimum":1,"maximum":3}' '3'
	violates '{"minimum":1}' '0' 'below minimum 1'
	violates '{"maximum":3}' '4' 'above maximum 3'
}

@test "required, nested properties and additionalProperties=false" {
	s='{"type":"object","required":["a"],"additionalProperties":false,
	    "properties":{"a":{"type":"object","additionalProperties":false,"required":["b"],
	                       "properties":{"b":{"type":"integer"}}}}}'
	conforms "$s" '{"a":{"b":1}}'
	violates "$s" '{}' '$: missing required property a'
	violates "$s" '{"a":{"b":1},"z":0}' '$: unexpected property z'
	violates "$s" '{"a":{"b":1,"z":0}}' '$.a: unexpected property z'
	violates "$s" '{"a":{}}' '$.a: missing required property b'
	violates "$s" '{"a":{"b":"1"}}' '$.a.b: expected type integer, got string'
}

@test "items, minItems and maxItems check every element" {
	s='{"type":"array","minItems":1,"maxItems":2,"items":{"type":"string"}}'
	conforms "$s" '["x","y"]'
	violates "$s" '[]' 'fewer than 1 items'
	violates "$s" '["x","y","z"]' 'more than 2 items'
	violates "$s" '["x",2]' '$[1]: expected type string, got number'
}

@test "anyOf passes when any alternative passes, fails when none does" {
	s='{"anyOf":[{"required":["tenant"]},{"required":["tenant_id"]}]}'
	conforms "$s" '{"tenant_id":"kusari"}'
	violates "$s" '{"other":1}' 'matches none of the anyOf alternatives'
}

@test "\$ref resolves local pointers, including chains" {
	s='{"$defs":{"h":{"$ref":"#/$defs/hex"},"hex":{"type":"string","pattern":"^[0-9a-f]+$"}},
	    "type":"object","properties":{"d":{"$ref":"#/$defs/h"}}}'
	conforms "$s" '{"d":"ab"}'
	violates "$s" '{"d":"zz"}' '$.d: "zz" does not match'
}

@test "an unresolvable \$ref is a violation, not a crash or a pass" {
	violates '{"properties":{"d":{"$ref":"#/$defs/absent"}}}' '{"d":1}' 'unresolvable $ref #/$defs/absent'
	violates '{"properties":{"d":{"$ref":"https://example.com/s.json"}}}' '{"d":1}' 'unresolvable $ref https://example.com/s.json'
}

@test "an unsupported keyword is refused, never silently ignored" {
	for kw in '"maxLength":1' '"oneOf":[{"type":"string"}]' '"not":{"type":"string"}' \
		'"exclusiveMinimum":0' '"uniqueItems":true' '"format":"date-time"' '"allOf":[{}]'; do
		violates "{$kw}" '"xyz"' 'unsupported schema keyword'
	done
}

@test "additionalProperties other than false is refused" {
	violates '{"additionalProperties":{"type":"string"}}' '{"a":1}' 'unsupported schema keyword additionalProperties'
}

@test "\$ref with sibling constraints is refused (they would be dropped)" {
	violates '{"$defs":{"s":{"type":"string"}},"properties":{"d":{"$ref":"#/$defs/s","minLength":5}}}' \
		'{"d":"x"}' 'unsupported schema keyword'
}

@test "annotations and x- extensions are accepted" {
	conforms '{"title":"t","description":"d","$comment":"c","x-rawArtifacts":[],"type":"string"}' '"x"'
}

@test "a file holding more than one JSON document is a violation" {
	violates '{"type":"object"}' '{"a":1} {"b":2}' 'exactly one JSON document'
	violates '{"type":"object"}' '' 'exactly one JSON document'
}

@test "the committed bundle schema uses only supported keywords (every \$def validates cleanly)" {
	schema="$(cat "$root/schemas/eap-evidence-bundle-schema.json")"
	# A document of the wrong type exercises every keyword the validator visits
	# at the top of each definition; an unsupported one would be reported.
	for ptr in '#' '#/$defs/preflightManifest' '#/$defs/registryClaim' '#/$defs/ebpfObservation'; do
		validate "$schema" '{}' "$ptr"
		[ "$status" -eq 0 ]
		[[ "$output" != *"unsupported schema keyword"* ]]
		[[ "$output" != *"unresolvable"* ]]
	done
	for f in preflight-manifest.json:preflightManifest step2-registry-claim.json:registryClaim step4-ebpf-observation.json:ebpfObservation; do
		conforms "$schema" "$(cat "$root/test/fixtures/eap-evidence/${f%%:*}")" "#/\$defs/${f##*:}"
	done
}
