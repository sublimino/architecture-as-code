# json-schema-lite.jq: a deliberately small JSON Schema validator so an
# auditor can check an SLDC evidence bundle with jq alone (no python
# jsonschema, no node ajv, no network).
#
# Supported keywords: $ref (local "#/..." pointers only), type, const, enum,
# pattern, minLength, minimum, maximum, required, properties,
# additionalProperties (false only), items, minItems, maxItems, anyOf.
# Annotations (title, description, $comment, $schema, $id, $defs, x-*) are
# accepted. Any other keyword, a $ref with sibling keywords, or a $ref that
# does not resolve is reported as a violation: a constraint this validator
# cannot enforce must never pass silently.
#
# Usage (every input via --slurpfile, so no document ever travels in argv):
#   jq -n -r --slurpfile schema S.json --slurpfile doc D.json \
#      --arg ptr '#/$defs/name' -f scripts/lib/json-schema-lite.jq
# Prints one line per violation; prints nothing when the document conforms.
# --arg ptr '#' validates against the root schema.

def pointer_path: ltrimstr("#") | ltrimstr("/") | if . == "" then [] else split("/") end;

def annotations: ["title", "description", "$comment", "$schema", "$id", "$defs"];

def supported:
  annotations + ["type", "const", "enum", "pattern", "minLength", "minimum", "maximum",
                 "required", "properties", "additionalProperties", "items", "minItems",
                 "maxItems", "anyOf"];

# Resolve local $refs; an unresolvable one becomes {"$unresolved": ref}.
def resolve($root):
  if type == "object" and has("$ref") then
    .["$ref"] as $r
    | (if ($r | type) == "string" and ($r | startswith("#")) then $root | getpath($r | pointer_path) else null end) as $t
    | if $t == null then {"$unresolved": $r} else $t | resolve($root) end
  else . end;

def unsupported_keywords:
  if has("$ref") then
    [keys[] | select(. != "$ref" and (. as $k | annotations | index($k) | not))]
  else
    [keys[] | select((startswith("x-") | not) and (. as $k | supported | index($k) | not))]
    + (if has("additionalProperties") and .additionalProperties != false then ["additionalProperties"] else [] end)
  end;

def json_types:
  if type == "number" and . == floor then ["integer", "number"] else [type] end;

def check($root; $schema; $v; $p):
  if ($schema | type) == "object" and ($schema | unsupported_keywords | length) > 0 then
    "\($p): unsupported schema keyword \($schema | unsupported_keywords | join(", "))"
  else
  ($schema | resolve($root)) as $s
  | if ($s | type) == "object" and ($s | has("$unresolved")) then "\($p): unresolvable $ref \($s["$unresolved"])"
    elif ($s | type) != "object" then "\($p): schema node is not an object"
    elif ($s | unsupported_keywords | length) > 0 then
      "\($p): unsupported schema keyword \($s | unsupported_keywords | join(", "))"
    else
  (
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
    )
    end
  end;

$schema[0] as $root
| if ($doc | length) != 1 then "$: expected exactly one JSON document, got \($doc | length)"
  else check($root; {"$ref": $ptr}; $doc[0]; "$") end
