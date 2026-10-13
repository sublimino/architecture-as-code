#!/usr/bin/env python3
"""Convert raw Kubernetes RBAC JSON (kubectl get ... -o json) to KubeSec-AFM import format.

Usage:
    kubectl get clusterroles,clusterrolebindings,roles,rolebindings -A -o json | python3 scripts/rbac-to-afm.py
    python3 scripts/rbac-to-afm.py < /path/to/rbac.json

Output: JSON suitable for POST to /clusters/import with Content-Type: application/json.
"""
import argparse
import json
import sys


def convert(k8s_list: dict, cluster_id: str = "local", cluster_name: str = "Local Cluster") -> dict:
    items = k8s_list.get("items") or []
    subjects_seen: dict[str, dict] = {}
    roles: list[dict] = []
    bindings: list[dict] = []

    for item in items:
        if not isinstance(item, dict):
            continue
        kind = item.get("kind", "")
        meta = item.get("metadata") or {}
        name = meta.get("name", "")
        namespace = meta.get("namespace", "")

        if kind in ("ClusterRole", "Role"):
            scope = "Cluster" if kind == "ClusterRole" else "Namespace"
            rules_raw = item.get("rules") or []
            rules = []
            for r in rules_raw:
                if not isinstance(r, dict):
                    continue
                rules.append({
                    "verbs": r.get("verbs") or [],
                    "apiGroups": r.get("apiGroups") or [""],
                    "resources": r.get("resources") or [],
                })
            role = {"name": name, "scope": scope, "rules": rules}
            if scope == "Namespace":
                role["namespace"] = namespace
            roles.append(role)

        elif kind in ("ClusterRoleBinding", "RoleBinding"):
            scope = "Cluster" if kind == "ClusterRoleBinding" else "Namespace"
            role_ref = item.get("roleRef") or {}
            role_ref_name = role_ref.get("name", "")
            binding_subjects = item.get("subjects") or []
            afm_subjects = []
            for s in binding_subjects:
                if not isinstance(s, dict):
                    continue
                sk = s.get("kind", "User")
                sn = s.get("name", "")
                sns = s.get("namespace", "")
                key = f"{sk}/{sns}/{sn}" if sns else f"{sk}/{sn}"
                if key not in subjects_seen:
                    subj = {"name": sn, "kind": sk}
                    if sk == "ServiceAccount" and sns:
                        subj["namespace"] = sns
                    subjects_seen[key] = subj
                entry = {"kind": sk, "name": sn}
                if sns:
                    entry["namespace"] = sns
                afm_subjects.append(entry)
            binding = {
                "name": name,
                "scope": scope,
                "roleRef": role_ref_name,
                "subjects": afm_subjects,
            }
            if scope == "Namespace":
                binding["namespace"] = namespace
            bindings.append(binding)

    return {
        "id": cluster_id,
        "name": cluster_name,
        "rbac": {
            "subjects": list(subjects_seen.values()),
            "roles": roles,
            "bindings": bindings,
        },
    }


def main():
    parser = argparse.ArgumentParser(description="Convert raw Kubernetes RBAC JSON to KubeSec-AFM import format.")
    parser.add_argument("--cluster-id", default="local", help="Cluster identifier (default: local)")
    parser.add_argument("--cluster-name", default="Local Cluster", help="Cluster display name (default: Local Cluster)")
    parser.add_argument("file", nargs="?", default="-", help="Input JSON file or '-' for stdin (default: -)")
    args = parser.parse_args()

    if args.file == "-":
        data = json.load(sys.stdin)
    else:
        with open(args.file, "r", encoding="utf-8") as f:
            data = json.load(f)

    result = convert(data, cluster_id=args.cluster_id, cluster_name=args.cluster_name)
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    sys.stdout.flush()
    sys.stderr.write(
        f"Converted: {len(result['rbac']['subjects'])} subjects, "
        f"{len(result['rbac']['roles'])} roles, "
        f"{len(result['rbac']['bindings'])} bindings\n"
    )


if __name__ == "__main__":
    main()
