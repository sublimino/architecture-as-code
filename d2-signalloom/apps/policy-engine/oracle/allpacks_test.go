package oracle

// External oracle, extended from the CIS Kubernetes pack to every pack in this
// repo that reads a workload object.
//
// psa_oracle_test.go anchors cis-kubernetes/v1.8 against
// k8s.io/pod-security-admission. It anchors nothing else. The eu-ai-act and
// nist-800-53 packs carry the same family of object-reading checks — non-root,
// privileged, privilege escalation, capabilities, seccomp, host namespaces —
// and their fixtures were authored alongside their expressions by the same
// agent in the same sitting, so until this file existed they could only prove
// self-consistency. This file runs every pod-shaped fixture of every such pack,
// plus probe pods authored here, through the same PSA comparison.
//
// Scope, and why it is exactly these six packs
//
//	in scope:  eu-ai-act v1.0 / v2.0 / v2.1, nist-800-53 v1.0 / v2.0 / v2.1.
//	out of scope: cra/v1.0, dora/v1.0, finos-aigf/v1.0, nis2/v1.0 — not by
//	           judgement but by measurement: no check in any of those four
//	           references `object` or `manifest`, and no fixture in any of them
//	           carries a pod-shaped object. TestAllPacks_ScopeIsMeasuredNotAsserted
//	           re-derives that from the policy tree on every run, so a pack that
//	           grows an object-reading check fails this tier until it is either
//	           brought in scope or declared.
//
// Oracle provenance is the same as psa_oracle_test.go's, and the machinery
// (psaOracle, compareCase, the API-server defaulting step, the seccomp API
// validation secondary oracle, strict pod decoding) is reused from there rather
// than re-implemented, so the two tiers cannot drift apart in their notion of
// what agreement means. Everything new here is prefixed apk* to keep the diff
// separable from concurrent work on that file.
//
// This module must not change policy/**. policy/frameworks/eu-ai-act/** is
// owned by another worker and policy/frameworks/nist-800-53/** by a third.
// Every divergence is therefore recorded as an apkException carrying a
// DEFECT CANDIDATE or DELIBERATE prefix and a reason; the defect candidates are
// the pack owners' to fix, after which the exception goes stale and this tier
// fails until it is retired.

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"

	psaapi "k8s.io/pod-security-admission/api"
	psapolicy "k8s.io/pod-security-admission/policy"
)

// --- the packs in scope -----------------------------------------------------

// apkPSAModule is the oracle's provenance, logged on every run so a failure
// report names the version of upstream it was judged against.
const apkPSAModule = oraclePSAModule

// apkPack names one framework version. dir is the directory under
// policy/frameworks/<id>/; version is what that pack's framework.json declares.
// They are not the same string and both are asserted, so a pack moved between
// directories cannot be judged under the wrong name.
type apkPack struct {
	id      string
	dir     string
	version string
}

func (a apkPack) label() string { return a.id + "@" + a.dir }

var apkPacks = []apkPack{
	{"eu-ai-act", "v1.0", "v1.0.0"},
	{"eu-ai-act", "v2.0", "v2.0.0"},
	{"eu-ai-act", "v2.1", "v2.1.0"},
	{"nist-800-53", "v1.0", "v1.0.0"},
	{"nist-800-53", "v2.0", "v2.0.0"},
	{"nist-800-53", "v2.1", "v2.1.0"},
}

// apkOutOfScopePacks are the packs this tier does not measure. The reason is
// re-derived on every run by TestAllPacks_ScopeIsMeasuredNotAsserted; this map
// only records the claim so the test has something to check it against.
var apkOutOfScopePacks = map[string]string{
	"cra/v1.0":        "no check references object or manifest; no pod-shaped fixture.",
	"dora/v1.0":       "placeholder pack, single check; no check references object or manifest.",
	"finos-aigf/v1.0": "no check references object or manifest; all 116 fixtures are agent/request-shaped.",
	"nis2/v1.0":       "placeholder pack, single check; no check references object or manifest.",
	// cis-kubernetes is in scope for the oracle, but through
	// psa_oracle_test.go, which owns it. Measuring it twice would double every
	// divergence and split its exception list across two files.
	"cis-kubernetes/v1.8": "owned by psa_oracle_test.go, the original tier.",
}

// --- the mapping: pack check IDs <-> the PSA checks that bear on them -------

// apkGroupTemplate is a comparable unit stated once for all packs. A pack gets
// the template with `ours` narrowed to the checks it actually has; a template
// none of whose checks the pack has is dropped. The check IDs below are shared
// verbatim across these packs (same ID, same expression — asserted by
// TestAllPacks_MappedChecksReadTheObject and reported by
// TestAllPacks_SharedCheckExpressionsAreReported), which is what makes one
// mapping table safe for six packs.
type apkGroupTemplate struct {
	name          string
	ours          []string
	psa           []psapolicy.CheckID
	secondary     bool
	necessaryOnly bool
	note          string
}

var apkGroupTemplates = []apkGroupTemplate{
	{
		name: "privileged",
		ours: []string{"no-privileged-mode"},
		psa:  []psapolicy.CheckID{"privileged"},
		note: "baseline. 1:1 with PSA's privileged check.",
	},
	{
		name: "allowPrivilegeEscalation",
		ours: []string{"no-privilege-escalation"},
		psa:  []psapolicy.CheckID{"allowPrivilegeEscalation"},
		note: "restricted. 1:1 in field terms, but PSA exempts spec.os.name == windows and these packs do not.",
	},
	{
		name: "runAsNonRoot",
		ours: []string{"container-run-as-non-root"},
		psa:  []psapolicy.CheckID{"runAsNonRoot", "runAsUser"},
		note: "restricted. PSS splits 'must require runAsNonRoot: true' from 'must not set runAsUser: 0'; " +
			"these packs carry only the first half, which is the point of mapping both PSA checks here.",
	},
	{
		name: "podSecurityContext",
		ours: []string{"pod-security-context"},
		psa:  []psapolicy.CheckID{"runAsNonRoot"},
		note: "restricted. nist-800-53 v2.0 only. Demands runAsNonRoot at POD level specifically, which is " +
			"strictly narrower than PSS: PSS accepts container-level runAsNonRoot. A PSA check may appear in " +
			"more than one group; a pack check may not, so this is its own group rather than folded into runAsNonRoot.",
	},
	{
		name: "capabilities",
		ours: []string{"drop-all-capabilities"},
		psa:  []psapolicy.CheckID{"capabilities_baseline", "capabilities_restricted"},
		note: "baseline+restricted. PSS restricted is a conjunction: drop must contain ALL AND add must be " +
			"within the allow-list. These packs check only the drop half.",
	},
	{
		name: "hostNamespaces",
		ours: []string{"no-host-network", "no-host-pid", "no-host-ipc"},
		psa:  []psapolicy.CheckID{"hostNamespaces"},
		note: "baseline. nist-800-53 v2.0 only. PSA judges hostNetwork, hostPID and hostIPC as one " +
			"check, and this pack now has all three: V3 built the no-host-ipc check and proved it but " +
			"could not land it (a Go test pinned the check count and this group mapped two names), so " +
			"the lead added it and widened the group. apk-probe-host-ipc-only now agrees.",
	},
	{
		name: "seccompProfile",
		ours: []string{"seccomp-profile"},
		psa:  []psapolicy.CheckID{"seccompProfile_baseline", "seccompProfile_restricted"},
		note: "baseline+restricted. nist-800-53 v2.0 only. PSA checks the profile TYPE only; the " +
			"Localhost/localhostProfile pairing is API validation, see the seccompAPIValidation group.",
	},
	{
		name:          "seccompAPIValidation",
		ours:          []string{"seccomp-profile"},
		psa:           []psapolicy.CheckID{oracleAPIValidationSeccomp},
		secondary:     true,
		necessaryOnly: true,
		note: "Secondary oracle, not PSA: structural API validation transcribed from kubernetes v1.34.0 " +
			"(see oracleSeccompAPIValidation). Answers 'would the API server accept the object at all', " +
			"which PSA deliberately does not judge. Necessary-only: it can say invalid, never compliant.",
	},
}

