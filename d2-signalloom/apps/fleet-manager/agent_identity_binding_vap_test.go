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
	vars            []admissionv1.Variable
	validations     []admissionv1.Validation
	matchConditions []admissionv1.MatchCondition
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
			p = identityBindingPolicy{
				vars:            obj.Spec.Variables,
				validations:     obj.Spec.Validations,
				matchConditions: obj.Spec.MatchConditions,
			}
			found = true
		}
	}
	if !found {
		t.Fatalf("sl-agent-identity-binding not found in %s", identityBindingPolicyPath)
	}
	return p
}

// matches evaluates this policy's matchConditions against pod, the way the
// real API server does BEFORE resolving params or running variables/
// validations: only object/oldObject/request are in scope, no params or
// variables. true means the request would actually reach the validations
// this test file's admit() evaluates; false means the API server would
// never run this policy's CEL at all for this object.
func (p identityBindingPolicy) matches(t *testing.T, pod *corev1.Pod) bool {
	t.Helper()
	env, err := cel.NewEnv(
		cel.Variable("object", cel.DynType),
		cel.Variable("oldObject", cel.DynType),
		cel.Variable("request", cel.DynType),
	)
	if err != nil {
		t.Fatal(err)
	}
	act := map[string]any{
		"object":    asIdentityCEL(t, pod),
		"oldObject": nil,
		"request":   map[string]any{"operation": "CREATE"},
	}
	for _, mc := range p.matchConditions {
		ast, iss := env.Compile(mc.Expression)
		if iss.Err() != nil {
			t.Fatalf("compile matchCondition %q: %v", mc.Name, iss.Err())
		}
		prg, err := env.Program(ast)
		if err != nil {
			t.Fatal(err)
		}
		out, _, err := prg.Eval(act)
		if err != nil {
			t.Fatalf("eval matchCondition %q: %v", mc.Name, err)
		}
		ok, isBool := out.Value().(bool)
		if !isBool || !ok {
			return false
		}
	}
	return true
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
// entries as the admission-time params object would receive them: one
// identity.<name> (ServiceAccount) and identity-ns.<name> (namespace) key
// pair per registered agent, mirroring base/configmap.yaml exactly.
func identityMapConfigMap(entries map[string]AgentIdentity) *corev1.ConfigMap {
	data := make(map[string]string, len(entries)*2)
	for name, id := range entries {
		data["identity."+name] = id.ServiceAccount
		data["identity-ns."+name] = id.Namespace
	}
	return &corev1.ConfigMap{Data: data}
}

func identityPod(namespace, agentNameLabel, serviceAccount string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: namespace,
			Labels:    map[string]string{"signalloom.ai/agent-name": agentNameLabel},
		},
		Spec: corev1.PodSpec{ServiceAccountName: serviceAccount},
	}
}

func kusariIdentityParams() *corev1.ConfigMap {
	return identityMapConfigMap(map[string]AgentIdentity{
		"kusari-agent": {Namespace: "fe-signalloom-agents", ServiceAccount: "kusari-agent"},
	})
}

func TestIdentityBindingVAP_SpoofedServiceAccountIsRejected(t *testing.T) {
	p := loadIdentityBindingPolicy(t)
	params := kusariIdentityParams()
	decoy := identityPod("fe-signalloom-agents", "kusari-agent", "hosted-daytona-coder")

	msg := p.admit(t, decoy, params)
	if msg == "" {
		t.Fatal("a pod labelled kusari-agent but running as hosted-daytona-coder was admitted; want it rejected")
	}
	if !strings.Contains(msg, "kusari-agent") || !strings.Contains(msg, "hosted-daytona-coder") {
		t.Fatalf("message = %q, want it to name both the claimed identity and the actual ServiceAccount", msg)
	}
}

