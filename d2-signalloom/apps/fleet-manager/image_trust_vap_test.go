package main

import (
	"os"
	"strings"
	"testing"

	"github.com/google/cel-go/cel"
	admissionv1 "k8s.io/api/admissionregistration/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/yaml"
)

// image_trust_vap_test.go evaluates the CEL in the image-trust
// ValidatingAdmissionPolicies that replaced the Kyverno ClusterPolicy at
// policy/kyverno-verify-images.yaml (OSD-7). The Kyverno path required
// `kubectl apply -f https://github.com/kyverno/kyverno/releases/...` --
// an internet fetch an air-gapped appliance cannot make -- and shipped in
// no bundle image list, which is why the P2-4 deliverable "a digest-pinned
// platform image is admitted and an untrusted one rejected" was
// unsatisfiable as built. These two policies need no extra image: the API
// server is the admission engine.
//
// What changed in the GUARANTEE, and it is not a like-for-like swap:
// Kyverno's verifyImages performed CRYPTOGRAPHIC cosign verification at
// admission. CEL cannot -- it cannot call out, so it can only inspect the
// admission request's own fields. The trust chain is therefore two-layer:
// Flux verifies the cosign signature before the artefact reaches the
// in-cluster Zot registry (OCIRepository verify.provider: cosign), and
// these policies enforce that a pod may only pull a DIGEST-PINNED image
// FROM that registry. "In the registry" is the signature claim; "pinned to
// a digest from the registry" is what admission can prove. See
// docs/signalloom/image-verification-without-kyverno.md.
//
// These tests read the YAML that is actually applied, so a rename, a
// deletion, or a binding silently downgraded from Deny to Warn fails here
// rather than passing vacuously.
//
// @target policy/cel/require-trusted-registry.yaml
// @target policy/cel/require-image-digest.yaml
// @target policy/cel/admission-demo-bindings.yaml

const (
	trustedRegistryPolicyPath = "../../../policy/cel/require-trusted-registry.yaml"
	imageDigestPolicyPath     = "../../../policy/cel/require-image-digest.yaml"
	demoBindingsPath          = "../../../policy/cel/admission-demo-bindings.yaml"

	// The registry the demo and the platform both pull from. Flux pushes
	// only cosign-verified artefacts here, which is what makes "from this
	// registry" a signature claim rather than a hostname check.
	trustedRegistry = "zot.registry.svc.cluster.local:5000/acme"
)

// loadImageTrustPolicy returns the named ValidatingAdmissionPolicy from a
// multi-document YAML file. It t.Fatals rather than returning a zero value
// if the policy is absent or carries no validations: an empty policy
// admits everything, so a silent miss here would make every assertion
// below pass while proving nothing.
func loadImageTrustPolicy(t *testing.T, path, name string) admissionPolicy {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	for _, doc := range strings.Split(string(raw), "\n---\n") {
		var p admissionv1.ValidatingAdmissionPolicy
		if err := yaml.Unmarshal([]byte(doc), &p); err != nil {
			t.Fatalf("parse a document of %s: %v", path, err)
		}
		if p.Kind != "ValidatingAdmissionPolicy" || p.Name != name {
			continue
		}
		if len(p.Spec.Validations) == 0 {
			t.Fatalf("%s in %s has no validations -- it would admit every pod", name, path)
		}
		return admissionPolicy{vars: p.Spec.Variables, validations: p.Spec.Validations}
	}
	t.Fatalf("ValidatingAdmissionPolicy %q not found in %s -- renamed, removed, or moved", name, path)
	return admissionPolicy{}
}

// loadImageTrustBinding returns the named ValidatingAdmissionPolicyBinding
// from a multi-document YAML file, t.Fatalling if it is missing. A policy
// with no binding is applied to nothing and fails SILENTLY -- it is the
// single most dangerous state this change could land in, so it is asserted
// directly rather than inferred.
func loadImageTrustBinding(t *testing.T, path, name string) admissionv1.ValidatingAdmissionPolicyBinding {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	for _, doc := range strings.Split(string(raw), "\n---\n") {
		var b admissionv1.ValidatingAdmissionPolicyBinding
		if err := yaml.Unmarshal([]byte(doc), &b); err != nil {
			t.Fatalf("parse a document of %s: %v", path, err)
		}
		if b.Kind == "ValidatingAdmissionPolicyBinding" && b.Name == name {
			return b
		}
	}
	t.Fatalf("ValidatingAdmissionPolicyBinding %q not found in %s -- the policy would apply to nothing", name, path)
	return admissionv1.ValidatingAdmissionPolicyBinding{}
}