// apkUnanchoredChecks are pack checks with no Pod Security Standards
// counterpart. They are NOT anchored by anything outside this repo and their
// semantics rest entirely on fixtures written by their own author. Stating the
// reason is the deliverable: an unanchored check is a known hole, not an
// oversight.
var apkUnanchoredChecks = map[string]string{
	// Supply chain. PSS is about pod configuration, not provenance.
	"image-digest-required": "PSS says nothing about image references. Digest pinning is supply-chain, not pod security.",
	"image-digest":          "PSS says nothing about image references. Digest pinning is supply-chain, not pod security.",
	"trusted-registry":      "PSS says nothing about registries. The allow-list is a local deployment policy.",

	// Runtime hardening PSS does not require.
	"read-only-rootfs": "PSS has no read-only root filesystem requirement at baseline or restricted. " +
		"Commonly believed to be part of restricted; it is not.",
	"no-automount-sa-token": "PSS says nothing about service account token mounting (same hole CIS 5.1.6 has).",

	// Capacity and liveness: operational, not admission.
	"resource-limits-set":     "no PSS counterpart. Resource limits are capacity management.",
	"resource-requests-set":   "no PSS counterpart. Resource requests are scheduling.",
	"liveness-probe-present":  "no PSS counterpart. Probes are availability, not security.",
	"readiness-probe-present": "no PSS counterpart. Probes are availability, not security.",
	"min-replicas":            "no PSS counterpart, and the expression is a placeholder (literal false).",
	"log-volume-mount":        "no PSS counterpart. PSS constrains volume TYPES, never mount paths.",

	// Metadata conventions: entirely local.
	"app-label":                 "label hygiene is outside PSS.",
	"version-label":             "label hygiene is outside PSS.",
	"env-label":                 "label hygiene is outside PSS.",
	"managed-by-label":          "label hygiene is outside PSS.",
	"owner-label":               "label hygiene is outside PSS.",
	"audit-label":               "label hygiene is outside PSS.",
	"policy-version-label":      "label hygiene is outside PSS.",
	"data-classification-label": "data classification is an EU AI Act concept with no PSS counterpart.",
	"hitl-label":                "human oversight is an EU AI Act concept with no PSS counterpart.",
	"tls-annotation":            "annotation convention; PSS says nothing about transport security.",
	"encryption-annotation":     "annotation convention; PSS says nothing about encryption at rest.",
	"vuln-scan-annotation":      "annotation convention; PSS says nothing about scanning.",
	"log-format-annotation":     "annotation convention; PSS says nothing about log formats.",
	"pii-handling-annotation":   "annotation convention; EU AI Act concept, no PSS counterpart.",
	"data-retention-annotation": "annotation convention; EU AI Act concept, no PSS counterpart.",
	"approval-gate-annotation":  "annotation convention; EU AI Act concept, no PSS counterpart.",

	// Checks that do not read the object at all. They read agent or request and
	// are structurally outside any object oracle, PSS or otherwise.
	"override-contact-annotation":          "annotation convention; EU AI Act Article 14 concept, no PSS counterpart.",
	"training-data-provenance":             "reads agent.*, not the object. No object oracle can anchor it.",
	"annex-iv-technical-documentation":     "reads agent.*, not the object. No object oracle can anchor it.",
	"automatic-record-keeping":             "reads agent.*, not the object. No object oracle can anchor it.",
	"user-instructions-transparency":       "reads agent.*, not the object. No object oracle can anchor it.",
	"deployer-monitoring-active":           "reads agent.*, not the object. No object oracle can anchor it.",
	"synthetic-content-marking":            "reads agent.*, not the object. No object oracle can anchor it.",
	"block-unauthorized-host-exec":         "reads request.*, not the object. No object oracle can anchor it.",
	"immutable-audit-sink":                 "reads agent.*, not the object. No object oracle can anchor it.",
	"anomaly-detection-telemetry":          "reads agent.*, not the object. No object oracle can anchor it.",
	"spiffe-peer-authorization":            "reads request.*, not the object. No object oracle can anchor it.",
	"mfa-spiffe-svid-required":             "reads request.*, not the object. No object oracle can anchor it.",
	"network-boundary-enforcement":         "reads request.*, not the object. No object oracle can anchor it.",
	"cross-namespace-egress-authorization": "reads request.*, not the object. No object oracle can anchor it.",
}

// apkPSACheckAbsenceReason gives, for every PSA check, the reason a pack that
// does not map it does not cover that ground. Stated once rather than per pack
// (six near-identical tables would be noise), and enforced per pack by
// TestAllPacks_MappingCoversEveryPSACheck: every upstream check must be either
// mapped for that pack or present here. An upstream addition or rename
// therefore fails the tier rather than silently turning it into a no-op.
var apkPSACheckAbsenceReason = map[psapolicy.CheckID]string{
	"privileged":                 "pack has no privileged-mode check",
	"allowPrivilegeEscalation":   "pack has no privilege-escalation check",
	"runAsNonRoot":               "pack has no run-as-non-root check",
	"runAsUser":                  "no pack in scope checks runAsUser at all; the gap is recorded as a defect candidate",
	"capabilities_baseline":      "pack has no capability check",
	"capabilities_restricted":    "pack has no capability check",
	"hostNamespaces":             "pack has no host-namespace check",
	"hostPorts":                  "no pack in scope has a hostPort check",
	"hostPathVolumes":            "no pack in scope has a hostPath check",
	"restrictedVolumes":          "no pack in scope has a volume-type allow-list",
	"windowsHostProcess":         "no pack in scope has a Windows HostProcess check",
	"seccompProfile_baseline":    "pack has no seccomp check",
	"seccompProfile_restricted":  "pack has no seccomp check",
	"appArmorProfile":            "no pack in scope has an AppArmor check",
	"procMount":                  "no pack in scope has a procMount check",
	"procMount_restricted":       "no pack in scope has a procMount check",
	"seLinuxOptions":             "no pack in scope has an SELinux check",
	"sysctls":                    "no pack in scope has a sysctl check",
	"hostProbesAndHostLifecycle": "no pack in scope has a host-probe check (PSA >= 1.34)",
}

// --- exceptions: divergences accepted, each with its own reason -------------

// apkException records one accepted divergence, pack-scoped. Matching is exact
// on direction as well as identity, so a divergence that flips direction is a
// new finding, and an exception that stops diverging is reported as stale.
//
// Every Reason must start with one of apkExceptionPrefixes:
//
//	DEFECT CANDIDATE — this tier believes the pack is wrong. Not fixed here:
//	  policy/frameworks/** is owned by other workers. The exception exists so
//	  the tier can stay green while the fix is outstanding, and goes stale the
//	  moment it lands.
//	DELIBERATE — the pack is knowingly stricter than, or differently attributed
//	  from, Pod Security Standards, and that is the intended behaviour.
//
// An entry expands to the full cross-product Pack x Groups x Cases, and EVERY
// key in that product must diverge in the recorded direction. A product member
// that does not diverge is reported stale individually, so the list cannot be
// padded: one entry covering ten cases is ten assertions, not one.
type apkException struct {
	Pack     string   // apkPack.label()
	Groups   []string // group names
	Cases    []string // fixture or probe names
	OursPass bool
	PSAAllow bool
	Reason   string
}

var apkExceptionPrefixes = []string{"DEFECT CANDIDATE", "DELIBERATE"}

// apkExceptionKey is one (pack, group, case) triple from an entry's product.
type apkExceptionKey struct {
	pack, group, caseName string
	oursPass, psaAllow    bool
	entry                 int
}

func apkExpandExceptions(exceptions []apkException) []apkExceptionKey {
	var out []apkExceptionKey
	for i, e := range exceptions {
		for _, g := range e.Groups {
			for _, c := range e.Cases {
				out = append(out, apkExceptionKey{
					pack: e.Pack, group: g, caseName: c,
					oursPass: e.OursPass, psaAllow: e.PSAAllow, entry: i,
				})
			}
		}
	}
	return out
}

// --- the cases a pod cannot be judged on: zero-container fixtures -----------

// Each pack's fixtures include one "--no-containers" pod per check author, and
// every container-iterating check in every pack guards with
// size(object.spec.containers) > 0 and therefore FAILS such a pod. PSA has
// nothing to visit and allows it. The lists are written out per pack rather
// than derived, because a derived list would silently absorb a new fixture.
var (
	apkNoContainerFixturesEUv10 = []string{
		"container-run-as-non-root--no-containers",
		"image-digest-required--no-containers",
		"no-privilege-escalation--no-containers",
		"no-privileged-mode--no-containers",
		"resource-limits-set--no-containers",
	}
	apkNoContainerFixturesEUv20 = []string{
		"container-run-as-non-root--no-containers",
		"drop-all-capabilities--no-containers",
		"image-digest-required--no-containers",
		"liveness-probe-present--no-containers",
		"no-privilege-escalation--no-containers",
		"no-privileged-mode--no-containers",
		"read-only-rootfs--no-containers",
		"readiness-probe-present--no-containers",
		"resource-limits-set--no-containers",
		"resource-requests-set--no-containers",
	}
	apkNoContainerFixturesEUv21 = []string{
		"container-run-as-non-root--no-containers",
		"drop-all-capabilities--no-containers",
		"no-privilege-escalation--no-containers",
		"resource-limits-set--no-containers",
	}
	apkNoContainerFixturesNISTv10 = []string{
		"container-run-as-non-root--no-containers",
		"drop-all-capabilities--no-containers",
		"image-digest-required--no-containers",
		"no-privilege-escalation--no-containers",
		"no-privileged-mode--no-containers",
		"read-only-rootfs--no-containers",
		"resource-limits-set--no-containers",
	}
	apkNoContainerFixturesNISTv20 = []string{
		"container-run-as-non-root--no-containers",
		"drop-all-capabilities--no-containers",
		"image-digest-required--no-containers",
		"liveness-probe-present--no-containers",
		"log-volume-mount--no-containers",
		"no-privilege-escalation--no-containers",
		"no-privileged-mode--no-containers",
		"read-only-rootfs--no-containers",
		"readiness-probe-present--no-containers",
		"resource-limits-set--no-containers",
		"resource-requests-set--no-containers",
	}
	apkNoContainerFixturesNISTv21 = []string{
		"container-run-as-non-root--no-containers",
		"drop-all-capabilities--no-containers",
		"image-digest--no-containers",
		"no-privilege-escalation--no-containers",
		"no-privileged-mode--no-containers",
		"read-only-rootfs--no-containers",
	}
)