// TestIdentityBindingVAP_RightServiceAccountNameButWrongNamespaceIsRejected is
// the direct case Andy's decision names: a ServiceAccount name is only
// unique within its namespace, so a decoy in hosted-daytona-coder's own
// namespace that names its own ServiceAccount literally "kusari-agent" --
// the right name -- must still be rejected, because kusari-agent is
// registered to run in fe-signalloom-agents, not there.
func TestIdentityBindingVAP_RightServiceAccountNameButWrongNamespaceIsRejected(t *testing.T) {
	p := loadIdentityBindingPolicy(t)
	params := kusariIdentityParams()
	decoy := identityPod("hosted-daytona-coder-workspace", "kusari-agent", "kusari-agent")

	msg := p.admit(t, decoy, params)
	if msg == "" {
		t.Fatal("the right ServiceAccount name in the wrong namespace was admitted; want it rejected")
	}
	if !strings.Contains(msg, "fe-signalloom-agents") || !strings.Contains(msg, "hosted-daytona-coder-workspace") {
		t.Fatalf("message = %q, want it to name both the registered and actual namespace", msg)
	}
}

func TestIdentityBindingVAP_MatchingNamespaceAndServiceAccountIsAdmitted(t *testing.T) {
	p := loadIdentityBindingPolicy(t)
	params := kusariIdentityParams()
	legit := identityPod("fe-signalloom-agents", "kusari-agent", "kusari-agent")

	if msg := p.admit(t, legit, params); msg != "" {
		t.Fatalf("the real kusari-agent pod was denied: %s", msg)
	}
}

func TestIdentityBindingVAP_UnregisteredAgentNameIsAdmitted(t *testing.T) {
	p := loadIdentityBindingPolicy(t)
	params := kusariIdentityParams()
	// cardvault is not registered in this params object: the policy must not
	// become a second allow-list for which agents may exist.
	pod := identityPod("fe-signalloom-agents", "cardvault", "literally-anything")

	if msg := p.admit(t, pod, params); msg != "" {
		t.Fatalf("an unregistered agent-name label was denied: %s", msg)
	}
}

func TestIdentityBindingVAP_HalfAuthoredEntryIsTreatedAsUnregistered(t *testing.T) {
	// A params object carrying only the ServiceAccount half (no
	// identity-ns.* key) must not be treated as "registered with an empty
	// namespace": that would reject every real pod with no namespace label
	// drift at all. Mirrors identity_map.go/agent_identity_map.py exactly.
	p := loadIdentityBindingPolicy(t)
	params := &corev1.ConfigMap{Data: map[string]string{"identity.kusari-agent": "kusari-agent"}}
	pod := identityPod("fe-signalloom-agents", "kusari-agent", "kusari-agent")

	if msg := p.admit(t, pod, params); msg != "" {
		t.Fatalf("a half-authored identity entry denied a pod it should treat as unregistered: %s", msg)
	}
}

func TestIdentityBindingVAP_NoAgentNameLabelIsAdmitted(t *testing.T) {
	p := loadIdentityBindingPolicy(t)
	params := kusariIdentityParams()
	pod := &corev1.Pod{Spec: corev1.PodSpec{ServiceAccountName: "default"}}

	if msg := p.admit(t, pod, params); msg != "" {
		t.Fatalf("a pod with no agent-name label was denied: %s", msg)
	}
}

// TestIdentityBindingVAP_BindingDeniesOnMissingParams is a structural
// assertion, not a CEL evaluation: parameterNotFoundAction is enforced by
// the API server's param-resolution step, BEFORE matchConditions or this
// policy's CEL ever run (loadIdentityBindingPolicy's admit()/matches()
// harnesses have no way to simulate that step -- feeding params: nil into
// CEL directly, as an earlier version of this test did, proves nothing
// about the real "ConfigMap not found" path, which never reaches CEL at
// all when this field is Deny). The field must be Deny: fleet-config
// missing must not silently admit every spoof.
func TestIdentityBindingVAP_BindingDeniesOnMissingParams(t *testing.T) {
	raw, err := os.ReadFile(identityBindingPolicyPath)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, doc := range strings.Split(string(raw), "\n---\n") {
		var obj admissionv1.ValidatingAdmissionPolicyBinding
		if err := yaml.Unmarshal([]byte(doc), &obj); err != nil {
			t.Fatal(err)
		}
		if obj.Kind != "ValidatingAdmissionPolicyBinding" || obj.Name != "sl-agent-identity-binding-binding" {
			continue
		}
		found = true
		if obj.Spec.ParamRef == nil {
			t.Fatal("binding declares no paramRef")
		}
		action := obj.Spec.ParamRef.ParameterNotFoundAction
		if action == nil || *action != admissionv1.DenyAction {
			got := "<nil>"
			if action != nil {
				got = string(*action)
			}
			t.Fatalf("paramRef.parameterNotFoundAction = %s, want %q: a missing fleet-config ConfigMap must deny, not silently admit every spoof",
				got, admissionv1.DenyAction)
		}
	}
	if !found {
		t.Fatalf("sl-agent-identity-binding-binding not found in %s", identityBindingPolicyPath)
	}
}

