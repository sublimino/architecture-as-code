package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/cel-go/cel"
	admissionv1 "k8s.io/api/admissionregistration/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/yaml"
)

// fleet-manager is the authorised releaser, but the CEL admission policy that
// guards signalloom.ai/state=stunned admitted only swarm-governor and cluster
// admins. Every live /recover therefore failed its release with
//
//	ValidatingAdmissionPolicy 'sl-agent-identity-state-protection' ... the
//	signalloom.ai/state=stunned label cannot be removed or mutated by any
//	identity other than the Swarm Governor ... or cluster admin
//
// These tests evaluate the deployed policy's own CEL (read from the YAML that
// Flux applies) against the exact pod object fleet-manager's SetPodState
// writes, as the identity fleet-manager's own manifests give it.

const vapPolicyPath = "../../../d2-agent-trust/policies/agent-identity-state-protection.yaml"

type admissionPolicy struct {
	vars        []admissionv1.Variable
	validations []admissionv1.Validation
}

func loadAdmissionPolicy(t *testing.T) admissionPolicy {
	t.Helper()
	raw, err := os.ReadFile(vapPolicyPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, doc := range strings.Split(string(raw), "\n---\n") {
		var p admissionv1.ValidatingAdmissionPolicy
		if err := yaml.Unmarshal([]byte(doc), &p); err != nil {
			t.Fatal(err)
		}
		if p.Kind == "ValidatingAdmissionPolicy" && p.Name == "sl-agent-identity-state-protection" {
			if len(p.Spec.Validations) == 0 {
				t.Fatal("policy has no validations")
			}
			return admissionPolicy{vars: p.Spec.Variables, validations: p.Spec.Validations}
		}
	}
	t.Fatalf("sl-agent-identity-state-protection not found in %s", vapPolicyPath)
	return admissionPolicy{}
}

func asCEL(t *testing.T, v any) any {
	t.Helper()
	if v == nil {
		return nil
	}
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// admit evaluates an UPDATE of oldPod to newPod by username. It returns ""
// when admitted, else the first failing validation's message.
func (p admissionPolicy) admit(t *testing.T, oldPod, newPod *corev1.Pod, username string, groups ...string) string {
	t.Helper()
	env, err := cel.NewEnv(
		cel.Variable("object", cel.DynType),
		cel.Variable("oldObject", cel.DynType),
		cel.Variable("request", cel.DynType),
		cel.Variable("variables", cel.MapType(cel.StringType, cel.DynType)),
	)
	if err != nil {
		t.Fatal(err)
	}
	if groups == nil {
		groups = []string{"system:authenticated"}
	}
	vars := map[string]any{}
	act := map[string]any{
		"object":    asCEL(t, newPod),
		"oldObject": asCEL(t, oldPod),
		"request":   map[string]any{"operation": "UPDATE", "userInfo": map[string]any{"username": username, "groups": groups}},
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

// fleetManagerUsername derives the API username from the manifests that
// deploy fleet-manager: the Deployment's serviceAccountName and that
// ServiceAccount's namespace.
func fleetManagerUsername(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("base", "deployment.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var d appsv1.Deployment
	if err := yaml.Unmarshal(raw, &d); err != nil {
		t.Fatal(err)
	}
	sa := d.Spec.Template.Spec.ServiceAccountName
	if sa == "" {
		t.Fatal("fleet-manager Deployment names no serviceAccountName")
	}
	raw, err = os.ReadFile(filepath.Join("base", "rbac.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	for _, doc := range strings.Split(string(raw), "\n---\n") {
		var o corev1.ServiceAccount
		if err := yaml.Unmarshal([]byte(doc), &o); err != nil {
			t.Fatal(err)
		}
		if o.Kind == "ServiceAccount" && o.Name == sa {
			return "system:serviceaccount:" + o.Namespace + ":" + sa
		}
	}
	t.Fatalf("no ServiceAccount %q in base/rbac.yaml", sa)
	return ""
}

func stunnedAgentPod() *corev1.Pod {
	return agentPod("agent-kusari", StateStunned, map[string]string{
		StunnedLabel:              "true",
		ContainmentModeLabel:      ContainmentModeFrozen,
		"signalloom.ai/framework": "custom",
	})
}

// releasedBy runs fleet-manager's real release write and returns the pod it
// produced.
func releasedBy(t *testing.T, stunned *corev1.Pod) *corev1.Pod {
	t.Helper()
	c, cs := newTestK8sClient(stunned.DeepCopy())
	if err := c.SetPodState(context.Background(), testNamespace, "agent-kusari", StateRunning); err != nil {
		t.Fatal(err)
	}
	got, err := cs.CoreV1().Pods(testNamespace).Get(context.Background(), stunned.Name, metav1.GetOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if got.Labels[PodStateLabel] == StateStunned {
		t.Fatal("the release write left the pod stunned; nothing to admit")
	}
	return got
}

func TestTheAdmissionPolicyAdmitsFleetManagerReleasingAStunnedAgent(t *testing.T) {
	p := loadAdmissionPolicy(t)
	user := fleetManagerUsername(t)
	if user != "system:serviceaccount:fe-signalloom:fleet-manager" {
		t.Fatalf("fleet-manager identity = %q", user)
	}
	stunned := stunnedAgentPod()
	if msg := p.admit(t, stunned, releasedBy(t, stunned), user); msg != "" {
		t.Fatalf("fleet-manager's release was denied: %s", msg)
	}
}

func TestTheAdmissionPolicyStillDeniesEveryOtherIdentityTheRelease(t *testing.T) {
	p := loadAdmissionPolicy(t)
	stunned := stunnedAgentPod()
	released := releasedBy(t, stunned)
	for _, user := range []string{
		"system:serviceaccount:fe-signalloom-agents:kusari-agent",  // the tenant itself
		"system:serviceaccount:fe-signalloom-agents:fleet-manager", // right name, tenant namespace
		"system:serviceaccount:fe-signalloom:fleet-manager-shadow", // prefix lookalike
		"system:serviceaccount:fe-signalloom-agents:stun-sentinel", // stuns, never releases
		"system:serviceaccount:fe-signalloom:fleet-manager:extra",  // suffix lookalike
		"fleet-manager", // bare name, no SA
	} {
		msg := p.admit(t, stunned, released, user, "system:serviceaccounts", "system:serviceaccounts:fe-signalloom", "system:authenticated")
		if !strings.Contains(msg, "cannot be removed or mutated") {
			t.Errorf("%s: release admitted (msg %q); only fleet-manager and the governors may release", user, msg)
		}
	}
}

func TestTheAdmissionPolicyKeepsStunningOpenToTheSentinel(t *testing.T) {
	p := loadAdmissionPolicy(t)
	running := agentPod("agent-kusari", PodStateLabelValue(StateRunning), map[string]string{"signalloom.ai/framework": "custom"})
	stunned := stunnedAgentPod()
	if msg := p.admit(t, running, stunned, "system:serviceaccount:fe-signalloom-agents:stun-sentinel"); msg != "" {
		t.Fatalf("a stun was denied: %s", msg)
	}
}