// Reasons are shared across packs where the finding is literally the same
// expression in the same shape, so the pack owners get one statement of each
// defect rather than six paraphrases of it.
const (
	apkReasonNoContainers = "DELIBERATE, pack is right. A Pod with zero containers: every container-iterating " +
		"check guards with size(object.spec.containers) > 0 and fails, PSA has nothing to visit and admits. " +
		"The guard is correct and must not be removed — without it CEL's .all() over an empty list is " +
		"vacuously true and the pack would report full compliance for an empty pod. The object is rejected " +
		"by API validation anyway (spec.containers: Required value), so nothing admissible is being failed."

	apkReasonWindowsField = "DEFECT CANDIDATE (low: false non-compliance, not false compliance). PSS exempts " +
		"spec.os.name == windows from allowPrivilegeEscalation and from the restricted seccomp requirement " +
		"because those are Linux-only fields that cannot meaningfully be set on a Windows pod. These packs " +
		"carry no os check, so a conformant Windows workload is permanently non-compliant and cannot be " +
		"made compliant. PSA is right: gate both expressions on " +
		"(!has(object.spec.os) || object.spec.os.name != 'windows')."

	apkReasonRunAsUserZero = "DEFECT CANDIDATE (high). container-run-as-non-root asks only about runAsNonRoot, " +
		"so runAsUser: 0 alongside runAsNonRoot: true PASSES. PSS splits the rule in two and its runAsUser " +
		"half forbids 0 outright, so PSA rejects the pod. This is the known class: the pack reasons about " +
		"runtime effect (kubelet would refuse to start the container) where admission reasons about fields. " +
		"The pack reports compliance for a pod that cannot be submitted. PSA is right: add " +
		"runAsUser != 0 to the expression, pod level and container level."

	apkReasonAddSysAdmin = "DEFECT CANDIDATE (high). PSS restricted is a conjunction — drop must contain ALL " +
		"AND add must be within {NET_BIND_SERVICE} — and PSS baseline forbids SYS_ADMIN on its own. " +
		"drop-all-capabilities checks only the drop half, so a container that drops ALL and then re-adds " +
		"SYS_ADMIN (root-equivalent: mount, ptrace any process, load kernel modules) is reported compliant. " +
		"PSA is right: the expression needs an add allow-list beside the drop assertion."
)

var apkExceptions = []apkException{
	// --- class A: zero-container fixtures, one entry per pack --------------
	{
		Pack:     "eu-ai-act@v1.0",
		Groups:   []string{"privileged", "allowPrivilegeEscalation", "runAsNonRoot"},
		PSAAllow: true,
		Cases:    apkNoContainerFixturesEUv10,
		Reason:   apkReasonNoContainers,
	},
	{
		Pack:     "eu-ai-act@v2.0",
		Groups:   []string{"privileged", "allowPrivilegeEscalation", "runAsNonRoot", "capabilities"},
		PSAAllow: true,
		Cases:    apkNoContainerFixturesEUv20,
		Reason:   apkReasonNoContainers,
	},
	{
		Pack:     "eu-ai-act@v2.1",
		Groups:   []string{"allowPrivilegeEscalation", "runAsNonRoot", "capabilities"},
		PSAAllow: true,
		Cases:    apkNoContainerFixturesEUv21,
		Reason:   apkReasonNoContainers,
	},
	{
		Pack:     "nist-800-53@v1.0",
		Groups:   []string{"privileged", "allowPrivilegeEscalation", "runAsNonRoot", "capabilities"},
		PSAAllow: true,
		Cases:    apkNoContainerFixturesNISTv10,
		Reason:   apkReasonNoContainers,
	},
	{
		Pack:     "nist-800-53@v2.0",
		Groups:   []string{"privileged", "allowPrivilegeEscalation", "runAsNonRoot", "capabilities", "seccompProfile"},
		PSAAllow: true,
		Cases:    apkNoContainerFixturesNISTv20,
		Reason:   apkReasonNoContainers,
	},
	{
		Pack:     "nist-800-53@v2.1",
		Groups:   []string{"privileged", "allowPrivilegeEscalation", "runAsNonRoot", "capabilities"},
		PSAAllow: true,
		Cases:    apkNoContainerFixturesNISTv21,
		Reason:   apkReasonNoContainers,
	},

	// --- class B: the Windows exemption PSS has and the packs do not -------
	{
		Pack: "eu-ai-act@v1.0", Groups: []string{"allowPrivilegeEscalation"},
		PSAAllow: true,
		Cases:    []string{"apk-probe-windows-no-privilege-escalation-field"}, Reason: apkReasonWindowsField,
	},
	{
		Pack: "eu-ai-act@v2.0", Groups: []string{"allowPrivilegeEscalation"},
		PSAAllow: true,
		Cases:    []string{"apk-probe-windows-no-privilege-escalation-field"}, Reason: apkReasonWindowsField,
	},
	{
		Pack: "eu-ai-act@v2.1", Groups: []string{"allowPrivilegeEscalation"},
		PSAAllow: true,
		Cases:    []string{"apk-probe-windows-no-privilege-escalation-field"}, Reason: apkReasonWindowsField,
	},
	{
		Pack: "nist-800-53@v1.0", Groups: []string{"allowPrivilegeEscalation"},
		PSAAllow: true,
		Cases:    []string{"apk-probe-windows-no-privilege-escalation-field"}, Reason: apkReasonWindowsField,
	},
	{
		Pack: "nist-800-53@v2.0", Groups: []string{"allowPrivilegeEscalation", "seccompProfile"},
		PSAAllow: true,
		Cases:    []string{"apk-probe-windows-no-privilege-escalation-field"}, Reason: apkReasonWindowsField,
	},
	{
		Pack: "nist-800-53@v2.1", Groups: []string{"allowPrivilegeEscalation"},
		PSAAllow: true,
		Cases:    []string{"apk-probe-windows-no-privilege-escalation-field"}, Reason: apkReasonWindowsField,
	},

	// --- class C: runAsUser: 0 accepted alongside runAsNonRoot: true ------
	{
		Pack: "eu-ai-act@v1.0", Groups: []string{"runAsNonRoot"}, OursPass: true,
		Cases: []string{
			"apk-probe-runasuser-zero-with-runasnonroot-true",
			"apk-probe-runasuser-zero-container-level",
		},
		Reason: apkReasonRunAsUserZero,
	},
	{
		Pack: "eu-ai-act@v2.0", Groups: []string{"runAsNonRoot"}, OursPass: true,
		Cases: []string{
			"apk-probe-runasuser-zero-with-runasnonroot-true",
			"apk-probe-runasuser-zero-container-level",
		},
		Reason: apkReasonRunAsUserZero,
	},
	{
		Pack: "eu-ai-act@v2.1", Groups: []string{"runAsNonRoot"}, OursPass: true,
		Cases: []string{
			"apk-probe-runasuser-zero-with-runasnonroot-true",
			"apk-probe-runasuser-zero-container-level",
		},
		Reason: apkReasonRunAsUserZero,
	},
	{
		Pack: "nist-800-53@v1.0", Groups: []string{"runAsNonRoot"}, OursPass: true,
		Cases: []string{
			"apk-probe-runasuser-zero-with-runasnonroot-true",
			"apk-probe-runasuser-zero-container-level",
		},
		Reason: apkReasonRunAsUserZero,
	},
	{
		Pack: "nist-800-53@v2.0", Groups: []string{"runAsNonRoot"}, OursPass: true,
		Cases: []string{
			"apk-probe-runasuser-zero-with-runasnonroot-true",
			"apk-probe-runasuser-zero-container-level",
		},
		Reason: apkReasonRunAsUserZero,
	},
	{
		Pack: "nist-800-53@v2.1", Groups: []string{"runAsNonRoot"}, OursPass: true,
		Cases: []string{
			"apk-probe-runasuser-zero-with-runasnonroot-true",
			"apk-probe-runasuser-zero-container-level",
		},
		Reason: apkReasonRunAsUserZero,
	},

	// --- class D: drop ALL then add SYS_ADMIN ------------------------------
	{
		Pack: "eu-ai-act@v2.0", Groups: []string{"capabilities"}, OursPass: true,
		Cases: []string{"apk-probe-drop-all-plus-add-sys-admin"}, Reason: apkReasonAddSysAdmin,
	},
	{
		Pack: "eu-ai-act@v2.1", Groups: []string{"capabilities"}, OursPass: true,
		Cases: []string{"apk-probe-drop-all-plus-add-sys-admin"}, Reason: apkReasonAddSysAdmin,
	},
	{
		Pack: "nist-800-53@v1.0", Groups: []string{"capabilities"}, OursPass: true,
		Cases: []string{"apk-probe-drop-all-plus-add-sys-admin"}, Reason: apkReasonAddSysAdmin,
	},
	{
		Pack: "nist-800-53@v2.0", Groups: []string{"capabilities"}, OursPass: true,
		Cases: []string{"apk-probe-drop-all-plus-add-sys-admin"}, Reason: apkReasonAddSysAdmin,
	},
	{
		Pack: "nist-800-53@v2.1", Groups: []string{"capabilities"}, OursPass: true,
		Cases: []string{"apk-probe-drop-all-plus-add-sys-admin"}, Reason: apkReasonAddSysAdmin,
	},

	// --- class E: the third host namespace, uncovered ----------------------
	{
		Pack: "nist-800-53@v2.0", Groups: []string{"hostNamespaces"}, OursPass: true,
		Cases: []string{"apk-probe-host-ipc-only"},
		Reason: "DEFECT CANDIDATE (medium). PSA judges hostNetwork, hostPID and hostIPC as ONE baseline " +
			"check; this pack has no-host-network and no-host-pid but nothing for hostIPC, so a pod sharing " +
			"the host IPC namespace (readable/writable shared memory and message queues of every other " +
			"host process) is reported compliant. PSA is right: the pack needs a no-host-ipc check.",
	},

	// --- class F: seccomp Localhost with no localhostProfile ---------------
	{
		Pack: "nist-800-53@v2.0", Groups: []string{"seccompAPIValidation"}, OursPass: true,
		Cases: []string{"apk-probe-seccomp-localhost-without-profile"},
		Reason: "DEFECT CANDIDATE (medium). seccomp-profile accepts type Localhost and stops; the API server " +
			"rejects the object outright when localhostProfile is unset (validateSeccompProfileField, " +
			"transcribed in oracleSeccompAPIValidation). The pack reports compliance for a pod that cannot " +
			"be submitted. This is the SAME defect A5 already fixed in cis-kubernetes's " +
			"seccomp-runtime-default — the fix did not travel to this pack. PSA cannot see this direction " +
			"at all, which is why the necessary-only secondary oracle is what catches it.",
	},

	// --- class G: pod-security-context is strictly narrower than PSS -------
	{
		Pack: "nist-800-53@v2.0", Groups: []string{"podSecurityContext"}, PSAAllow: true,
		Cases: []string{
			"apk-probe-container-level-runasnonroot-only",
			"apk-probe-runasuser-zero-container-level",
			"pod-security-context--no-pod-security-context",
			"pod-security-context--run-as-non-root-absent",
			"seccomp-profile--no-pod-security-context",
		},
		Reason: "DELIBERATE, pack is deliberately stricter. pod-security-context demands runAsNonRoot at POD " +
			"level specifically; PSS accepts container-level runAsNonRoot and so admits these pods. Defensible " +
			"as a defence-in-depth default (a pod-level setting covers containers added later), and this " +
			"group exists precisely to make the stricter-than-PSS surface visible rather than implicit. " +
			"Keep, unless the pack owner decides NIST AC-6 does not warrant exceeding PSS here.",
	},

	// --- class H: attribution, not disagreement ----------------------------
	{
		Pack: "nist-800-53@v2.0", Groups: []string{"podSecurityContext"}, OursPass: true,
		Cases: []string{
			"container-run-as-non-root--container-sets-false",
			"container-run-as-non-root--init-container-violates",
			"container-run-as-non-root--ephemeral-container-violates",
		},
		Reason: "DELIBERATE — ATTRIBUTION, NOT DISAGREEMENT. Pod-level runAsNonRoot is true, so " +
			"pod-security-context passes, while a container overrides it and PSA's runAsNonRoot rejects the " +
			"pod. The pack DOES reject these pods, through container-run-as-non-root: the runAsNonRoot group " +
			"agrees with PSA on all three. Only the per-check attribution differs, and the overlap between " +
			"the two pack checks is deliberate and visible.",
	},
	{
		Pack: "nist-800-53@v2.0", Groups: []string{"runAsNonRoot"}, OursPass: true,
		Cases: []string{"pod-security-context--run-as-non-root-false"},
		Reason: "DELIBERATE — ATTRIBUTION, NOT DISAGREEMENT. Pod-level runAsNonRoot is false with containers " +
			"overriding to true, so container-run-as-non-root passes while PSA rejects an explicit pod-level " +
			"false regardless of overrides. The pack DOES reject this pod, through pod-security-context: that " +
			"group agrees with PSA here. Per-check attribution differs; both sides find the pod inadmissible.",
	},

	// --- class J: pod-level Unconfined masked by container overrides -------
	{
		Pack: "nist-800-53@v2.0", Groups: []string{"seccompProfile"}, OursPass: true,
		Cases: []string{"seccomp-profile--containers-override-pod-unconfined"},
		Reason: "DEFECT CANDIDATE (high). Pod-level seccompProfile.type is Unconfined and each container " +
			"overrides it with RuntimeDefault. seccomp-profile's per-container ternary reads the container " +
			"level and never looks at the pod level once it is set, so the pod passes; PSA rejects an " +
			"explicit pod-level Unconfined outright, at baseline AND restricted. The known class again: the " +
			"pack computes the EFFECTIVE profile where admission forbids the FIELD. It matters beyond " +
			"attribution because any container added later without its own profile inherits Unconfined, and " +
			"no other check in this pack fails the pod. PSA is right.",
	},
}

