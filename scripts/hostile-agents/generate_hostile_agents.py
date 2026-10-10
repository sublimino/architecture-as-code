#!/usr/bin/env python3
"""Generative Adversarial Hostile Agent Suite for Signal Loom / OSRAMP.

Generates 5 distinct hostile agent vectors designed to test and prove that
CEL policies, Kubernetes admission guards, and signal telemetry feeds detect
and block hostile workloads:

1. Vector 1 (Root Breakout):
   - runAsNonRoot: false, runAsUser: 0, allowPrivilegeEscalation: true
   - Target CEL controls: cis-5.2.6 (Non-Root Execution), cis-5.2.5 (Privilege Escalation Disabled)

2. Vector 2 (Host Hijacker):
   - hostPID: true, hostIPC: true, hostNetwork: true
   - Target CEL control: cis-5.2.2 (Host Namespace Sharing Prohibited)

3. Vector 3 (Token Harvester):
   - automountServiceAccountToken: true, unauthorized listening port 4444
   - Target CEL controls: cis-5.7.1 (Service Account Token Auto-Mount Disabled),
     CRA Port Minimization (attack-surface-reduction-ports)

4. Vector 4 (Syscall Bypass):
   - seccompProfile.type: Unconfined
   - Target CEL control: cis-5.7.4 (Default Seccomp Profile RuntimeDefault)

5. Vector 5 (Rogue Telemetry & Unauthorized Tool Exec):
   - Rapid telemetry heartbeats probing canary, executing 'modify_iam' without human approval SVID
   - Target CEL control: Art. 14 Human Oversight (EU AI Act High-Risk Human Authorization)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

# Standard CEL policy expressions corresponding to the 5 hostile vectors
TARGET_CEL_POLICIES = {
    "cis-5.2.6": {
        "id": "cis-5.2.6",
        "name": "CIS 5.2.6 -- Non-Root Execution",
        "framework": "CIS Kubernetes Benchmark",
        "cel_expression": "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot == true)",
        "remediation": "Set securityContext.runAsNonRoot to true on all containers.",
        "docs_url": "https://www.cisecurity.org/benchmark/kubernetes",
    },
    "cis-5.2.5": {
        "id": "cis-5.2.5",
        "name": "CIS 5.2.5 -- Privilege Escalation Disabled",
        "framework": "CIS Kubernetes Benchmark",
        "cel_expression": "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.allowPrivilegeEscalation) && c.securityContext.allowPrivilegeEscalation == false)",
        "remediation": "Set securityContext.allowPrivilegeEscalation to false on all containers.",
        "docs_url": "https://www.cisecurity.org/benchmark/kubernetes",
    },
    "cis-5.2.2": {
        "id": "cis-5.2.2",
        "name": "CIS 5.2.2 -- Host Namespace Sharing Prohibited",
        "framework": "CIS Kubernetes Benchmark",
        "cel_expression": "(!has(object.spec.hostPID) || object.spec.hostPID == false) && (!has(object.spec.hostIPC) || object.spec.hostIPC == false) && (!has(object.spec.hostNetwork) || object.spec.hostNetwork == false)",
        "remediation": "Ensure hostPID, hostIPC, and hostNetwork are omitted or set to false.",
        "docs_url": "https://www.cisecurity.org/benchmark/kubernetes",
    },
    "cis-5.7.1": {
        "id": "cis-5.7.1",
        "name": "CIS 5.7.1 -- Automount Service Account Token Disabled",
        "framework": "CIS Kubernetes Benchmark",
        "cel_expression": "!has(object.spec.automountServiceAccountToken) || object.spec.automountServiceAccountToken == false",
        "remediation": "Set automountServiceAccountToken: false in pod spec or service account.",
        "docs_url": "https://www.cisecurity.org/benchmark/kubernetes",
    },
    "cra-ports": {
        "id": "cra-ports",
        "name": "CRA -- Port Minimization",
        "framework": "Cyber Resilience Act (CRA)",
        "cel_expression": "object.spec.containers.all(c, !has(c.ports) || c.ports.all(p, p.containerPort in [8080, 8443, 9090]))",
        "remediation": "Close unapproved ports and restrict container listening surfaces to authorized ports.",
        "docs_url": "https://digital-strategy.ec.europa.eu/en/policies/cyber-resilience-act",
    },
    "cis-5.7.4": {
        "id": "cis-5.7.4",
        "name": "CIS 5.7.4 -- Seccomp RuntimeDefault",
        "framework": "CIS Kubernetes Benchmark",
        "cel_expression": 'has(object.spec.securityContext) && has(object.spec.securityContext.seccompProfile) && object.spec.securityContext.seccompProfile.type in ["RuntimeDefault", "Localhost"]',
        "remediation": "Configure pod securityContext.seccompProfile.type to RuntimeDefault.",
        "docs_url": "https://www.cisecurity.org/benchmark/kubernetes",
    },
    "art-14": {
        "id": "art-14",
        "name": "Art. 14 -- Human Oversight Authorization",
        "framework": "EU AI Act",
        "cel_expression": "request.tool_call.action in ['exec', 'write_file', 'modify_iam'] ? (has(request.context.claims) && request.context.claims.exists(c, c.type == 'human_approval_svid' && c.valid == true)) : true",
        "remediation": "Obtain valid human approval SVID prior to executing privileged operations.",
        "docs_url": "https://artificialintelligenceact.eu/",
    },
}


def build_vector_1_root_breakout(namespace: str = "fe-signalloom-agents") -> dict[str, Any]:
    """Vector 1: Root Breakout — runAsNonRoot: false, runAsUser: 0, allowPrivilegeEscalation: true."""
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": "agent-hostile-root-breakout",
            "namespace": namespace,
            "labels": {
                "app.kubernetes.io/name": "signalloom-agent",
                "app.kubernetes.io/component": "hostile-agent",
                "app.kubernetes.io/part-of": "signalloom",
                "app.kubernetes.io/managed-by": "hostile-agents-suite",
                "app.kubernetes.io/instance": "hostile-root-breakout",
                "signalloom.ai/agent": "true",
                "signalloom.ai/agent-name": "hostile-root-breakout",
                "signalloom.ai/framework": "custom",
                "signalloom.ai/agent-cohort": "hostile",
                "signalloom.ai/vector": "root-breakout",
                "signalloom.ai/state": "active",
                "signalloom.ai/tenant": "tenant-demo",
            },
            "annotations": {
                "signalloom.ai/agent-display-name": "Hostile Agent: Root Breakout",
                "signalloom.ai/description": "Adversarial root breakout vector with UID 0 and allowPrivilegeEscalation=true",
                "signalloom.ai/target-cel-controls": "cis-5.2.6,cis-5.2.5",
            },
        },
        "spec": {
            "containers": [
                {
                    "name": "agent",
                    "image": "ghcr.io/stefanprodan/podinfo:6.7.1",
                    "securityContext": {
                        "runAsNonRoot": False,
                        "runAsUser": 0,
                        "allowPrivilegeEscalation": True,
                    },
                    "resources": {
                        "requests": {"cpu": "5m", "memory": "16Mi"},
                        "limits": {"memory": "64Mi"},
                    },
                }
            ]
        },
    }


def build_vector_2_host_hijacker(namespace: str = "fe-signalloom-agents") -> dict[str, Any]:
    """Vector 2: Host Hijacker — hostPID: true, hostIPC: true, hostNetwork: true."""
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": "agent-hostile-host-hijacker",
            "namespace": namespace,
            "labels": {
                "app.kubernetes.io/name": "signalloom-agent",
                "app.kubernetes.io/component": "hostile-agent",
                "app.kubernetes.io/part-of": "signalloom",
                "app.kubernetes.io/managed-by": "hostile-agents-suite",
                "app.kubernetes.io/instance": "hostile-host-hijacker",
                "signalloom.ai/agent": "true",
                "signalloom.ai/agent-name": "hostile-host-hijacker",
                "signalloom.ai/framework": "custom",
                "signalloom.ai/agent-cohort": "hostile",
                "signalloom.ai/vector": "host-hijacker",
                "signalloom.ai/state": "active",
                "signalloom.ai/tenant": "tenant-demo",
            },
            "annotations": {
                "signalloom.ai/agent-display-name": "Hostile Agent: Host Hijacker",
                "signalloom.ai/description": "Shares host PID, IPC, and network namespaces to inspect host kernel and processes",
                "signalloom.ai/target-cel-controls": "cis-5.2.2",
            },
        },
        "spec": {
            "hostPID": True,
            "hostIPC": True,
            "hostNetwork": True,
            "containers": [
                {
                    "name": "agent",
                    "image": "ghcr.io/stefanprodan/podinfo:6.7.1",
                    "securityContext": {
                        "allowPrivilegeEscalation": False,
                    },
                    "resources": {
                        "requests": {"cpu": "5m", "memory": "16Mi"},
                        "limits": {"memory": "64Mi"},
                    },
                }
            ],
        },
    }


def build_vector_3_token_harvester(namespace: str = "fe-signalloom-agents") -> dict[str, Any]:
    """Vector 3: Token Harvester — automountServiceAccountToken: true, unauthorized listening port 4444."""
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": "agent-hostile-token-harvester",
            "namespace": namespace,
            "labels": {
                "app.kubernetes.io/name": "signalloom-agent",
                "app.kubernetes.io/component": "hostile-agent",
                "app.kubernetes.io/part-of": "signalloom",
                "app.kubernetes.io/managed-by": "hostile-agents-suite",
                "app.kubernetes.io/instance": "hostile-token-harvester",
                "signalloom.ai/agent": "true",
                "signalloom.ai/agent-name": "hostile-token-harvester",
                "signalloom.ai/framework": "custom",
                "signalloom.ai/agent-cohort": "hostile",
                "signalloom.ai/vector": "token-harvester",
                "signalloom.ai/state": "active",
                "signalloom.ai/tenant": "tenant-demo",
            },
            "annotations": {
                "signalloom.ai/agent-display-name": "Hostile Agent: Token Harvester",
                "signalloom.ai/description": "Mounts Kubernetes default SA token and opens unauthorized listener on port 4444",
                "signalloom.ai/target-cel-controls": "cis-5.7.1,cra-ports",
            },
        },
        "spec": {
            "automountServiceAccountToken": True,
            "containers": [
                {
                    "name": "agent",
                    "image": "ghcr.io/stefanprodan/podinfo:6.7.1",
                    "ports": [
                        {
                            "name": "backdoor",
                            "containerPort": 4444,
                        }
                    ],
                    "securityContext": {
                        "allowPrivilegeEscalation": False,
                    },
                    "resources": {
                        "requests": {"cpu": "5m", "memory": "16Mi"},
                        "limits": {"memory": "64Mi"},
                    },
                }
            ],
        },
    }


def build_vector_4_syscall_bypass(namespace: str = "fe-signalloom-agents") -> dict[str, Any]:
    """Vector 4: Syscall Bypass — seccompProfile.type: Unconfined."""
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": "agent-hostile-syscall-bypass",
            "namespace": namespace,
            "labels": {
                "app.kubernetes.io/name": "signalloom-agent",
                "app.kubernetes.io/component": "hostile-agent",
                "app.kubernetes.io/part-of": "signalloom",
                "app.kubernetes.io/managed-by": "hostile-agents-suite",
                "app.kubernetes.io/instance": "hostile-syscall-bypass",
                "signalloom.ai/agent": "true",
                "signalloom.ai/agent-name": "hostile-syscall-bypass",
                "signalloom.ai/framework": "custom",
                "signalloom.ai/agent-cohort": "hostile",
                "signalloom.ai/vector": "syscall-bypass",
                "signalloom.ai/state": "active",
                "signalloom.ai/tenant": "tenant-demo",
            },
            "annotations": {
                "signalloom.ai/agent-display-name": "Hostile Agent: Syscall Bypass",
                "signalloom.ai/description": "Executes with Unconfined seccomp profile, disabling kernel syscall filtering",
                "signalloom.ai/target-cel-controls": "cis-5.7.4",
            },
        },
        "spec": {
            "securityContext": {
                "seccompProfile": {
                    "type": "Unconfined",
                },
            },
            "containers": [
                {
                    "name": "agent",
                    "image": "ghcr.io/stefanprodan/podinfo:6.7.1",
                    "securityContext": {
                        "allowPrivilegeEscalation": False,
                    },
                    "resources": {
                        "requests": {"cpu": "5m", "memory": "16Mi"},
                        "limits": {"memory": "64Mi"},
                    },
                }
            ],
        },
    }


def build_vector_5_rogue_telemetry(namespace: str = "fe-signalloom-agents") -> dict[str, Any]:
    """Vector 5: Rogue Telemetry & Unauthorized Tool Exec — rapid telemetry probing canary, executing modify_iam."""
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": "agent-hostile-rogue-telemetry",
            "namespace": namespace,
            "labels": {
                "app.kubernetes.io/name": "signalloom-agent",
                "app.kubernetes.io/component": "hostile-agent",
                "app.kubernetes.io/part-of": "signalloom",
                "app.kubernetes.io/managed-by": "hostile-agents-suite",
                "app.kubernetes.io/instance": "hostile-rogue-telemetry",
                "signalloom.ai/agent": "true",
                "signalloom.ai/agent-name": "hostile-rogue-telemetry",
                "signalloom.ai/framework": "custom",
                "signalloom.ai/agent-cohort": "hostile",
                "signalloom.ai/vector": "rogue-telemetry",
                "signalloom.ai/behavior": "active-loop",
                "signalloom.ai/state": "active",
                "signalloom.ai/tenant": "tenant-demo",
            },
            "annotations": {
                "signalloom.ai/agent-display-name": "Hostile Agent: Rogue Telemetry & Tool Exec",
                "signalloom.ai/description": "Rapid telemetry probing canary and invoking privileged modify_iam without human approval SVID",
                "signalloom.ai/target-cel-controls": "art-14",
            },
        },
        "spec": {
            "containers": [
                {
                    "name": "agent",
                    "image": "ghcr.io/stefanprodan/podinfo:6.7.1",
                    "resources": {
                        "requests": {"cpu": "5m", "memory": "16Mi"},
                        "limits": {"memory": "64Mi"},
                    },
                },
                {
                    "name": "rogue-telemetry-loop",
                    "image": "ghcr.io/stefanprodan/podinfo:6.7.1",
                    "command": ["/bin/sh", "-c"],
                    "args": [
                        "while true; do "
                        'now=$(date -u +"%Y-%m-%dT%H:%M:%SZ"); '
                        'curl -sS -X POST "http://signal-ingest.fe-signalloom.svc.cluster.local:8082/api/v1/observations" '
                        '-H "Content-Type: application/json" '
                        '-d "{\\"actor\\": \\"agent-hostile-rogue-telemetry\\", \\"layer\\": \\"activity_pulse\\", \\"action\\": \\"state_heartbeat\\", \\"timestamp\\": \\"${now}\\", \\"attributes\\": {\\"vector\\": \\"rogue-telemetry\\", \\"status\\": \\"probing\\"}}" 2>/dev/null || true; '
                        'curl -sS --max-time 1 "http://fake-integration-proxy.inf-signalloom.svc.cluster.local:8080/api/v1/canary" 2>/dev/null || true; '
                        "sleep 2; "
                        "done\n"
                    ],
                    "resources": {
                        "requests": {"cpu": "5m", "memory": "16Mi"},
                        "limits": {"memory": "64Mi"},
                    },
                },
            ]
        },
    }


def build_compliant_baseline(namespace: str = "fe-signalloom-agents") -> dict[str, Any]:
    """Compliant Baseline Pod — satisfies all CIS, CRA, and admission policies."""
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": "agent-compliant-baseline",
            "namespace": namespace,
            "labels": {
                "app.kubernetes.io/name": "signalloom-agent",
                "app.kubernetes.io/component": "agent",
                "app.kubernetes.io/part-of": "signalloom",
                "app.kubernetes.io/instance": "compliant-baseline",
                "signalloom.ai/agent": "true",
                "signalloom.ai/agent-name": "compliant-baseline",
                "signalloom.ai/framework": "custom",
                "signalloom.ai/agent-cohort": "baseline",
                "signalloom.ai/state": "idle",
                "signalloom.ai/tenant": "tenant-demo",
            },
            "annotations": {
                "signalloom.ai/agent-display-name": "Compliant Baseline Agent",
                "signalloom.ai/description": "Fully compliant reference agent passing all CIS and governance controls",
            },
        },
        "spec": {
            "automountServiceAccountToken": False,
            "hostPID": False,
            "hostIPC": False,
            "hostNetwork": False,
            "nodeSelector": {
                "node.signalloom.ai/cgroup-v2": "true",
                "node.signalloom.ai/landlock": "true",
            },
            "securityContext": {
                "runAsNonRoot": True,
                "runAsUser": 65532,
                "runAsGroup": 65532,
                "seccompProfile": {
                    "type": "RuntimeDefault",
                },
            },
            "containers": [
                {
                    "name": "agent",
                    "image": "ghcr.io/stefanprodan/podinfo:6.7.1",
                    "ports": [
                        {
                            "name": "http",
                            "containerPort": 8080,
                        }
                    ],
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": 65532,
                        "allowPrivilegeEscalation": False,
                        "readOnlyRootFilesystem": True,
                        "capabilities": {
                            "drop": ["ALL"],
                        },
                    },
                    "resources": {
                        "requests": {"cpu": "5m", "memory": "16Mi"},
                        "limits": {"memory": "64Mi"},
                    },
                }
            ],
        },
    }


def get_all_vectors(namespace: str = "fe-signalloom-agents") -> list[dict[str, Any]]:
    """Return all 5 hostile vectors in sequential order."""
    return [
        build_vector_1_root_breakout(namespace),
        build_vector_2_host_hijacker(namespace),
        build_vector_3_token_harvester(namespace),
        build_vector_4_syscall_bypass(namespace),
        build_vector_5_rogue_telemetry(namespace),
    ]


def to_yaml_doc(data: Any) -> str:
    """Serialize data to clean YAML string (or JSON fallback accepted natively by Kubernetes)."""
    try:
        import yaml
        doc = yaml.dump(data, sort_keys=False)
    except ImportError:
        import json
        doc = json.dumps(data, indent=2)
    if not doc.endswith("\n"):
        doc += "\n"
    return doc


def write_manifests(output_dir: Path, namespace: str = "fe-signalloom-agents") -> list[Path]:
    """Write individual and combined YAML files to the designated output directory."""
    output_dir.mkdir(parents=True, exist_ok=True)
    vectors = get_all_vectors(namespace)
    baseline = build_compliant_baseline(namespace)
    all_pods = vectors + [baseline]

    written_paths: list[Path] = []

    names = [
        "vector-1-root-breakout.yaml",
        "vector-2-host-hijacker.yaml",
        "vector-3-token-harvester.yaml",
        "vector-4-syscall-bypass.yaml",
        "vector-5-rogue-telemetry.yaml",
    ]

    for pod, fname in zip(vectors, names):
        p = output_dir / fname
        p.write_text(to_yaml_doc(pod), encoding="utf-8")
        written_paths.append(p)

    p_base = output_dir / "compliant-baseline.yaml"
    p_base.write_text(to_yaml_doc(baseline), encoding="utf-8")
    written_paths.append(p_base)

    # Multi-document bundle
    p_all = output_dir / "all-hostile-agents.yaml"
    combined_content = "---\n".join(to_yaml_doc(p) for p in all_pods)
    p_all.write_text(combined_content, encoding="utf-8")
    written_paths.append(p_all)

    return written_paths


def build_admission_review(pod: dict[str, Any], uid: str = "") -> dict[str, Any]:
    """Wrap a Pod manifest into an AdmissionReview request payload for node-capability-guard testing."""
    pod_name = pod.get("metadata", {}).get("name", "agent-probe")
    review_uid = uid or f"probe-{pod_name}"
    return {
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "request": {
            "uid": review_uid,
            "operation": "CREATE",
            "object": pod,
        },
    }


def evaluate_vector_against_cel(
    vector_idx: int,
    pod: dict[str, Any],
) -> list[dict[str, Any]]:
    """Evaluate a hostile vector against its target CEL policy controls using the engine."""
    repo_src = Path(__file__).resolve().parents[2] / "d2-signalloom" / "apps" / "fe-signalloom" / "src"
    if str(repo_src) not in sys.path:
        sys.path.insert(0, str(repo_src))

    from policy_evaluation import evaluate_cel_expression

    results = []

    if vector_idx == 1:
        # cis-5.2.6 and cis-5.2.5
        for cid in ("cis-5.2.6", "cis-5.2.5"):
            pol = TARGET_CEL_POLICIES[cid]
            res = evaluate_cel_expression(pol["cel_expression"], {"object": pod})
            results.append({
                "vector": 1,
                "vector_name": "Root Breakout",
                "control_id": cid,
                "control_name": pol["name"],
                "cel_expression": pol["cel_expression"],
                "compliant": res.compliant,
                "expected": False,
                "caught": (res.compliant is False),
            })
    elif vector_idx == 2:
        # cis-5.2.2
        pol = TARGET_CEL_POLICIES["cis-5.2.2"]
        res = evaluate_cel_expression(pol["cel_expression"], {"object": pod})
        results.append({
            "vector": 2,
            "vector_name": "Host Hijacker",
            "control_id": "cis-5.2.2",
            "control_name": pol["name"],
            "cel_expression": pol["cel_expression"],
            "compliant": res.compliant,
            "expected": False,
            "caught": (res.compliant is False),
        })
    elif vector_idx == 3:
        # cis-5.7.1 and cra-ports
        for cid in ("cis-5.7.1", "cra-ports"):
            pol = TARGET_CEL_POLICIES[cid]
            res = evaluate_cel_expression(pol["cel_expression"], {"object": pod})
            results.append({
                "vector": 3,
                "vector_name": "Token Harvester",
                "control_id": cid,
                "control_name": pol["name"],
                "cel_expression": pol["cel_expression"],
                "compliant": res.compliant,
                "expected": False,
                "caught": (res.compliant is False),
            })
    elif vector_idx == 4:
        # cis-5.7.4
        pol = TARGET_CEL_POLICIES["cis-5.7.4"]
        res = evaluate_cel_expression(pol["cel_expression"], {"object": pod})
        results.append({
            "vector": 4,
            "vector_name": "Syscall Bypass",
            "control_id": "cis-5.7.4",
            "control_name": pol["name"],
            "cel_expression": pol["cel_expression"],
            "compliant": res.compliant,
            "expected": False,
            "caught": (res.compliant is False),
        })
    elif vector_idx == 5:
        # art-14: tool call modify_iam without approval SVID
        pol = TARGET_CEL_POLICIES["art-14"]
        hostile_request = {
            "tool_call": {"action": "modify_iam"},
            "context": {"claims": []},
        }
        res = evaluate_cel_expression(pol["cel_expression"], {"request": hostile_request})
        results.append({
            "vector": 5,
            "vector_name": "Rogue Telemetry & Unauthorized Tool Exec",
            "control_id": "art-14",
            "control_name": pol["name"],
            "cel_expression": pol["cel_expression"],
            "compliant": res.compliant,
            "expected": False,
            "caught": (res.compliant is False),
        })

    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Signal Loom Generative Adversarial Hostile Agent Suite")
    parser.add_argument("--out-dir", type=Path, default=Path(__file__).parent / "manifests", help="Output directory for manifests")
    parser.add_argument("--namespace", default="fe-signalloom-agents", help="Kubernetes namespace")
    parser.add_argument("--json", action="store_true", help="Print all vectors as JSON")
    parser.add_argument("--evaluate", action="store_true", help="Evaluate all generated vectors against CEL policies")
    parser.add_argument("--admission-review", action="store_true", help="Output AdmissionReview payloads for webhook testing")
    args = parser.parse_args()

    if args.json:
        vectors = get_all_vectors(args.namespace)
        print(json.dumps(vectors, indent=2))
        return 0

    if args.admission_review:
        vectors = get_all_vectors(args.namespace)
        reviews = [build_admission_review(v) for v in vectors]
        print(json.dumps(reviews, indent=2))
        return 0

    # Write manifests
    written = write_manifests(args.out_dir, args.namespace)
    print(f"✓ Generated {len(written)} manifest files in {args.out_dir}")
    for p in written:
        print(f"  - {p.name}")

    if args.evaluate:
        print("\n=== Evaluating Hostile Agents against CEL Policy Controls ===")
        all_passed = True
        vectors = get_all_vectors(args.namespace)
        for idx, pod in enumerate(vectors, start=1):
            evals = evaluate_vector_against_cel(idx, pod)
            for e in evals:
                status = "PASS (CAUGHT)" if e["caught"] else "FAIL (BYPASSED)"
                print(f"Vector {e['vector']} [{e['vector_name']}] vs {e['control_id']}: {status}")
                print(f"  CEL: {e['cel_expression']}")
                print(f"  Result compliant={e['compliant']}, expected compliant={e['expected']}")
                if not e["caught"]:
                    all_passed = False

        # Evaluate compliant baseline
        base_pod = build_compliant_baseline(args.namespace)
        repo_src = Path(__file__).resolve().parents[2] / "d2-signalloom" / "apps" / "fe-signalloom" / "src"
        if str(repo_src) not in sys.path:
            sys.path.insert(0, str(repo_src))
        from policy_evaluation import evaluate_cel_expression

        print("\n=== Evaluating Compliant Baseline Agent against All Controls ===")
        compliant_passed = True
        for cid, pol in TARGET_CEL_POLICIES.items():
            if cid == "art-14":
                req_ctx = {
                    "request": {
                        "tool_call": {"action": "modify_iam"},
                        "context": {"claims": [{"type": "human_approval_svid", "valid": True}]},
                    }
                }
                res = evaluate_cel_expression(pol["cel_expression"], req_ctx)
            else:
                res = evaluate_cel_expression(pol["cel_expression"], {"object": base_pod})

            if not res.compliant:
                print(f"  Compliant baseline FAILED control {cid}: {pol['name']}")
                compliant_passed = False
            else:
                print(f"  ✓ Compliant baseline PASSED control {cid}: {pol['name']}")

        if not all_passed or not compliant_passed:
            print("\n❌ Proof assertion failed: some hostile vectors were not caught or compliant agent was flagged.")
            return 1
        print("\n✓ SUCCESS: All 5 hostile vectors were correctly caught and flagged as FAIL.")
        print("✓ SUCCESS: Compliant baseline agent passed all compliance controls.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
