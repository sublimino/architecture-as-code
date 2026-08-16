#!/usr/bin/env python3
"""Every RBAC binding must reference a subject and a role that actually exist.

A RoleBinding naming a ServiceAccount that was never created is **legal**.
The API server accepts it, stores it, reports no error, and reconciles clean.
It simply grants nothing to nobody. The same is true of a binding whose
``roleRef`` names a Role that does not exist: the binding is accepted and
confers no permissions. Neither shows up as a failed object, a degraded
Kustomization, or a log line.

What you observe instead is a workload that gets 403 on a call it should be
allowed to make -- and because most callers in this estate treat a 403 as
"nothing there", it surfaces as *less data*, not as an error. The agent
discovery proxy already shipped exactly that: it searched a namespace it had no
grant in, returned fewer agents, and logged nothing.

So both sides are derived here rather than restated:

  subjects  -- every ServiceAccount named by a RoleBinding/ClusterRoleBinding
  declared  -- every ServiceAccount object the repository creates
  roleRefs  -- every Role/ClusterRole a binding points at
  roles     -- every Role/ClusterRole object the repository creates

**Nested resources are walked, and that is load-bearing.** Flux ResourceSets
carry whole objects inline under ``spec.resources[]``, and the fleet declares
much of this estate that way. A scanner that only reads top-level YAML documents
reports ``Role/fe-signalloom-health-reader`` as missing when it is declared at
d2-osramp-fleet/tenants/local/signalloom.yaml -- a false positive that would
have been "fixed" by adding a duplicate Role, or by an allowlist entry
permanently blinding the check. A guard that cannot see half the declarations is
worse than no guard, because its silence reads as coverage.

Usage:
    check-rbac-subjects.py [ROOT]        # exit 1 and print offenders on drift
    check-rbac-subjects.py --list        # print what was found, for debugging
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - environment problem, not a finding
    sys.exit("PyYAML is required: pip install pyyaml")

# ServiceAccount names that exist without anyone declaring them.
#
# Kubernetes creates `default` in every namespace automatically, so a binding
# naming it resolves at runtime even though no manifest here creates it. It is
# named rather than pattern-matched: "looks built-in" is not a property this
# check should be guessing at.
IMPLICIT_SERVICE_ACCOUNTS = {"default"}

# ClusterRoles shipped by Kubernetes itself. A binding may reference these
# without the repository declaring them.
#
# Restricted to the four default user-facing roles plus the discovery roles that
# are stable API surface. Anything else -- including controller roles installed
# by an operator -- must be declared in-repo, because "some component probably
# creates it" is the assumption that lets a genuinely missing role through.
BUILTIN_CLUSTER_ROLES = {
    "cluster-admin",
    "admin",
    "edit",
    "view",
    "system:basic-user",
    "system:discovery",
    "system:public-info-viewer",
}

BINDING_KINDS = {"RoleBinding", "ClusterRoleBinding"}


def _documents(root: Path):
    """Every YAML document tracked by git, with its path."""
    listing = subprocess.run(
        ["git", "-C", str(root), "ls-files", "*.yaml", "*.yml"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    for relative in listing:
        path = root / relative
        try:
            loaded = list(yaml.safe_load_all(path.read_text()))
        except Exception:
            # Templated manifests are not always valid YAML before rendering.
            # Skipping them is safe for *declarations* (a skipped file cannot
            # invent a binding) but it would be unsafe to skip silently if it
            # meant missing subjects, which is why unreadable files are counted
            # and reported by --list.
            yield relative, None
            continue
        for document in loaded:
            yield relative, document


def _objects(document):
    """A document's own object plus any nested inside it.

    Flux ResourceSets embed complete objects under ``spec.resources[]``, and
    Kustomizations can inline them too. Those nested objects are real
    declarations -- most of this estate's Roles and ServiceAccounts are
    declared exactly that way -- so they are yielded alongside the top-level
    document rather than ignored.
    """
    if not isinstance(document, dict):
        return
    if "kind" in document:
        yield document
    for nested in (document.get("spec", {}) or {}).get("resources", []) or []:
        if isinstance(nested, dict):
            yield from _objects(nested)


def collect(root: Path):
    declared_accounts: set[str] = set()
    declared_roles: dict[str, set[str]] = {"Role": set(), "ClusterRole": set()}
    subject_uses: list[tuple[str, str, str]] = []   # (file, binding, sa name)
    role_uses: list[tuple[str, str, str, str]] = []  # (file, binding, kind, name)
    unreadable: list[str] = []

    for relative, document in _documents(root):
        if document is None:
            unreadable.append(relative)
            continue
        for obj in _objects(document):
            kind = obj.get("kind")
            meta = obj.get("metadata") or {}
            name = meta.get("name")
            if kind == "ServiceAccount" and name:
                declared_accounts.add(name)
            elif kind in declared_roles and name:
                declared_roles[kind].add(name)
            elif kind in BINDING_KINDS:
                binding = name or "<unnamed>"
                for subject in obj.get("subjects") or []:
                    if isinstance(subject, dict) and subject.get("kind") == "ServiceAccount":
                        if subject.get("name"):
                            subject_uses.append((relative, binding, subject["name"]))
                reference = obj.get("roleRef") or {}
                if reference.get("kind") and reference.get("name"):
                    role_uses.append(
                        (relative, binding, reference["kind"], reference["name"]),
                    )

    return declared_accounts, declared_roles, subject_uses, role_uses, unreadable


def main(argv: list[str]) -> int:
    arguments = [a for a in argv[1:] if not a.startswith("--")]
    root = Path(arguments[0]) if arguments else Path(
        subprocess.run(["git", "rev-parse", "--show-toplevel"],
                       capture_output=True, text=True, check=True).stdout.strip(),
    )

    accounts, roles, subject_uses, role_uses, unreadable = collect(root)

    if "--list" in argv:
        print(f"serviceaccounts declared : {len(accounts)}")
        print(f"roles declared           : {len(roles['Role'])}")
        print(f"clusterroles declared    : {len(roles['ClusterRole'])}")
        print(f"binding subject uses     : {len(subject_uses)}")
        print(f"binding roleRef uses     : {len(role_uses)}")
        print(f"unreadable yaml files    : {len(unreadable)}")
        return 0

    # Assert the mechanism before trusting its verdict. An empty scan agrees
    # with itself perfectly: zero subjects are all resolvable. Several defects
    # in this repository were scanners that silently scanned nothing.
    problems: list[str] = []
    if not subject_uses:
        problems.append(
            "found no ServiceAccount subjects in any binding. This repository "
            "has RBAC, so the scanner is broken -- not the manifests.",
        )
    if not accounts:
        problems.append("found no ServiceAccount declarations at all -- scanner is broken.")

    for relative, binding, name in sorted(set(subject_uses)):
        if name in accounts or name in IMPLICIT_SERVICE_ACCOUNTS:
            continue
        problems.append(
            f"{relative}: binding {binding!r} names ServiceAccount {name!r}, "
            "which no manifest creates. Kubernetes accepts this binding and it "
            "grants nothing -- the workload will 403 with no error anywhere.",
        )

    for relative, binding, kind, name in sorted(set(role_uses)):
        if kind == "ClusterRole" and name in BUILTIN_CLUSTER_ROLES:
            continue
        if name in roles.get(kind, set()):
            continue
        problems.append(
            f"{relative}: binding {binding!r} references {kind} {name!r}, which "
            "no manifest creates. The binding is accepted and confers no "
            "permissions.",
        )

    if problems:
        print("RBAC binding drift:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(
        f"ok: {len(set(subject_uses))} subject reference(s) and "
        f"{len(set(role_uses))} roleRef(s) all resolve",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