// --- scanning ---------------------------------------------------------------

type apkCase struct {
	name   string
	source string // "fixture" or "probe"
	object map[string]any
}

type apkDivergence struct {
	Pack     string
	Case     string
	Group    string
	OursPass bool
	PSAAllow bool
	Detail   string
}

func (d apkDivergence) String() string {
	ours, psa := "fail", "reject"
	if d.OursPass {
		ours = "pass"
	}
	if d.PSAAllow {
		psa = "allow"
	}
	return fmt.Sprintf("%s | %s / %s: pack=%s, oracle=%s | %s", d.Pack, d.Case, d.Group, ours, psa, d.Detail)
}

func (d apkDivergence) matches(k apkExceptionKey) bool {
	return d.Pack == k.pack && d.Case == k.caseName && d.Group == k.group &&
		d.OursPass == k.oursPass && d.PSAAllow == k.psaAllow
}

// apkApplyExceptions splits divergences into unexcused ones and reports which
// expanded exception keys went unused. An unused key is stale and must fail:
// that interlock is the reason this tier cannot quietly accumulate excuses for
// defects that have since been fixed.
func apkApplyExceptions(divs []apkDivergence, exceptions []apkException) (unexcused []apkDivergence, stale []string) {
	keys := apkExpandExceptions(exceptions)
	used := make([]bool, len(keys))
	for _, d := range divs {
		matched := false
		for i, k := range keys {
			if d.matches(k) {
				used[i] = true
				matched = true
			}
		}
		if !matched {
			unexcused = append(unexcused, d)
		}
	}
	for i, k := range keys {
		if used[i] {
			continue
		}
		stale = append(stale, fmt.Sprintf("%s | %s / %s (recorded pack=%v oracle=%v): %s",
			k.pack, k.caseName, k.group, k.oursPass, k.psaAllow, exceptions[k.entry].Reason))
	}
	return unexcused, stale
}

// apkActiveGroups narrows the shared templates to one pack. A template keeps
// only the checks the pack has; a template with none of them is dropped, so a
// pack is never measured against a mapping for a check it does not carry.
func apkActiveGroups(p *Pack) []oracleGroup {
	var out []oracleGroup
	for _, tmpl := range apkGroupTemplates {
		var ours []string
		for _, id := range tmpl.ours {
			if _, ok := p.Checks[id]; ok {
				ours = append(ours, id)
			}
		}
		if len(ours) == 0 {
			continue
		}
		out = append(out, oracleGroup{
			name: tmpl.name, ours: ours, psa: tmpl.psa,
			secondary: tmpl.secondary, necessaryOnly: tmpl.necessaryOnly, note: tmpl.note,
		})
	}
	return out
}

