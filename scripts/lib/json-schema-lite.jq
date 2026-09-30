# json-schema-lite.jq: a deliberately small JSON Schema validator so an
# auditor can check an SLDC evidence bundle with jq alone (no python
# jsonschema, no node ajv, no network).
#
# Supported keywords: $ref (local "#/..." pointers only), type, const, enum,
# pattern, minLength, minimum, maximum, required, properties,
# additionalProperties (false only), items, minItems, maxItems, anyOf.
# Any other keyword is ignored, so schemas/eap-evidence-bundle-schema.json
# must stay inside this subset.
#
# Usage (every input via --slurpfile, so no document ever travels in argv):
#   jq -n -r --slurpfile schema S.json --slurpfile doc D.json \
#      --arg ptr '#/$defs/name' -f scripts/lib/json-schema-lite.jq
# Prints one line per violation; prints nothing when the document conforms.
# --arg ptr '#' validates against the root schema.

def pointer_path: ltrimstr("#") | ltrimstr("/") | if . == "" then [] else split("/") end;

def resolve($root):
  if type == "object" and has("$ref") then (.["$ref"] | pointer_path) as $path | $root | getpath($path) | resolve($root)
  else . end;

def json_types:
  if type == "number" and . == floor then ["integer", "number"] else [type] end;

def check($root; $schema; $v; $p):
  ($schema | resolve($root)) as $s
  | (
      (if $s | has("type") then
         ($s.type | if type == "array" then . else [.] end) as $want
         | ($v | json_types) as $have
         | if any($want[]; . as $t | $have | index($t)) then empty
           else "\($p): expected type \($want | join("|")), got \($v | type)" end
       else empty end),
      (if $s | has("const") then
         if $v == $s.const then empty else "\($p): must equal \($s.const | tojson)" end
       else empty end),
      (if $s | has("enum") then
         if any($s.enum[]; . == $v) then empty else "\($p): must be one of \($s.enum | tojson)" end
       else empty end),
      (if ($v | type) == "string" then
         (if $s | has("pattern") then
            if $v | test($s.pattern) then empty else "\($p): \($v | tojson) does not match \($s.pattern)" end
          else empty end),
         (if $s | has("minLength") then
            if ($v | length) >= $s.minLength then empty else "\($p): shorter than \($s.minLength)" end
          else empty end)
       else empty end),
      (if ($v | type) == "number" then
         (if $s | has("minimum") then
            if $v >= $s.minimum then empty else "\($p): below minimum \($s.minimum)" end
          else empty end),
         (if $s | has("maximum") then
            if $v <= $s.maximum then empty else "\($p): above maximum \($s.maximum)" end
          else empty end)
       else empty end),
      (if ($v | type) == "object" then
         (($s.required // [])[] as $k
           | if $v | has($k) then empty else "\($p): missing required property \($k)" end),
         (($s.properties // {}) | to_entries[] as $e
           | if $v | has($e.key) then check($root; $e.value; $v[$e.key]; "\($p).\($e.key)") else empty end),
         (if $s.additionalProperties == false then
            ($v | keys[]) as $k
            | if ($s.properties // {}) | has($k) then empty else "\($p): unexpected property \($k)" end
          else empty end)
       else empty end),
      (if ($v | type) == "array" then
         (if $s | has("minItems") then
            if ($v | length) >= $s.minItems then empty else "\($p): fewer than \($s.minItems) items" end
          else empty end),
         (if $s | has("maxItems") then
            if ($v | length) <= $s.maxItems then empty else "\($p): more than \($s.maxItems) items" end
          else empty end),
         (if $s | has("items") then
            $v | to_entries[] as $e | check($root; $s.items; $e.value; "\($p)[\($e.key)]")
          else empty end)
       else empty end),
      (if $s | has("anyOf") then
         if any($s.anyOf[]; . as $sub | [check($root; $sub; $v; $p)] | length == 0) then empty
         else "\($p): matches none of the anyOf alternatives" end
       else empty end)
    );

$schema[0] as $root
| check($root; ($root | getpath($ptr | pointer_path)); $doc[0]; "$")
