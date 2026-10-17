#!/usr/bin/env python3
"""A store-backed fake of the `bao` CLI's generic list/read/write verbs.

Used by test/openbao-migrate.bats as BOTH the retiring dev server and the new
persistent server (two store files). Only the shapes scripts/openbao-migrate.sh
uses are modelled:

  list  -format=json PATH        -> JSON array of child keys ("dir/" for dirs); exit 2 if none
  read  -format=json PATH        -> {"data": ...}; exit 2 if missing
  write PATH -                   -> JSON object on stdin
  status                         -> exit 0, or FAKE_BAO_DOWN=1 -> exit 1

Store file (FAKE_BAO_STORE): {"mounts": {"kv/": {...}}, "auth": {"jwt/": {...}},
"paths": {"kv/data/a/b": {...}, "sys/policies/acl/x": {"policy": "..."}, ...}}
Every write is appended to FAKE_BAO_STORE + ".writes" so a test can count them.
"""
import json
import os
import sys

store_path = os.environ["FAKE_BAO_STORE"]
if os.environ.get("FAKE_BAO_DOWN") == "1":
    print("Error: dial tcp: connection refused", file=sys.stderr)
    sys.exit(1)

with open(store_path) as fh:
    store = json.load(fh)
store.setdefault("mounts", {})
store.setdefault("auth", {})
store.setdefault("paths", {})

args = [a for a in sys.argv[1:] if a != "-format=json"]
verb = args[0] if args else ""


def save():
    with open(store_path, "w") as fh:
        json.dump(store, fh, sort_keys=True)


def missing():
    print("No value found", file=sys.stderr)
    sys.exit(2)


if verb == "status":
    sys.exit(0)

if verb == "list":
    path = args[1].rstrip("/")
    parts = path.split("/")
    if len(parts) >= 2 and parts[1] == "metadata":
        prefix = parts[0] + "/data/" + "/".join(parts[2:])
    else:
        prefix = path
    prefix = prefix.rstrip("/") + "/"
    children = set()
    for p in store["paths"]:
        if p.startswith(prefix):
            rest = p[len(prefix):]
            head, _, tail = rest.partition("/")
            children.add(head + "/" if tail else head)
    if not children:
        missing()
    print(json.dumps(sorted(children)))
    sys.exit(0)

if verb == "read":
    path = args[1]
    if path == "sys/mounts":
        print(json.dumps({"data": store["mounts"]}))
        sys.exit(0)
    if path == "sys/auth":
        print(json.dumps({"data": store["auth"]}))
        sys.exit(0)
    if path not in store["paths"]:
        missing()
    value = store["paths"][path]
    parts = path.split("/")
    if len(parts) >= 2 and parts[1] == "data":
        print(json.dumps({"data": {"data": value, "metadata": {"version": 1}}}))
    else:
        print(json.dumps({"data": value}))
    sys.exit(0)

if verb == "write":
    path = args[1]
    body = json.load(sys.stdin) if len(args) > 2 and args[2] == "-" else {}
    with open(store_path + ".writes", "a") as fh:
        fh.write(path + "\n")
    if path.startswith("sys/mounts/"):
        store["mounts"][path[len("sys/mounts/"):].rstrip("/") + "/"] = body
    elif path.startswith("sys/auth/"):
        store["auth"][path[len("sys/auth/"):].rstrip("/") + "/"] = body
    else:
        parts = path.split("/")
        if len(parts) >= 2 and parts[1] == "data":
            store["paths"][path] = body.get("data", {})
        else:
            store["paths"][path] = body
    save()
    sys.exit(0)

print("fake bao: unsupported: " + " ".join(sys.argv[1:]), file=sys.stderr)
sys.exit(64)
