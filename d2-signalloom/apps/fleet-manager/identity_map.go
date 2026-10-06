package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// AgentIdentityMap is the single source of truth binding a
// signalloom.ai/agent-name label value to the NAMESPACE and ServiceAccount
// the real agent is registered to run as. It exists because a label is
// written by whoever creates the pod — including a workload with pod-create
// RBAC in the agents namespace, such as hosted-daytona-coder — so a label
// match alone can never prove identity. Both namespace and ServiceAccount
// are required: a ServiceAccount name is only unique within its namespace,
// so a decoy in a different namespace that happens to name its own
// ServiceAccount "kusari-agent" must not pass a check that compares the
// ServiceAccount name alone. The same mapping, read from the same
// ConfigMap, backs:
//
//   - fleet-manager's own resolution (agent_resolution.go, k8sclient.go,
//     mesh_client.go)
//   - the ValidatingAdmissionPolicy at base/agent-identity-binding.yaml,
//     which admits this ConfigMap as its params object.
//
// There is exactly one authored list: the `identity.<agent-name>` (the
// ServiceAccount) and `identity-ns.<agent-name>` (the namespace) key pairs
// of the fleet-config ConfigMap (base/configmap.yaml). Nothing else
// hardcodes it.
const (
	identityKeyPrefix          = "identity."
	identityNamespaceKeyPrefix = "identity-ns."
)

// AgentIdentity is the namespace and ServiceAccount a registered agent name
// is bound to.
type AgentIdentity struct {
	Namespace      string
	ServiceAccount string
}

// AgentIdentityMap maps a signalloom.ai/agent-name label value to the
// namespace and ServiceAccount the real agent is registered to run as.
type AgentIdentityMap struct {
	byAgentName map[string]AgentIdentity
}

// NewAgentIdentityMap wraps a pre-built mapping, mostly for tests.
func NewAgentIdentityMap(byAgentName map[string]AgentIdentity) *AgentIdentityMap {
	m := make(map[string]AgentIdentity, len(byAgentName))
	for k, v := range byAgentName {
		m[k] = v
	}
	return &AgentIdentityMap{byAgentName: m}
}

// LoadAgentIdentityMap reads every `identity.<agent-name>` and
// `identity-ns.<agent-name>` file in dir — each one a key of the
// fleet-config ConfigMap, materialised as a file by the kubelet's ConfigMap
// volume plugin — and returns the agent-name -> expected (namespace,
// ServiceAccount) mapping. A missing directory is not an error: it means
// this deployment mounts no identity map, and callers treat a nil/empty map
// as "no registered mapping", never as "deny everything". An agent name
// with only one of the two keys present is dropped from the map entirely
// (not "registered with an empty namespace"): a half-authored entry is a
// misconfiguration, and treating it as unregistered is the safe reading,
// never a guess at the missing half.
func LoadAgentIdentityMap(dir string) (*AgentIdentityMap, error) {
	m := &AgentIdentityMap{byAgentName: map[string]AgentIdentity{}}
	if dir == "" {
		return m, nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return m, nil
		}
		return nil, fmt.Errorf("read agent identity map dir %s: %w", dir, err)
	}

	serviceAccounts := map[string]string{}
	namespaces := map[string]string{}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		switch {
		case strings.HasPrefix(e.Name(), identityNamespaceKeyPrefix):
			agentName := strings.TrimPrefix(e.Name(), identityNamespaceKeyPrefix)
			if agentName == "" {
				continue
			}
			value, err := readTrimmedFile(dir, e.Name())
			if err != nil {
				return nil, err
			}
			if value != "" {
				namespaces[agentName] = value
			}
		case strings.HasPrefix(e.Name(), identityKeyPrefix):
			agentName := strings.TrimPrefix(e.Name(), identityKeyPrefix)
			if agentName == "" {
				continue
			}
			value, err := readTrimmedFile(dir, e.Name())
			if err != nil {
				return nil, err
			}
			if value != "" {
				serviceAccounts[agentName] = value
			}
		}
	}

	for agentName, sa := range serviceAccounts {
		if ns, ok := namespaces[agentName]; ok {
			m.byAgentName[agentName] = AgentIdentity{Namespace: ns, ServiceAccount: sa}
		}
	}
	return m, nil
}

func readTrimmedFile(dir, name string) (string, error) {
	raw, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return "", fmt.Errorf("read agent identity map entry %s: %w", name, err)
	}
	return strings.TrimSpace(string(raw)), nil
}

// Expected returns the namespace and ServiceAccount a registered agent name
// must run as, and whether that agent name is registered at all. An
// unregistered name (ok == false) is not a verdict — callers must not treat
// an unknown name as either trusted or denied on this basis alone.
func (m *AgentIdentityMap) Expected(agentName string) (AgentIdentity, bool) {
	if m == nil || agentName == "" {
		return AgentIdentity{}, false
	}
	id, ok := m.byAgentName[agentName]
	return id, ok
}

// Len reports how many agent names are registered. A nil map reports 0.
func (m *AgentIdentityMap) Len() int {
	if m == nil {
		return 0
	}
	return len(m.byAgentName)
}

// Matches reports whether actualNamespace and actualServiceAccount are BOTH
// consistent with the registered identity for agentName. An unregistered
// agentName always matches — this guard only ever narrows a SPOOF of a KNOWN
// identity, it never turns into a second allow-list for which agents may
// exist. A ServiceAccount name is only unique within its namespace, so
// checking the ServiceAccount alone would let a decoy in a different
// namespace that names its own ServiceAccount after a registered agent pass
// this guard; both fields are required to match.
func (m *AgentIdentityMap) Matches(agentName, actualNamespace, actualServiceAccount string) bool {
	expected, ok := m.Expected(agentName)
	if !ok {
		return true
	}
	return expected.Namespace == actualNamespace && expected.ServiceAccount == actualServiceAccount
}