// admitPodCreate evaluates a CREATE of pod against every validation in the
// policy, returning "" when admitted or the first failing validation's
// message. Distinct from the sibling admit(): these policies match CREATE
// and UPDATE and read only `object`, so there is no oldObject and no
// userInfo to bind.
func (p admissionPolicy) admitPodCreate(t *testing.T, pod *corev1.Pod) string {
	t.Helper()
	// cel.OptionalTypes() is what makes this the API server's CEL
	// environment rather than base CEL: Kubernetes enables the optional
	// library, which is where `?field` selection and `.orValue()` come
	// from. Without it these policies do not even compile here, so a
	// harness missing it would be testing a different language than the
	// one that actually admits the pod.
	env, err := cel.NewEnv(
		cel.Variable("object", cel.DynType),
		cel.Variable("oldObject", cel.DynType),
		cel.Variable("request", cel.DynType),
		cel.Variable("variables", cel.MapType(cel.StringType, cel.DynType)),
		cel.OptionalTypes(),
	)
	if err != nil {
		t.Fatal(err)
	}
	vars := map[string]any{}
	act := map[string]any{
		"object":    asCEL(t, pod),
		"oldObject": nil,
		"request":   map[string]any{"operation": "CREATE"},
		"variables": vars,
	}
	eval := func(expr string) any {
		ast, iss := env.Compile(expr)
		if iss.Err() != nil {
			t.Fatalf("compile %q: %v", expr, iss.Err())
		}
		prg, err := env.Program(ast)
		if err != nil {
			t.Fatal(err)
		}
		out, _, err := prg.Eval(act)
		if err != nil {
			t.Fatalf("eval %q: %v", expr, err)
		}
		return out.Value()
	}
	for _, v := range p.vars {
		vars[v.Name] = eval(v.Expression)
	}
	for _, v := range p.validations {
		if ok, isBool := eval(v.Expression).(bool); !isBool || !ok {
			return strings.TrimSpace(v.Message)
		}
	}
	return ""
}

// podWithImages builds the minimal pod shape these policies read.
func podWithImages(images ...string) *corev1.Pod {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "probe", Namespace: "admission-demo"},
	}
	for i, img := range images {
		pod.Spec.Containers = append(pod.Spec.Containers, corev1.Container{
			Name:  "c" + string(rune('0'+i)),
			Image: img,
		})
	}
	return pod
}

// A digest a real crane push produced; only its shape matters here.
const probeDigest = "@sha256:2b7cc7d5e3a1f4c0b6d8e9a0f1c2d3e4a5b6c7d8e9f0a1b2c3d4e5f60718293a"

// ── The P2-4 / D4 deliverable, as two halves ────────────────────────────

func TestImageTrustVAP_AdmitsADigestPinnedPlatformImage(t *testing.T) {
	trusted := loadImageTrustPolicy(t, trustedRegistryPolicyPath, "sl-require-trusted-registry")
	digest := loadImageTrustPolicy(t, imageDigestPolicyPath, "sl-require-image-digest")

	pod := podWithImages(trustedRegistry + "/images/listener" + probeDigest)

	if msg := trusted.admitPodCreate(t, pod); msg != "" {
		t.Errorf("a digest-pinned image from the trusted registry was rejected by the registry policy: %s", msg)
	}
	if msg := digest.admitPodCreate(t, pod); msg != "" {
		t.Errorf("a digest-pinned image from the trusted registry was rejected by the digest policy: %s", msg)
	}
}

func TestImageTrustVAP_RejectsAnImageFromAnUntrustedRegistry(t *testing.T) {
	trusted := loadImageTrustPolicy(t, trustedRegistryPolicyPath, "sl-require-trusted-registry")

	// Digest-pinned, so the digest policy alone would admit it. The point
	// is that pinning a digest does not make a registry trustworthy: an
	// attacker controls both the tag AND the digest in their own registry.
	for _, img := range []string{
		"docker.io/library/nginx" + probeDigest,
		"evil.example.com/acme/images/listener" + probeDigest,
		// The near-miss that a naive `contains()` check would admit: the
		// trusted registry's name as a PATH SEGMENT of a hostile registry.
		"evil.example.com/zot.registry.svc.cluster.local:5000/acme/images/listener" + probeDigest,
	} {
		if msg := trusted.admitPodCreate(t, podWithImages(img)); msg == "" {
			t.Errorf("an image from an untrusted registry was ADMITTED: %s", img)
		}
	}
}

func TestImageTrustVAP_RejectsAnUnpinnedMutableTag(t *testing.T) {
	digest := loadImageTrustPolicy(t, imageDigestPolicyPath, "sl-require-image-digest")

	for _, img := range []string{
		trustedRegistry + "/images/listener:latest",
		trustedRegistry + "/images/listener:v1.2.3",
		trustedRegistry + "/images/listener",
	} {
		if msg := digest.admitPodCreate(t, podWithImages(img)); msg == "" {
			t.Errorf("an unpinned mutable tag was ADMITTED: %s", img)
		}
	}
}

// One trusted container alongside one untrusted container must deny: the
// CEL uses .all(), and a policy that admitted the pod because SOME
// container was fine would let a sidecar carry anything.
func TestImageTrustVAP_RejectsAPodWhereOnlyOneContainerIsUntrusted(t *testing.T) {
	trusted := loadImageTrustPolicy(t, trustedRegistryPolicyPath, "sl-require-trusted-registry")

	pod := podWithImages(
		trustedRegistry+"/images/listener"+probeDigest,
		"docker.io/library/nginx"+probeDigest,
	)
	if msg := trusted.admitPodCreate(t, pod); msg == "" {
		t.Error("a pod with one untrusted sidecar was ADMITTED")
	}
}