// apkScan is the same pipeline as oracleScan, pack-labelled and driven by an
// explicit group list. The comparison itself is compareCase, shared with the
// CIS tier, so the two tiers cannot disagree about what a divergence is.
func apkScan(
	t *testing.T,
	eng *CELEngine,
	o *psaOracle,
	packLabel string,
	p *Pack,
	groups []oracleGroup,
	cases []apkCase,
) (divs []apkDivergence, skipped []string) {
	t.Helper()
	for _, c := range cases {
		obj := oracleRoundTrip(t, c.object)
		pod, err := oracleDecodePod(obj)
		if err != nil {
			skipped = append(skipped, fmt.Sprintf("%s | %s: not decodable as a Pod: %v", packLabel, c.name, err))
			continue
		}
		oracleApplyAPIServerDefaults(pod)
		ours := oracleOurVerdicts(eng, p, obj)
		psa := map[psapolicy.CheckID]psaVerdict{oracleAPIValidationSeccomp: oracleAPIValidationVerdict(pod)}
		for _, g := range groups {
			for _, id := range g.psa {
				if strings.HasPrefix(string(id), oracleAPIValidationPrefix) {
					continue
				}
				psa[id] = o.check(id, pod)
			}
		}
		d, s := compareCase(groups, c.name, ours, psa)
		for _, one := range d {
			divs = append(divs, apkDivergence{
				Pack: packLabel, Case: one.Case, Group: one.Group,
				OursPass: one.OursPass, PSAAllow: one.PSAAllow, Detail: one.Detail,
			})
		}
		for _, one := range s {
			skipped = append(skipped, packLabel+" | "+one)
		}
	}
	return divs, skipped
}

// --- loading ----------------------------------------------------------------

func apkLoadPack(t *testing.T, root string, ap apkPack) *Pack {
	t.Helper()
	p, err := LoadPack(root, ap.id, ap.dir)
	if err != nil {
		t.Fatalf("loading %s: %v", ap.label(), err)
	}
	if p.ID != ap.id || p.Version != ap.version {
		t.Fatalf("%s: framework.json declares %s@%s, want %s@%s", ap.label(), p.ID, p.Version, ap.id, ap.version)
	}
	if len(p.Order) == 0 {
		t.Fatalf("%s: no checks loaded", ap.label())
	}
	return p
}

func apkFixtureCases(t *testing.T, ap apkPack, p *Pack) (cases []apkCase, notPods []string) {
	t.Helper()
	fixtures, err := LoadFixtures(p)
	if err != nil {
		t.Fatalf("%s: loading fixtures: %v", ap.label(), err)
	}
	if len(fixtures) == 0 {
		t.Fatalf("%s: no fixtures loaded: the oracle would pass vacuously", ap.label())
	}
	for _, f := range fixtures {
		if !oraclePodShaped(f.Input.Object) {
			notPods = append(notPods, f.Name)
			continue
		}
		cases = append(cases, apkCase{name: f.Name, source: "fixture", object: f.Input.Object})
	}
	if len(cases) == 0 {
		t.Fatalf("%s: no pod-shaped fixture: this pack cannot be anchored by a pod oracle", ap.label())
	}
	return cases, notPods
}

// --- probe pods, authored here, deliberately not in any pack ----------------

