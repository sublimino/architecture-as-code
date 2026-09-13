"""Generate complete TypeScript wire types from every external-agent schema."""
from __future__ import annotations
import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / "signal-ingest/collectors/agentnono/contracts"
OUTPUT = ROOT / "dashboard-signalloom/src/types/externalAgent.ts"

def schemas() -> list[tuple[Path, dict[str, Any]]]:
    return [(path, json.loads(path.read_text())) for path in sorted(CONTRACTS.glob("external-agent-*.schema.json"))]

def pascal(value: str) -> str:
    return "".join(part[:1].upper() + part[1:] for part in re.split(r"[^A-Za-z0-9]+", value) if part)

def literal(value: Any) -> str:
    if value is None: return "null"
    if value is True: return "true"
    if value is False: return "false"
    return json.dumps(value, separators=(",", ":"))

def referenced_type(ref: str, local_defs: dict[str, str], titles: dict[str, str]) -> str:
    if ref.startswith("#/$defs/"):
        return local_defs[ref.rsplit("/", 1)[-1]]
    filename, _, fragment = ref.partition("#")
    if fragment.startswith("/$defs/"):
        return pascal(titles[filename] + " " + fragment.rsplit("/", 1)[-1])
    return titles[filename]

def array_type(schema: dict[str, Any], local_defs: dict[str, str], titles: dict[str, str]) -> str:
    if "prefixItems" in schema:
        return "readonly [" + ", ".join(ts_type(item, local_defs, titles) for item in schema["prefixItems"]) + "]"
    return "ReadonlyArray<" + ts_type(schema.get("items", {}), local_defs, titles) + ">"

def ts_type(schema: dict[str, Any], local_defs: dict[str, str], titles: dict[str, str]) -> str:
    if "$ref" in schema:
        return referenced_type(schema["$ref"], local_defs, titles)
    if "const" in schema: return literal(schema["const"])
    if "enum" in schema: return " | ".join(literal(value) for value in schema["enum"])
    if "oneOf" in schema: return " | ".join(ts_type(item, local_defs, titles) for item in schema["oneOf"])
    kind = schema.get("type")
    if isinstance(kind, list): return " | ".join("null" if item == "null" else ts_type({"type": item}, local_defs, titles) for item in kind)
    simple = {"string": "string", "integer": "number", "number": "number", "boolean": "boolean", "null": "null"}
    if kind in simple: return simple[kind]
    if kind == "array": return array_type(schema, local_defs, titles)
    if kind == "object": return "Record<string, unknown>"
    return "unknown"

def object_block(name: str, schema: dict[str, Any], local_defs: dict[str, str], titles: dict[str, str]) -> str:
    required = set(schema.get("required", []))
    lines = [f"export interface {name} {{"]
    for field, field_schema in schema.get("properties", {}).items():
        optional = "" if field in required else "?"
        lines.append(f"  {field}{optional}: {ts_type(field_schema, local_defs, titles)}")
    lines.append("}")
    return "\n".join(lines)

def merge_property_schema(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    shape_keywords = {"$ref", "type", "const", "enum", "oneOf", "anyOf", "allOf"}
    merged = dict(base)
    if shape_keywords.intersection(override):
        for keyword in shape_keywords:
            merged.pop(keyword, None)
    merged.update(override)
    return merged

def one_of_object_blocks(name: str, schema: dict[str, Any], local_defs: dict[str, str], titles: dict[str, str]) -> list[str] | None:
    variants: list[tuple[str, dict[str, Any]]] = []
    for branch in schema.get("oneOf", []):
        properties = branch.get("properties")
        if not isinstance(properties, dict):
            return None
        discriminator = next((value["const"] for value in properties.values() if isinstance(value, dict) and isinstance(value.get("const"), str)), None)
        if discriminator is None:
            return None
        base_properties = schema.get("properties", {})
        merged_properties = dict(base_properties)
        for field, override in properties.items():
            merged_properties[field] = merge_property_schema(base_properties.get(field, {}), override)
        merged = {
            **schema,
            "properties": merged_properties,
            "required": list(dict.fromkeys([*schema.get("required", []), *branch.get("required", [])])),
        }
        variants.append((name + pascal(discriminator), merged))
    if not variants:
        return None
    blocks = [object_block(variant_name, variant, local_defs, titles) for variant_name, variant in variants]
    blocks.append(f"export type {name} = " + " | ".join(variant_name for variant_name, _ in variants))
    return blocks

def discriminated_object_blocks(name: str, schema: dict[str, Any], local_defs: dict[str, str], titles: dict[str, str]) -> list[str]:
    one_of_blocks = one_of_object_blocks(name, schema, local_defs, titles)
    if one_of_blocks is not None:
        return one_of_blocks
    variants: list[tuple[str, dict[str, Any]]] = []
    for rule in schema.get("allOf", []):
        discriminator = rule.get("if", {}).get("properties", {}).get("evidence_type", {})
        value = discriminator.get("const")
        overrides = rule.get("then", {}).get("properties", {})
        if not isinstance(value, str) or "attributes" not in overrides:
            continue
        properties = dict(schema.get("properties", {}))
        properties["evidence_type"] = {"const": value}
        properties.update(overrides)
        variant_name = name + pascal(value) + "Evidence"
        variants.append((variant_name, {**schema, "properties": properties}))
    if not variants:
        return [object_block(name, schema, local_defs, titles)]
    blocks = [object_block(variant_name, variant, local_defs, titles) for variant_name, variant in variants]
    blocks.append(f"export type {name} = " + " | ".join(variant_name for variant_name, _ in variants))
    return blocks

def render() -> str:
    loaded = schemas()
    titles = {path.name: schema["title"] for path, schema in loaded}
    digest = hashlib.sha256(b"".join(path.name.encode() + b"\0" + path.read_bytes() + b"\0" for path, _ in loaded)).hexdigest()
    blocks = ["// Generated by generate_external_agent_types.py; DO NOT EDIT.", f"// schemas-sha256: {digest}"]
    for path, schema in loaded:
        title = schema["title"]
        local_defs = {key: pascal(title + " " + key) for key in schema.get("$defs", {})}
        for key, definition in schema.get("$defs", {}).items():
            name = local_defs[key]
            if definition.get("type") == "object": blocks.extend(discriminated_object_blocks(name, definition, local_defs, titles))
            else: blocks.append(f"export type {name} = {ts_type(definition, local_defs, titles)}")
        if schema.get("type") == "object": blocks.extend(discriminated_object_blocks(title, schema, local_defs, titles))
        else: blocks.append(f"export type {title} = {ts_type(schema, local_defs, titles)}")
    return "\n\n".join(blocks) + "\n"

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generated = render()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != generated:
            print(f"generated contract drift: {OUTPUT}")
            return 1
        return 0
    OUTPUT.write_text(generated)
    return 0

if __name__ == "__main__": raise SystemExit(main())