// An initContainer is a container that runs with the pod's volumes and
// service account. The registry policy carries a second validation for
// them precisely so an attacker cannot route around the first.
func TestImageTrustVAP_RejectsAnUntrustedInitContainer(t *testing.T) {
	trusted := loadImageTrustPolicy(t, trustedRegistryPolicyPath, "sl-require-trusted-registry")

	pod := podWithImages(trustedRegistry + "/images/listener" + probeDigest)
	pod.Spec.InitContainers = []corev1.Container{
		{Name: "init", Image: "evil.example.com/pwn" + probeDigest},
	}
	if msg := trusted.admitPodCreate(t, pod); msg == "" {
		t.Error("a pod with an untrusted initContainer was ADMITTED")
	}
}

// A pod with no initContainers at all must still be admitted. The CEL
// guards this with .orValue([]); without it the expression errors on a
// missing field and failurePolicy: Fail turns every ordinary pod into a
// rejection -- an outage, not a guardrail.
func TestImageTrustVAP_AdmitsAPodWithNoInitContainers(t *testing.T) {
	trusted := loadImageTrustPolicy(t, trustedRegistryPolicyPath, "sl-require-trusted-registry")

	pod := podWithImages(trustedRegistry + "/images/listener" + probeDigest)
	pod.Spec.InitContainers = nil
	if msg := trusted.admitPodCreate(t, pod); msg != "" {
		t.Errorf("a pod with no initContainers was rejected: %s", msg)
	}
}

// ── The bindings: a policy with no Deny binding enforces nothing ─────────

func TestImageTrustVAP_TheRegistryBindingDenies(t *testing.T) {
	b := loadImageTrustBinding(t, trustedRegistryPolicyPath, "sl-require-trusted-registry-binding")

	if b.Spec.PolicyName != "sl-require-trusted-registry" {
		t.Errorf("binding targets policyName %q, not the policy in this file", b.Spec.PolicyName)
	}
	assertDenies(t, b, "sl-require-trusted-registry-binding")
}

// The demo namespace is where the D4 deliverable is demonstrated, and the
// digest half of it is only a DENY there: the platform-wide digest binding
// is deliberately Warn (a lane-keeping control whose residual is priced in
// risk/, see docs/policy-as-versioned-code/INTEGRATION.md), so promoting
// it globally would silently reprice a published risk posture. The demo
// gets its own Deny binding instead.
func TestImageTrustVAP_TheDemoBindingsDenyInTheDemoNamespace(t *testing.T) {
	for _, tc := range []struct{ name, policy string }{
		{"sl-admission-demo-trusted-registry-binding", "sl-require-trusted-registry"},
		{"sl-admission-demo-image-digest-binding", "sl-require-image-digest"},
	} {
		b := loadImageTrustBinding(t, demoBindingsPath, tc.name)
		if b.Spec.PolicyName != tc.policy {
			t.Errorf("%s targets policyName %q, want %q", tc.name, b.Spec.PolicyName, tc.policy)
		}
		assertDenies(t, b, tc.name)

		if b.Spec.MatchResources == nil || b.Spec.MatchResources.NamespaceSelector == nil {
			t.Fatalf("%s has no namespaceSelector -- it would enforce cluster-wide, including on kube-system", tc.name)
		}
		got := b.Spec.MatchResources.NamespaceSelector.MatchLabels["kubernetes.io/metadata.name"]
		if got != "admission-demo" {
			t.Errorf("%s is scoped to namespace %q, want admission-demo", tc.name, got)
		}
	}
}

func assertDenies(t *testing.T, b admissionv1.ValidatingAdmissionPolicyBinding, name string) {
	t.Helper()
	for _, a := range b.Spec.ValidationActions {
		if a == admissionv1.Deny {
			return
		}
	}
	t.Errorf("%s does not Deny (validationActions=%v) -- a Warn-only binding logs the violation and admits the pod", name, b.Spec.ValidationActions)
}

// ── Kyverno is gone as a runtime dependency ──────────────────────────────

// The Kyverno ClusterPolicy must not come back. It was delivered by no
// Kustomization and no ResourceSet -- only imperatively, by
// scripts/admission-demo.sh, which fetched Kyverno's install.yaml from a
// GitHub release URL. Nothing in the bundle's 30-entry image list ever
// carried an admission controller, so the appliance could not have run it
// offline even if something had applied the policy.
func TestImageTrustVAP_TheKyvernoClusterPolicyIsGone(t *testing.T) {
	if _, err := os.Stat("../../../policy/kyverno-verify-images.yaml"); !os.IsNotExist(err) {
		t.Error("policy/kyverno-verify-images.yaml is back: the admission path must not depend on an unbundled controller")
	}
}
