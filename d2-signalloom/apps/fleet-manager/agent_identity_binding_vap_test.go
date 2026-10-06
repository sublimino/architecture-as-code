package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/google/cel-go/cel"
	admissionv1 "k8s.io/api/admissionregistration/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/yaml"
)

// agent_identity_binding_vap_test.go evaluates the CEL in
// base/agent-identity-binding.yaml against the exact pod shapes
// hosted-daytona-coder could create versus a legitimate agent pod, using the
// same cel-go harness vap_admission_test.go uses for the sibling
// state-protection policy -- except this policy declares a paramKind, so the
// harness here also binds `params` to the fleet-config ConfigMap, which is
// how the real admission control plane evaluates it against a resolved
// ValidatingAdmissionPolicyBinding.paramRef.

const identityBindingPolicyPath = "base/agent-identity-binding.yaml"

type identityBindingPolicy struct {
	vars        []admissionv1.Variable
	validations []admissionv1.Validation
}

func loadIdentityBindingPolicy(t *testing.T) identityBindingPolicy {
	t.Helper()
	raw, err := os.ReadFile(identityBindingPolicyPath)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	var p identityBindingPolicy
	for _, doc := range strings.Split(string(raw), "\n---\n") {
		var obj admissionv1.ValidatingAdmissionPolicy
		if err := yaml.Unmarshal([]byte(doc), &obj); err != nil {
			t.Fatal(err)
		}
		if obj.Kind == "ValidatingAdmissionPolicy" && obj.Name == "sl-agent-identity-binding" {
			if len(obj.Spec.Validations) == 0 {
				t.Fatal("policy has no validations")
			}
			p = identityBindingPolicy{vars: obj.Spec.Variables, validations: obj.Spec.Validations}
			found = true
		}
	}
	if !found {
		t.Fatalf("sl-agent-identity-binding not found in %s", identityBindingPolicyPath)
	}
	return p
}

func asIdentityCEL(t *testing.T, v any) any {
	t.Helper()
	if v == nil {
		return nil
	}
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// admit evaluates a CREATE of pod with the given params object (the
// fleet-config ConfigMap, or nil for "no params resolved"). It returns ""
// when admitted, else the first failing validation's rendered message.
func (p identityBindingPolicy) admit(t *testing.T, pod *corev1.Pod, params *corev1.ConfigMap) string {
	t.Helper()
	env, err := cel.NewEnv(
		cel.Variable("object", cel.DynType),
		cel.Variable("oldObject", cel.DynType),
		cel.Variable("request", cel.DynType),
		cel.Variable("params", cel.DynType),
		cel.Variable("variables", cel.MapType(cel.StringType, cel.DynType)),
	)
	if err != nil {
		t.Fatal(err)
	}
	vars := map[string]any{}
	act := map[string]any{
		"object":    asIdentityCEL(t, pod),
		"oldObject": nil,
		"request":   map[string]any{"operation": "CREATE"},
		"params":    asIdentityCEL(t, params),
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
		ok, isBool := eval(v.Expression).(bool)
		if !isBool || !ok {
			if v.MessageExpression != "" {
				msg, _ := eval(v.MessageExpression).(string)
				return strings.TrimSpace(msg)
			}
			return strings.TrimSpace(v.Message)
		}
	}
	return ""
}

// identityMapConfigMap builds the real fleet-config ConfigMap's identity
// entries as the admission-time params object would receive them.
func identityMapConfigMap(entries map[string]string) *corev1.ConfigMap {
	data := make(map[string]string, len(entries))
	for name, sa := range entries {
		data["identity."+name] = sa
	}
	return &corev1.ConfigMap{Data: data}
}

func identityPod(agentNameLabel, serviceAccount string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Labels: map[string]string{"signalloom.ai/agent-name": agentNameLabel},
		},
		Spec: corev1.PodSpec{ServiceAccountName: serviceAccount},
	}
}

func TestIdentityBindingVAP_SpoofedServiceAccountIsRejected(t *testing.T) {
	p := loadIdentityBindingPolicy(t)
	params := identityMapConfigMap(map[string]string{"kusari-agent": "kusari-agent"})
	decoy := identityPod("kusari-agent", "hosted-daytona-coder")

	msg := p.admit(t, decoy, params)
	if msg == "" {
		t.Fatal("a pod labelled kusari-agent but running as hosted-daytona-coder was admitted; want it rejected")
	}
	if !strings.Contains(msg, "kusari-agent") || !strings.Contains(msg, "hosted-daytona-coder") {
		t.Fatalf("message = %q, want it to name both the claimed identity and the actual ServiceAccount", msg)
	}
}

func TestIdentityBindingVAP_MatchingServiceAccountIsAdmitted(t *testing.T) {
	p := loadIdentityBindingPolicy(t)
	params := identityMapConfigMap(map[string]string{"kusari-agent": "kusari-agent"})
	legit := identityPod("kusari-agent", "kusari-agent")

	if msg := p.admit(t, legit, params); msg != "" {
		t.Fatalf("the real kusari-agent pod was denied: %s", msg)
	}
}

func TestIdentityBindingVAP_UnregisteredAgentNameIsAdmitted(t *testing.T) {
	p := loadIdentityBindingPolicy(t)
	params := identityMapConfigMap(map[string]string{"kusari-agent": "kusari-agent"})
	// cardvault is not registered in this params object: the policy must not
	// become a second allow-list for which agents may exist.
	pod := identityPod("cardvault", "literally-anything")

	if msg := p.admit(t, pod, params); msg != "" {
		t.Fatalf("an unregistered agent-name label was denied: %s", msg)
	}
}

func TestIdentityBindingVAP_NoAgentNameLabelIsAdmitted(t *testing.T) {
	p := loadIdentityBindingPolicy(t)
	params := identityMapConfigMap(map[string]string{"kusari-agent": "kusari-agent"})
	pod := &corev1.Pod{Spec: corev1.PodSpec{ServiceAccountName: "default"}}

	if msg := p.admit(t, pod, params); msg != "" {
		t.Fatalf("a pod with no agent-name label was denied: %s", msg)
	}
}

func TestIdentityBindingVAP_NilParamsAdmitsEverything(t *testing.T) {
	// parameterNotFoundAction: Allow -- if the ConfigMap is ever missing,
	// this policy must fail open on the identity check (fleet-manager's own
	// in-process guard, nil-safe by the same design, is the other layer),
	// never fail closed and brick every agent pod creation in the namespace.
	p := loadIdentityBindingPolicy(t)
	decoy := identityPod("kusari-agent", "hosted-daytona-coder")

	if msg := p.admit(t, decoy, nil); msg != "" {
		t.Fatalf("missing params must admit (parameterNotFoundAction: Allow), got denial: %s", msg)
	}
}
