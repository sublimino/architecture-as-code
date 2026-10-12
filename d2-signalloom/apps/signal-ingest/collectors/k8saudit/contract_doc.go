// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package k8saudit

// This file is documentation as code: the label contract the k8saudit-kube
// projection emits, and the limit of what it carries. It has no runtime effect;
// it exists so the contract lives next to the projector and a reviewer can read
// the whole of what reaches a segment without running the collector.
//
// # Distinction from the existing identity-auth k8saudit
//
// There are two projections of the kube-apiserver audit source in this repo, and
// they are not duplicates — they answer different questions and must not be
// conflated:
//
//   - api/audit (collectors/adapters.go K8sAuditCollector, Source
//     "k8s-apiserver-audit"): projects onto model.LayerIdentityAuth for
//     DELEGATION and IMPERSONATION tracking. Its label set is identity-shaped
//     (audit_id, stage, verb, namespace, resource, name, api_group, status_code,
//     delegation_basis) and it emits a DelegationEdge. It answers "who delegated
//     to whom". It is unchanged by this vertical.
//
//   - THIS package (Source "k8saudit-kube"): projects onto
//     model.LayerKubernetes for the THREAT stream. It answers "what dangerous
//     thing was done in the cluster" — exec into a pod, a secret read outside an
//     allow-list, an RBAC escalation. Its label set is the threat contract
//     below, and every rule in policy/bundles/kusari/k8s-audit.yaml gates on
//     obs.source == "k8saudit-kube" so the two streams never cross a rule.
//
// Making this vertical canonical under the existing COLLECTOR_K8SAUDIT_MODE
// (retiring the identity-auth path) is deliberately out of scope and tracked as a
// separate follow-up card; the two coexist under distinct sources and env vars.
//
// # The label contract (binding, docs/EAP "k8s label contract")
//
// Keys emitted (all in store.DefaultLabelAllowList, enforced by the coverage
// gate and store/label_allowlist_k8saudit_test.go):
//
//	verb           the audited action (get, list, create, update, delete, bind, ...)
//	resource       the resource (pods, secrets, clusterrolebindings, ...)
//	subresource    the subresource when present (exec, attach, token, proxy, portforward, approval)
//	resource_kind  the request object Kind when present (Pod, Secret, ...)
//	api_group      the API group ("" for the core group — always set)
//	api_version    the API version (v1, rbac.authorization.k8s.io/v1, ...)
//	namespace      the object namespace (absent for cluster-scoped resources)
//	name           the object name when present
//	decision       the authorizer verdict, "allow" or "forbid" (always set)
//	response_code  the HTTP status as a string (always set; "0" for a non-terminal stage)
//	source_ip      the first client source IP when present
//	audit_id       the apiserver audit ID (always set)
//	stage          the audit stage (RequestReceived | ResponseStarted | ResponseComplete | Panic)
//	reason         the response reason when present
//	user_agent     the audit client string (always set; may be "")
//
// # The negative contract — what this projection must NEVER carry
//
//   - The acting identity. The user or service account (or impersonated subject)
//     goes to Observation.ActorHint, which the store pseudonymises into
//     obs.actor. It is NEVER a label. A rule that discriminates on identity reads
//     obs.actor against a bundle actor_vars set, never a label (binding C2).
//     TestProject_ActorIsNeverALabel pins this.
//
//   - The request/response body. Pod security context (privileged, hostPath,
//     hostPID, hostNetwork, hostIPC, runAsUser, added capabilities) is NOT
//     projected: it is not in the contract above, and admitting it would need new
//     allow-list keys this card does not add. So privileged-pod-create fires on
//     the pod-CREATE surface, a deliberate over-trigger in the same spirit as the
//     awslogs s3-bucket-exposure-changed rule, documented at the rule. Reading
//     the pod spec is an admission-webhook SOURCE, not this audit projection.
//
// # Stage
//
// The projection emits an observation for EVERY stage (apiserver emits up to
// four per request). ResponseComplete filtering is enforced at the RULE layer —
// every rule gates on stage == "ResponseComplete" — rather than dropped here, so
// the control is visible in the label space and its removal measurably
// double-counts a single request across its stages (the mutation the quality bar
// names). The vertical therefore produces findings only for ResponseComplete,
// exactly as specified, while keeping the filter testable.
