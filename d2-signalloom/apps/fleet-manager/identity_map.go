package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// AgentIdentityMap is the single source of truth binding a
// signalloom.ai/agent-name label value to the ServiceAccount the real agent
// runs as. It exists because a label is written by whoever creates the pod —
// including a workload with pod-create RBAC in the agents namespace, such as
// hosted-daytona-coder — so a label match alone can never prove identity. The
// same mapping, read from the same ConfigMap, backs:
//
//   - fleet-manager's own resolution (agent_resolution.go, k8sclient.go)
//   - the ValidatingAdmissionPolicy at
//     d2-agent-trust/policies/agent-identity-binding.yaml, which admits this
//     ConfigMap as its params object.
//
// There is exactly one authored list: the `identity.<agent-name>` keys of the
// fleet-config ConfigMap (base/configmap.yaml). Nothing else hardcodes it.
const identityKeyPrefix = "identity."

// AgentIdentityMap maps a signalloom.ai/agent-name label value to the
// ServiceAccount name the real agent is registered to run as.
type AgentIdentityMap struct {
	byAgentName map[string]string
}

// NewAgentIdentityMap wraps a pre-built mapping, mostly for tests.
func NewAgentIdentityMap(byAgentName map[string]string) *AgentIdentityMap {
	m := make(map[string]string, len(byAgentName))
	for k, v := range byAgentName {
		m[k] = v
	}
	return &AgentIdentityMap{byAgentName: m}
}

// LoadAgentIdentityMap reads every `identity.<agent-name>` file in dir — each
// one a key of the fleet-config ConfigMap, materialised as a file by the
// kubelet's ConfigMap volume plugin — and returns the agent-name -> expected
// ServiceAccount mapping. A missing directory is not an error: it means this
// deployment mounts no identity map, and callers treat a nil/empty map as "no
// registered mapping", never as "deny everything".
func LoadAgentIdentityMap(dir string) (*AgentIdentityMap, error) {
	m := &AgentIdentityMap{byAgentName: map[string]string{}}
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
	for _, e := range entries {
		if e.IsDir() || !strings.HasPrefix(e.Name(), identityKeyPrefix) {
			continue
		}
		agentName := strings.TrimPrefix(e.Name(), identityKeyPrefix)
		if agentName == "" {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			return nil, fmt.Errorf("read agent identity map entry %s: %w", e.Name(), err)
		}
		sa := strings.TrimSpace(string(raw))
		if sa == "" {
			continue
		}
		m.byAgentName[agentName] = sa
	}
	return m, nil
}

// ExpectedServiceAccount returns the ServiceAccount a registered agent name
// must run as, and whether that agent name is registered at all. An
// unregistered name (ok == false) is not a verdict — callers must not treat an
// unknown name as either trusted or denied on this basis alone.
func (m *AgentIdentityMap) ExpectedServiceAccount(agentName string) (string, bool) {
	if m == nil || agentName == "" {
		return "", false
	}
	sa, ok := m.byAgentName[agentName]
	return sa, ok
}

// Len reports how many agent names are registered. A nil map reports 0.
func (m *AgentIdentityMap) Len() int {
	if m == nil {
		return 0
	}
	return len(m.byAgentName)
}

// Matches reports whether actualServiceAccount is consistent with the
// registered identity for agentName. An unregistered agentName always
// matches — this guard only ever narrows a SPOOF of a KNOWN identity, it never
// turns into a second allow-list for which agents may exist.
func (m *AgentIdentityMap) Matches(agentName, actualServiceAccount string) bool {
	expected, ok := m.ExpectedServiceAccount(agentName)
	if !ok {
		return true
	}
	return expected == actualServiceAccount
}
