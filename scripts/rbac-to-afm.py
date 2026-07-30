#!/usr/bin/env python3
"""Convert raw Kubernetes RBAC JSON (kubectl get ... -o json) to KubeSec-AFM import format.

Usage:
    kubectl get clusterroles,clusterrolebindings,roles,rolebindings -A -o json | python3 scripts/rbac-to-afm.py
    python3 scripts/rbac-to-afm.py < /path/to/rbac.json

Output: JSON suitable for POST to /clusters/import with Content-Type: application/json.
"""
import json
import sys


def convert(k8s_list: dict, cluster_id: str = "local", cluster_name: str = "Local Cluster") -> dict:
    items = k8s_list.get("items", [])
    subjects_seen: dict[str, dict] = {}
    roles: list[dict] = []
    bindings: list[dict] = []

    for item in items:
        kind = item.get("kind", "")
        meta = item.get("metadata", {})
        name = meta.get("name", "")
        namespace = meta.get("namespace", "")

        if kind in ("ClusterRole", "Role"):
            scope = "Cluster" if kind == "ClusterRole" else "Namespace"
            rules_raw = item.get("rules", [])
            rules = []
            for r in rules_raw:
                rules.append({
                    "verbs": r.get("verbs", []),
                    "apiGroups": r.get("apiGroups", [""]),
                    "resources": r.get("resources", []),
                })
            role = {"name": name, "scope": scope, "rules": rules}
            if scope == "Namespace":
                role["namespace"] = namespace
            roles.append(role)

        elif kind in ("ClusterRoleBinding", "RoleBinding"):
            scope = "Cluster" if kind == "ClusterRoleBinding" else "Namespace"
            role_ref = item.get("roleRef", {})
            role_ref_name = role_ref.get("name", "")
            binding_subjects = item.get("subjects", [])
            afm_subjects = []
            for s in binding_subjects:
                sk = s.get("kind", "User")
                sn = s.get("name", "")
                sns = s.get("namespace", "")
                key = f"{sk}/{sns}/{sn}" if sns else f"{sk}/{sn}"
                if key not in subjects_seen:
                    subj = {"name": sn, "kind": sk}
                    if sk == "ServiceAccount" and sns:
                        subj["namespace"] = sns
                    subjects_seen[key] = subj
                afm_subjects.append({"kind": sk, "name": sn, **({"namespace": sns} if sns else {})})
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
    data = json.load(sys.stdin)
    result = convert(data)
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