// apkProbePods exist because fixture coverage is chosen by the same author as
// the expressions, so a semantics gap no fixture exercises is invisible to the
// fixture leg by construction. Each probe isolates one question and is named
// apk-probe-* so it can never be confused with a pack fixture or with
// psa_oracle_test.go's probes.
//
// Every probe is otherwise PSS-restricted-compliant, so the only thing that can
// make a group diverge is the one field the probe is about.
var apkProbePods = map[string]string{
	// Control. A pod PSS admits under restricted. The oracle must agree with
	// the packs somewhere, or the mapping is just noise.
	"apk-probe-restricted-compliant": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-restricted-compliant", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,

	// THE KNOWN CLASS, instance 1: runAsUser: 0 alongside runAsNonRoot: true.
	// Every in-scope pack's container-run-as-non-root asks only about
	// runAsNonRoot, so it passes. PSS splits the rule in two and its runAsUser
	// half forbids 0 outright. This is admission reasoning about FIELDS where
	// the pack reasons about intent.
	"apk-probe-runasuser-zero-with-runasnonroot-true": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-runasuser-zero-with-runasnonroot-true", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 0,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,

	// Same field, container level, to prove the gap is not an artefact of where
	// the securityContext sits.
	"apk-probe-runasuser-zero-container-level": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-runasuser-zero-container-level", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"runAsNonRoot": true, "runAsUser": 0,
                              "allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,

	// Control for the above: a non-zero runAsUser with no runAsNonRoot at all.
	// The CIS pack was lax here; these packs' ternary form is not, so both
	// sides must reject and this probe must NOT diverge.
	"apk-probe-runasuser-nonzero-without-runasnonroot": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-runasuser-nonzero-without-runasnonroot", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,

	// Container-level runAsNonRoot only, no pod-level. PSS accepts this;
	// nist-800-53 v2.0's pod-security-context demands the pod level
	// specifically, so it is strictly narrower than PSS.
	"apk-probe-container-level-runasnonroot-only": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-container-level-runasnonroot-only", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                              "allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,

	// THE KNOWN CLASS, instance 2: drop ALL *and* add SYS_ADMIN. PSS restricted
	// is a conjunction — drop must contain ALL AND add must be within the
	// allow-list — and PSS baseline forbids SYS_ADMIN on its own. Every
	// in-scope pack checks only the drop half, so it passes a container that
	// re-acquires the one capability that is equivalent to root.
	"apk-probe-drop-all-plus-add-sys-admin": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-drop-all-plus-add-sys-admin", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"], "add": ["SYS_ADMIN"]}}}]
      }}`,

	// Control for the capability comparison: drop ALL plus the one capability
	// PSS restricted does permit. Both sides must accept.
	"apk-probe-drop-all-plus-add-net-bind-service": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-drop-all-plus-add-net-bind-service", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"], "add": ["NET_BIND_SERVICE"]}}}]
      }}`,

	// Case sensitivity of the drop comparison. The CIS pack accepted a
	// lowercase "all" and that was a real defect; these packs compare
	// d == 'ALL', so both sides must reject and this probe must NOT diverge.
	"apk-probe-drop-all-lowercase": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-drop-all-lowercase", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["all"]}}}]
      }}`,

	// THE KNOWN CLASS, instance 3: the host namespace the pack does not cover.
	// nist-800-53 v2.0 has no-host-network and no-host-pid but nothing for
	// hostIPC; PSA judges all three as one check.
	"apk-probe-host-ipc-only": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-host-ipc-only", "namespace": "payments"},
      "spec": {
        "hostIPC": true,
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,

	// Controls for the two host namespaces the pack does cover.
	"apk-probe-host-pid-only": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-host-pid-only", "namespace": "payments"},
      "spec": {
        "hostPID": true,
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,

	// THE KNOWN CLASS, instance 4: seccompProfile.type Localhost with no
	// localhostProfile. nist-800-53 v2.0's seccomp-profile accepts the type and
	// stops; the API server rejects the object outright, so the pack reports
	// compliance for a pod that cannot be submitted.
	"apk-probe-seccomp-localhost-without-profile": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-seccomp-localhost-without-profile", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "Localhost"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,

	// Control: Localhost WITH a profile. Valid object, accepted by both.
	"apk-probe-seccomp-localhost-with-profile": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-seccomp-localhost-with-profile", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "Localhost",
                                               "localhostProfile": "profiles/app.json"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,

	// Seccomp Unconfined: rejected by both PSA seccomp checks and by the pack.
	"apk-probe-seccomp-unconfined": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-seccomp-unconfined", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "Unconfined"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,

	// THE KNOWN CLASS, instance 5, in the other direction: PSS exempts
	// spec.os.name == windows from allowPrivilegeEscalation (the field has no
	// meaning on Windows); the packs do not, so they fail a pod PSA admits.
	"apk-probe-windows-no-privilege-escalation-field": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-windows-no-privilege-escalation-field", "namespace": "payments"},
      "spec": {
        "os": {"name": "windows"},
        "automountServiceAccountToken": false,
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"capabilities": {"drop": ["ALL"]}}}]
      }}`,

	// A privileged container. Both sides must reject, in every pack that has a
	// privileged check.
	"apk-probe-privileged-container": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-privileged-container", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"privileged": true, "allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,

	// An initContainer carrying the violation while the main container is
	// clean: both sides visit init containers, so both must reject.
	"apk-probe-init-container-privileged": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "apk-probe-init-container-privileged", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "initContainers": [{"name": "init", "image": "registry.example/init:1",
          "securityContext": {"privileged": true, "allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}],
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,
}

func apkProbeCases(t *testing.T) []apkCase {
	t.Helper()
	names := make([]string, 0, len(apkProbePods))
	for n := range apkProbePods {
		names = append(names, n)
	}
	sort.Strings(names)
	cases := make([]apkCase, 0, len(names))
	for _, n := range names {
		if !strings.HasPrefix(n, "apk-probe-") {
			t.Fatalf("probe %q must be named apk-probe-*", n)
		}
		var obj map[string]any
		dec := json.NewDecoder(strings.NewReader(apkProbePods[n]))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&obj); err != nil {
			t.Fatalf("probe %s: %v", n, err)
		}
		if !oraclePodShaped(obj) {
			t.Fatalf("probe %s is not pod-shaped", n)
		}
		if got, _ := obj["metadata"].(map[string]any)["name"].(string); got != n {
			t.Fatalf("probe %s: metadata.name is %q, must equal the probe name", n, got)
		}
		// A probe that does not decode as a Pod would be silently skipped by
		// apkScan, which is the quietest way for this leg to become a no-op.
		if _, err := oracleDecodePod(obj); err != nil {
			t.Fatalf("probe %s does not decode as a corev1.Pod: %v", n, err)
		}
		cases = append(cases, apkCase{name: n, source: "probe", object: obj})
	}
	return cases
}

// --- the tier ---------------------------------------------------------------

// TestAllPacks_AgreeWithPodSecurityAdmission is the tier, extended over every
// pack with object-reading checks. Every divergence is a failure unless it is
// an individually-justified exception, and an exception that no longer diverges
// is itself a failure.
func TestAllPacks_AgreeWithPodSecurityAdmission(t *testing.T) {
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	o, err := newPSAOracle()
	if err != nil {
		t.Fatal(err)
	}
	root, err := PolicyRoot()
	if err != nil {
		t.Fatal(err)
	}
	probes := apkProbeCases(t)
	t.Logf("oracle: %s, policy version %s; %d packs, %d probes",
		apkPSAModule, psaapi.LatestVersion(), len(apkPacks), len(probes))

	var all []apkDivergence
	for _, ap := range apkPacks {
		p := apkLoadPack(t, root, ap)
		groups := apkActiveGroups(p)
		if len(groups) == 0 {
			t.Fatalf("%s: no group maps any of its checks, yet it is declared in scope", ap.label())
		}
		fixtures, notPods := apkFixtureCases(t, ap, p)
		cases := append(append([]apkCase{}, fixtures...), probes...)

		divs, skipped := apkScan(t, eng, o, ap.label(), p, groups, cases)
		names := make([]string, 0, len(groups))
		for _, g := range groups {
			names = append(names, fmt.Sprintf("%s(%s)", g.name, strings.Join(g.ours, "+")))
		}
		t.Logf("%s: %d checks, %d pod fixtures (%d non-pod objects: %s), groups: %s",
			ap.label(), len(p.Order), len(fixtures), len(notPods), strings.Join(notPods, ", "),
			strings.Join(names, " "))
		for _, s := range skipped {
			t.Logf("skipped: %s", s)
		}
		for _, d := range divs {
			t.Logf("divergence: %s", d)
		}
		all = append(all, divs...)
	}

	unexcused, stale := apkApplyExceptions(all, apkExceptions)
	for _, d := range unexcused {
		t.Errorf("UNEXCUSED DIVERGENCE from Pod Security Admission\n  %s\n"+
			"  Either the pack check is wrong (record it as a DEFECT CANDIDATE exception for the pack "+
			"owner) or the divergence is intended (record it as DELIBERATE with a one-line reason).", d)
	}
	for _, s := range stale {
		t.Errorf("STALE EXCEPTION: no longer diverges in the recorded direction. Delete the entry, narrow "+
			"its Cases/Groups, or re-state it.\n  %s", s)
	}
}

// --- mapping honesty: nothing may escape the oracle silently ----------------

// TestAllPacks_MappingCoversEveryPackCheck fails if a pack check is neither
// mapped to a PSA check nor explicitly declared unanchored with a reason. A new
// check in any of these packs must make a decision, not default to unexamined.
func TestAllPacks_MappingCoversEveryPackCheck(t *testing.T) {
	root, err := PolicyRoot()
	if err != nil {
		t.Fatal(err)
	}
	usedUnanchored := map[string]bool{}
	for _, ap := range apkPacks {
		p := apkLoadPack(t, root, ap)
		groups := apkActiveGroups(p)

		owner := map[string]string{}
		for _, g := range groups {
			if g.secondary {
				continue
			}
			for _, id := range g.ours {
				if prev, dup := owner[id]; dup {
					t.Errorf("%s: check %q owned by two primary groups: %s and %s", ap.label(), id, prev, g.name)
				}
				owner[id] = g.name
			}
		}
		for _, g := range groups {
			if !g.secondary {
				continue
			}
			for _, id := range g.ours {
				if _, owned := owner[id]; !owned {
					t.Errorf("%s: secondary group %s reads %q, which no primary group owns", ap.label(), g.name, id)
				}
			}
		}

		var mapped, unanchored []string
		for _, id := range p.Order {
			_, isMapped := owner[id]
			reason, isUnanchored := apkUnanchoredChecks[id]
			switch {
			case isMapped && isUnanchored:
				t.Errorf("%s: check %q is both mapped and declared unanchored", ap.label(), id)
			case !isMapped && !isUnanchored:
				t.Errorf("%s: check %q is neither mapped to a PSA check nor declared unanchored: "+
					"decide which, in apkGroupTemplates or apkUnanchoredChecks", ap.label(), id)
			case isMapped:
				mapped = append(mapped, id)
			default:
				if len(strings.TrimSpace(reason)) < 20 {
					t.Errorf("%s: unanchored check %q has no usable reason", ap.label(), id)
				}
				unanchored = append(unanchored, id)
				usedUnanchored[id] = true
			}
		}
		sort.Strings(mapped)
		sort.Strings(unanchored)
		t.Logf("%s: %d mapped (%s); %d unanchored (%s)",
			ap.label(), len(mapped), strings.Join(mapped, ", "), len(unanchored), strings.Join(unanchored, ", "))
	}

	// A declaration for a check no pack has is dead weight and hides a rename.
	for id := range apkUnanchoredChecks {
		if !usedUnanchored[id] {
			t.Errorf("apkUnanchoredChecks declares %q, which no pack in scope has (renamed or removed)", id)
		}
	}
}

// TestAllPacks_MappingCoversEveryPSACheck fails if upstream adds or renames a
// check: for every pack, a PSA check must be either mapped or carry a recorded
// reason for not being covered. Without this, an upstream rename turns the
// oracle into a no-op silently.
func TestAllPacks_MappingCoversEveryPSACheck(t *testing.T) {
	upstream := map[psapolicy.CheckID]bool{}
	for _, c := range psapolicy.DefaultChecks() {
		upstream[c.ID] = true
	}
	for id := range apkPSACheckAbsenceReason {
		if !upstream[id] {
			t.Errorf("apkPSACheckAbsenceReason names %q, which k8s.io/pod-security-admission does not have", id)
		}
	}
	root, err := PolicyRoot()
	if err != nil {
		t.Fatal(err)
	}
	for _, ap := range apkPacks {
		p := apkLoadPack(t, root, ap)
		mapped := map[psapolicy.CheckID]bool{}
		for _, g := range apkActiveGroups(p) {
			for _, id := range g.psa {
				if strings.HasPrefix(string(id), oracleAPIValidationPrefix) {
					continue // secondary oracle, not a PSA check
				}
				if !upstream[id] {
					t.Errorf("group %q maps PSA check %q, which upstream does not have (renamed or removed)", g.name, id)
				}
				mapped[id] = true
			}
		}
		for id := range upstream {
			if mapped[id] {
				continue
			}
			if _, declared := apkPSACheckAbsenceReason[id]; !declared {
				t.Errorf("%s: PSA check %q is neither mapped nor has a recorded absence reason: "+
					"upstream has ground this pack is not measured against", ap.label(), id)
			}
		}
	}
}

// TestAllPacks_MappedChecksReadTheObject is what makes one mapping table safe
// for six packs: a mapped check ID is mapped by SEMANTICS, so if a pack's
// expression for that ID stops reading the object, the PSA mapping is
// meaningless and the comparison becomes noise rather than evidence.
func TestAllPacks_MappedChecksReadTheObject(t *testing.T) {
	root, err := PolicyRoot()
	if err != nil {
		t.Fatal(err)
	}
	// Collected across packs so a divergence in a shared ID's expression is
	// reported rather than assumed away. It is NOT a failure (packs are owned
	// by different workers and may be fixed at different times), but it is the
	// signal that a shared group may need splitting.
	exprs := map[string]map[string][]string{}
	for _, ap := range apkPacks {
		p := apkLoadPack(t, root, ap)
		for _, g := range apkActiveGroups(p) {
			for _, id := range g.ours {
				expr := p.Checks[id].CELExpression
				if !strings.Contains(expr, "object") && !strings.Contains(expr, "manifest") {
					t.Errorf("%s: check %q is mapped to PSA %v but its expression reads neither object nor "+
						"manifest, so the mapping cannot mean anything: %q", ap.label(), id, g.psa, expr)
				}
				if p.Placeholder(id) {
					t.Errorf("%s: check %q is mapped to PSA %v but is a placeholder: a placeholder cannot be "+
						"anchored, declare it unanchored instead", ap.label(), id, g.psa)
				}
				if exprs[id] == nil {
					exprs[id] = map[string][]string{}
				}
				exprs[id][expr] = append(exprs[id][expr], ap.label())
			}
		}
	}
	for _, id := range oracleSortedKeys(exprs) {
		if len(exprs[id]) == 1 {
			continue
		}
		var where []string
		for _, packs := range exprs[id] {
			where = append(where, strings.Join(packs, "+"))
		}
		sort.Strings(where)
		t.Logf("NOTE: mapped check %q has %d distinct expressions across packs (%s). The shared group "+
			"may need splitting if the semantics, not just the wording, now differ.",
			id, len(exprs[id]), strings.Join(where, " vs "))
	}
}

// TestAllPacks_ScopeIsMeasuredNotAsserted re-derives the scope from the policy
// tree. A pack that grows an object-reading check, or a pod-shaped fixture,
// must be brought into this tier or explicitly declared out of it — the scope
// comment at the top of this file is not allowed to be the authority.
func TestAllPacks_ScopeIsMeasuredNotAsserted(t *testing.T) {
	root, err := PolicyRoot()
	if err != nil {
		t.Fatal(err)
	}
	inScope := map[string]bool{}
	for _, ap := range apkPacks {
		inScope[ap.id+"/"+ap.dir] = true
	}
	dirs, err := apkDiscoverPackDirs(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(dirs) < len(apkPacks)+len(apkOutOfScopePacks) {
		t.Fatalf("discovered only %d pack directories (%v), fewer than the %d declared: the discovery "+
			"walk is broken and this test would pass vacuously",
			len(dirs), dirs, len(apkPacks)+len(apkOutOfScopePacks))
	}
	for _, key := range dirs {
		parts := strings.SplitN(key, "/", 2)
		p, err := LoadPack(root, parts[0], parts[1])
		if err != nil {
			t.Errorf("%s: %v", key, err)
			continue
		}
		readsObject := false
		for _, id := range p.Order {
			if p.Placeholder(id) {
				continue
			}
			e := p.Checks[id].CELExpression
			if strings.Contains(e, "object") || strings.Contains(e, "manifest") {
				readsObject = true
				break
			}
		}
		pods := 0
		if fixtures, err := LoadFixtures(p); err == nil {
			for _, f := range fixtures {
				if oraclePodShaped(f.Input.Object) {
					pods++
				}
			}
		}
		anchorable := readsObject && pods > 0
		_, declaredOut := apkOutOfScopePacks[key]
		switch {
		case inScope[key] && declaredOut:
			t.Errorf("%s is both in scope and declared out of scope", key)
		case inScope[key] && !anchorable:
			t.Errorf("%s is in scope but has readsObject=%v podFixtures=%d: it cannot be anchored by a pod "+
				"oracle, so it must not be in apkPacks", key, readsObject, pods)
		case !inScope[key] && !declaredOut:
			t.Errorf("%s is a pack this tier neither measures nor declares out of scope "+
				"(readsObject=%v podFixtures=%d). Add it to apkPacks or apkOutOfScopePacks.", key, readsObject, pods)
		case !inScope[key] && declaredOut && anchorable && key != "cis-kubernetes/v1.8":
			t.Errorf("%s is declared out of scope but now reads the object (%v) and has %d pod-shaped "+
				"fixtures: it is anchorable and the declaration is stale.", key, readsObject, pods)
		}
	}
}

// apkDiscoverPackDirs lists every <id>/<version> directory under
// policy/frameworks that carries a framework.json.
func apkDiscoverPackDirs(policyRoot string) ([]string, error) {
	var out []string
	ids, err := osReadDirNames(policyRoot + "/frameworks")
	if err != nil {
		return nil, err
	}
	for _, id := range ids {
		versions, err := osReadDirNames(policyRoot + "/frameworks/" + id)
		if err != nil {
			continue
		}
		for _, v := range versions {
			if fileExists(policyRoot + "/frameworks/" + id + "/" + v + "/framework.json") {
				out = append(out, id+"/"+v)
			}
		}
	}
	sort.Strings(out)
	return out, nil
}

// TestAllPacks_ExceptionsAreWellFormed keeps the exception list honest: known
// pack, case and group names, no duplicates, a classification prefix and a
// reason on every entry.
func TestAllPacks_ExceptionsAreWellFormed(t *testing.T) {
	root, err := PolicyRoot()
	if err != nil {
		t.Fatal(err)
	}
	type packInfo struct {
		groups map[string]bool
		cases  map[string]bool
	}
	info := map[string]packInfo{}
	for _, ap := range apkPacks {
		p := apkLoadPack(t, root, ap)
		pi := packInfo{groups: map[string]bool{}, cases: map[string]bool{}}
		for _, g := range apkActiveGroups(p) {
			pi.groups[g.name] = true
		}
		fixtures, _ := apkFixtureCases(t, ap, p)
		for _, c := range fixtures {
			pi.cases[c.name] = true
		}
		for n := range apkProbePods {
			pi.cases[n] = true
		}
		info[ap.label()] = pi
	}
	for i, e := range apkExceptions {
		if len(e.Groups) == 0 || len(e.Cases) == 0 {
			t.Errorf("exception %d (%s) has an empty Groups or Cases list, so it asserts nothing", i, e.Pack)
		}
		if len(strings.TrimSpace(e.Reason)) < 40 {
			t.Errorf("exception %d (%s) has no usable reason", i, e.Pack)
		}
		classified := false
		for _, prefix := range apkExceptionPrefixes {
			if strings.HasPrefix(e.Reason, prefix) {
				classified = true
			}
		}
		if !classified {
			t.Errorf("exception %d (%s) reason must start with one of %v so the lead can route it: %q",
				i, e.Pack, apkExceptionPrefixes, e.Reason)
		}
	}
	seen := map[string]bool{}
	defects, deliberate := 0, 0
	for _, k := range apkExpandExceptions(apkExceptions) {
		key := k.pack + "|" + k.caseName + "/" + k.group
		if seen[key] {
			t.Errorf("duplicate exception key %s: two entries claim the same (pack, case, group)", key)
		}
		seen[key] = true
		pi, ok := info[k.pack]
		if !ok {
			t.Errorf("exception %s names unknown pack %q", key, k.pack)
			continue
		}
		if !pi.groups[k.group] {
			t.Errorf("exception %s names a group %q that is not active for that pack", key, k.group)
		}
		if !pi.cases[k.caseName] {
			t.Errorf("exception %s names unknown fixture or probe %q", key, k.caseName)
		}
		if strings.HasPrefix(apkExceptions[k.entry].Reason, "DEFECT CANDIDATE") {
			defects++
		} else {
			deliberate++
		}
	}
	t.Logf("%d exception entries expand to %d keys: %d DEFECT CANDIDATE, %d DELIBERATE",
		len(apkExceptions), defects+deliberate, defects, deliberate)
}

// --- negative tests: a green oracle that cannot go red is worthless ---------

// apkInvertedPack returns a pack with one check's expression negated. The pack
// on disk is untouched; the inversion exists only in this process.
func apkInvertedPack(t *testing.T, real *Pack, invert string) *Pack {
	t.Helper()
	out := &Pack{ID: real.ID, Version: real.Version, Status: real.Status, Dir: real.Dir, Checks: map[string]Check{}}
	found := false
	for _, id := range real.Order {
		c := real.Checks[id]
		if id == invert {
			c.CELExpression = "!(" + c.CELExpression + ")"
			found = true
		}
		out.Order = append(out.Order, id)
		out.Checks[id] = c
	}
	if !found {
		t.Fatalf("cannot invert %q: the pack has no such check", invert)
	}
	return out
}

// TestAllPacksNegative_InvertedCheckIsCaught inverts EVERY mapped expression of
// EVERY pack in memory and asserts the tier reports a new divergence in that
// check's group. A mapped check whose inversion goes unnoticed is not actually
// anchored, and the mapping table is telling a story the tier cannot back.
func TestAllPacksNegative_InvertedCheckIsCaught(t *testing.T) {
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	o, err := newPSAOracle()
	if err != nil {
		t.Fatal(err)
	}
	root, err := PolicyRoot()
	if err != nil {
		t.Fatal(err)
	}
	probes := apkProbeCases(t)
	for _, ap := range apkPacks {
		p := apkLoadPack(t, root, ap)
		groups := apkActiveGroups(p)
		fixtures, _ := apkFixtureCases(t, ap, p)
		cases := append(append([]apkCase{}, fixtures...), probes...)

		baseline, _ := apkScan(t, eng, o, ap.label(), p, groups, cases)
		baselineKeys := map[string]bool{}
		for _, d := range baseline {
			baselineKeys[d.Case+"/"+d.Group] = true
		}
		for _, g := range groups {
			if g.secondary {
				continue
			}
			for _, id := range g.ours {
				t.Run(ap.label()+"/"+id, func(t *testing.T) {
					divs, _ := apkScan(t, eng, o, ap.label(), apkInvertedPack(t, p, id), groups, cases)
					fresh := 0
					for _, d := range divs {
						if d.Group == g.name && !baselineKeys[d.Case+"/"+d.Group] {
							fresh++
						}
					}
					if fresh == 0 {
						t.Fatalf("inverting %q produced no new divergence in group %q: the oracle cannot "+
							"detect a wrong verdict for this check", id, g.name)
					}
					unexcused, _ := apkApplyExceptions(divs, apkExceptions)
					if len(unexcused) == 0 {
						t.Fatalf("inverting %q produced %d divergences but the exception list excused all "+
							"of them: the exception list is too broad", id, len(divs))
					}
					t.Logf("inverting %q: %d new divergences in %q, %d unexcused overall",
						id, fresh, g.name, len(unexcused))
				})
			}
		}
	}
}

// TestAllPacksNegative_EvalErrorIsNeverAgreement proves an un-evaluable check
// is skipped and counted, never read as agreement with the oracle. An
// expression that errors returns VerdictError, and the quietest possible
// failure of this tier would be to treat that as "the pack is fine".
func TestAllPacksNegative_EvalErrorIsNeverAgreement(t *testing.T) {
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	o, err := newPSAOracle()
	if err != nil {
		t.Fatal(err)
	}
	root, err := PolicyRoot()
	if err != nil {
		t.Fatal(err)
	}
	ap := apkPack{"nist-800-53", "v2.0", "v2.0.0"}
	p := apkLoadPack(t, root, ap)
	groups := apkActiveGroups(p)
	// One probe PSA rejects on the privileged check, so a working comparison
	// has something to disagree about.
	cases := []apkCase{}
	for _, c := range apkProbeCases(t) {
		if c.name == "apk-probe-privileged-container" {
			cases = append(cases, c)
		}
	}
	if len(cases) != 1 {
		t.Fatalf("expected exactly one probe case, got %d", len(cases))
	}

	// Sanity: unmodified, the pack and PSA agree that this pod is inadmissible.
	if divs, skipped := apkScan(t, eng, o, ap.label(), p, groups, cases); len(divs) != 0 || len(skipped) != 0 {
		t.Fatalf("baseline: divs=%d skipped=%d, want 0 and 0 (%v / %v)", len(divs), len(skipped), divs, skipped)
	}

	// An expression that compiles but cannot evaluate against a pod object.
	broken := &Pack{ID: p.ID, Version: p.Version, Status: p.Status, Dir: p.Dir, Checks: map[string]Check{}}
	for _, id := range p.Order {
		c := p.Checks[id]
		if id == "no-privileged-mode" {
			c.CELExpression = "object.spec.thisFieldDoesNotExist.atAll == true"
		}
		broken.Order = append(broken.Order, id)
		broken.Checks[id] = c
	}
	divs, skipped := apkScan(t, eng, o, ap.label(), broken, groups, cases)
	for _, d := range divs {
		if d.Group == "privileged" {
			t.Errorf("an erroring check produced a divergence verdict rather than a skip: %s", d)
		}
	}
	found := false
	for _, s := range skipped {
		if strings.Contains(s, "privileged") && strings.Contains(s, "not comparable") {
			found = true
		}
	}
	if !found {
		t.Errorf("an erroring check was not reported as skipped; skipped=%v", skipped)
	}
	// And the error must really have happened, or this test proves nothing.
	v := oracleOurVerdicts(eng, broken, oracleRoundTrip(t, cases[0].object))["no-privileged-mode"]
	if v != VerdictError {
		t.Errorf("broken expression produced verdict %s, want %s: rewrite this test's broken expression", v, VerdictError)
	}
}

// TestAllPacksNegative_StaleExceptionIsCaught proves the stale-exception
// interlock bites for the pack-scoped exception type: an exception for a case
// that agrees, one whose recorded direction is backwards, and one whose pack is
// wrong are all reported.
func TestAllPacksNegative_StaleExceptionIsCaught(t *testing.T) {
	div := apkDivergence{
		Pack: "nist-800-53@v2.0", Case: "apk-probe-host-ipc-only", Group: "hostNamespaces",
		OursPass: true, PSAAllow: false, Detail: "x",
	}
	reason := "DELIBERATE placeholder reason long enough to pass the well-formedness check"

	t.Run("exception for a case that does not diverge", func(t *testing.T) {
		exc := []apkException{{Pack: div.Pack, Cases: []string{"apk-probe-restricted-compliant"},
			Groups: []string{"privileged"}, OursPass: true, PSAAllow: false, Reason: reason}}
		unexcused, stale := apkApplyExceptions(nil, exc)
		if len(stale) != 1 || len(unexcused) != 0 {
			t.Fatalf("stale=%d unexcused=%d, want 1 and 0", len(stale), len(unexcused))
		}
	})
	t.Run("exception with the direction reversed", func(t *testing.T) {
		exc := []apkException{{Pack: div.Pack, Cases: []string{div.Case}, Groups: []string{div.Group},
			OursPass: false, PSAAllow: true, Reason: reason}}
		unexcused, stale := apkApplyExceptions([]apkDivergence{div}, exc)
		if len(stale) != 1 {
			t.Errorf("reversed exception not reported stale: %d", len(stale))
		}
		if len(unexcused) != 1 {
			t.Errorf("real divergence excused by a reversed exception: %d unexcused", len(unexcused))
		}
	})
	t.Run("exception for the wrong pack", func(t *testing.T) {
		exc := []apkException{{Pack: "eu-ai-act@v2.0", Cases: []string{div.Case}, Groups: []string{div.Group},
			OursPass: div.OursPass, PSAAllow: div.PSAAllow, Reason: reason}}
		unexcused, stale := apkApplyExceptions([]apkDivergence{div}, exc)
		if len(stale) != 1 || len(unexcused) != 1 {
			t.Fatalf("stale=%d unexcused=%d, want 1 and 1: an exception must not cross packs", len(stale), len(unexcused))
		}
	})
	t.Run("matching exception excuses and is not stale", func(t *testing.T) {
		exc := []apkException{{Pack: div.Pack, Cases: []string{div.Case}, Groups: []string{div.Group},
			OursPass: div.OursPass, PSAAllow: div.PSAAllow, Reason: reason}}
		unexcused, stale := apkApplyExceptions([]apkDivergence{div}, exc)
		if len(stale) != 0 || len(unexcused) != 0 {
			t.Fatalf("stale=%d unexcused=%d, want 0 and 0", len(stale), len(unexcused))
		}
	})
	// The product is the assertion: an entry whose Cases list grows a member
	// that does not diverge must go stale for that member alone, not be
	// forgiven because its siblings matched.
	t.Run("partially stale entry is reported per key", func(t *testing.T) {
		exc := []apkException{{Pack: div.Pack, Groups: []string{div.Group},
			Cases:    []string{div.Case, "apk-probe-restricted-compliant"},
			OursPass: div.OursPass, PSAAllow: div.PSAAllow, Reason: reason}}
		unexcused, stale := apkApplyExceptions([]apkDivergence{div}, exc)
		if len(stale) != 1 || len(unexcused) != 0 {
			t.Fatalf("stale=%d unexcused=%d, want 1 and 0", len(stale), len(unexcused))
		}
		if !strings.Contains(stale[0], "apk-probe-restricted-compliant") {
			t.Errorf("stale report names the wrong key: %s", stale[0])
		}
	})
}

// TestAllPacksNegative_GroupNarrowingCannotEmptyAGroup proves apkActiveGroups
// narrows rather than silently drops: a group whose checks a pack does not have
// must disappear, and one whose checks it has must keep exactly those.
func TestAllPacksNegative_GroupNarrowingCannotEmptyAGroup(t *testing.T) {
	root, err := PolicyRoot()
	if err != nil {
		t.Fatal(err)
	}
	// eu-ai-act v1.0 has no capability, seccomp or host-namespace check.
	p := apkLoadPack(t, root, apkPack{"eu-ai-act", "v1.0", "v1.0.0"})
	got := map[string][]string{}
	for _, g := range apkActiveGroups(p) {
		if len(g.ours) == 0 {
			t.Fatalf("group %q survived narrowing with no checks: it would compare the conjunction of "+
				"nothing (always pass) against PSA", g.name)
		}
		got[g.name] = g.ours
	}
	for _, absent := range []string{"capabilities", "seccompProfile", "seccompAPIValidation", "hostNamespaces", "podSecurityContext"} {
		if _, ok := got[absent]; ok {
			t.Errorf("group %q is active for eu-ai-act@v1.0, which has none of its checks", absent)
		}
	}
	for _, present := range []string{"privileged", "allowPrivilegeEscalation", "runAsNonRoot"} {
		if _, ok := got[present]; !ok {
			t.Errorf("group %q is not active for eu-ai-act@v1.0, which has its check", present)
		}
	}
	// nist-800-53 v2.0 has only two of the three host namespaces, and the group
	// must carry exactly those two — a group silently widened to a check the
	// pack lacks would make every case skip.
	n := apkLoadPack(t, root, apkPack{"nist-800-53", "v2.0", "v2.0.0"})
	for _, g := range apkActiveGroups(n) {
		if g.name != "hostNamespaces" {
			continue
		}
		if strings.Join(g.ours, ",") != "no-host-network,no-host-pid" {
			t.Errorf("hostNamespaces group for nist-800-53@v2.0 is %v, want [no-host-network no-host-pid]", g.ours)
		}
	}
}

// --- small filesystem helpers (kept here, not in engine.go, so this file can
// --- be reverted without touching the shared module) ------------------------

func osReadDirNames(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out, nil
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}