// TestIdentityBindingVAP_CELItselfStillAdmitsOnNilParams documents the one
// remaining CEL-level fact, now academic in production because
// parameterNotFoundAction: Deny means the API server never lets CEL see a
// nil params in the first place: `registered` requires params != null, so
// if CEL ever DID run with nil params -- it cannot, under Deny -- it would
// treat every identity as unregistered and admit. This is not a gap: it is
// why parameterNotFoundAction, not CEL, is the correct place to enforce
// fail-closed-on-missing-ConfigMap.
func TestIdentityBindingVAP_CELItselfStillAdmitsOnNilParams(t *testing.T) {
	p := loadIdentityBindingPolicy(t)
	decoy := identityPod("fe-signalloom-agents", "kusari-agent", "hosted-daytona-coder")

	if msg := p.admit(t, decoy, nil); msg != "" {
		t.Fatalf("CEL with a nil params denied unexpectedly: %s", msg)
	}
}

// ── matchConditions: the policy runs for ANY namespace, gated only on
// carrying the agent-name label (sldc/sa-identity gap 2) ───────────────────

func TestIdentityBindingVAP_MatchConditionsSkipAPodWithNoAgentNameLabel(t *testing.T) {
	p := loadIdentityBindingPolicy(t)
	if len(p.matchConditions) == 0 {
		t.Fatal("policy declares no matchConditions; a cluster-wide matchResources with no match condition would run this CEL on every pod in the cluster")
	}
	ordinary := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Namespace: "some-other-namespace"},
		Spec:       corev1.PodSpec{ServiceAccountName: "default"},
	}
	if p.matches(t, ordinary) {
		t.Fatal("a pod with no signalloom.ai/agent-name label must not match -- the point of matchConditions is to skip it")
	}
}

func TestIdentityBindingVAP_MatchConditionsRunForAnyNamespaceThatCarriesTheLabel(t *testing.T) {
	// The whole point of gap 2: a decoy in hosted-daytona-coder's own
	// namespace that carries the agent-name label must still reach the
	// validations -- matchConditions filters on the LABEL, never on
	// namespace.
	p := loadIdentityBindingPolicy(t)
	decoy := identityPod("hosted-daytona-coder-workspace", "kusari-agent", "kusari-agent")
	if !p.matches(t, decoy) {
		t.Fatal("a pod carrying signalloom.ai/agent-name must match regardless of namespace -- that is the entire point of removing the namespaceSelector")
	}
}

func TestIdentityBindingVAP_BindingHasNoNamespaceRestriction(t *testing.T) {
	raw, err := os.ReadFile(identityBindingPolicyPath)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, doc := range strings.Split(string(raw), "\n---\n") {
		var obj admissionv1.ValidatingAdmissionPolicyBinding
		if err := yaml.Unmarshal([]byte(doc), &obj); err != nil {
			t.Fatal(err)
		}
		if obj.Kind != "ValidatingAdmissionPolicyBinding" || obj.Name != "sl-agent-identity-binding-binding" {
			continue
		}
		found = true
		if obj.Spec.MatchResources != nil && obj.Spec.MatchResources.NamespaceSelector != nil {
			t.Fatalf("binding still restricts matchResources to a namespaceSelector (%+v); "+
				"the spoof this policy guards against is cross-namespace, so a namespace "+
				"restriction here would defeat it", obj.Spec.MatchResources.NamespaceSelector)
		}
	}
	if !found {
		t.Fatalf("sl-agent-identity-binding-binding not found in %s", identityBindingPolicyPath)
	}
}
