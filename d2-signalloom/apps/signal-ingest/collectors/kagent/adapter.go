// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package kagent

import (
	"fmt"
	"strings"
	"sync"
)

// ErrUnknownRuntimeVersion is returned when telemetry arrives from an unregistered Kagent runtime version.
var ErrUnknownRuntimeVersion = fmt.Errorf("unknown or unsupported kagent runtime version")

// RuntimeAdapter extracts agent, tool, and A2A context metadata from telemetry attributes
// according to the key schema of a specific Kagent runtime version.
type RuntimeAdapter interface {
	// Version returns the Kagent runtime version this adapter handles.
	Version() string
	// ExtractAgent retrieves the agent namespace and agent name from attributes.
	ExtractAgent(attrs map[string]string) (namespace, agentName string, ok bool)
	// ExtractTool retrieves the invoked tool name from attributes.
	ExtractTool(attrs map[string]string) (toolName string, ok bool)
	// ExtractContext retrieves the A2A context ID, task ID, caller ID, and authentication type.
	ExtractContext(attrs map[string]string) (contextID, taskID, callerID, authType string)
}

// KeySet represents a set of attribute keys for a specific Kagent runtime version.
type KeySet struct {
	VersionKey            string
	AgentNamespaceKeys    []string
	AgentNameKeys         []string
	AppNameKey            string
	ToolNameKeys          []string
	FunctionCallIDKeys    []string
	ContextIDKeys         []string
	TaskIDKeys            []string
	UserIDKeys            []string
	AuthTypeKeys          []string
}

// VersionedAdapter implements RuntimeAdapter using a configurable KeySet.
type VersionedAdapter struct {
	keySet KeySet
}

// NewVersionedAdapter creates a RuntimeAdapter backed by the provided KeySet.
func NewVersionedAdapter(ks KeySet) *VersionedAdapter {
	return &VersionedAdapter{keySet: ks}
}

func (a *VersionedAdapter) Version() string {
	return a.keySet.VersionKey
}

func (a *VersionedAdapter) ExtractAgent(attrs map[string]string) (string, string, bool) {
	var ns, name string
	for _, k := range a.keySet.AgentNamespaceKeys {
		if v, ok := attrs[k]; ok && v != "" {
			ns = v
			break
		}
	}
	for _, k := range a.keySet.AgentNameKeys {
		if v, ok := attrs[k]; ok && v != "" {
			name = v
			break
		}
	}

	// Fallback: parse app_name if available (e.g., "fe_signalloom_agents__NS__kagent_k8s_reader")
	if (ns == "" || name == "") && a.keySet.AppNameKey != "" {
		if appName, ok := attrs[a.keySet.AppNameKey]; ok && appName != "" {
			parsedNs, parsedName := parseAppName(appName)
			if ns == "" {
				ns = parsedNs
			}
			if name == "" {
				name = parsedName
			}
		}
	}

	if ns != "" && name != "" {
		return ns, name, true
	}
	return "", "", false
}

func (a *VersionedAdapter) ExtractTool(attrs map[string]string) (string, bool) {
	for _, k := range a.keySet.ToolNameKeys {
		if v, ok := attrs[k]; ok && v != "" {
			return v, true
		}
	}
	return "", false
}

func (a *VersionedAdapter) ExtractContext(attrs map[string]string) (contextID, taskID, callerID, authType string) {
	for _, k := range a.keySet.ContextIDKeys {
		if v, ok := attrs[k]; ok && v != "" {
			contextID = v
			break
		}
	}
	for _, k := range a.keySet.TaskIDKeys {
		if v, ok := attrs[k]; ok && v != "" {
			taskID = v
			break
		}
	}
	for _, k := range a.keySet.UserIDKeys {
		if v, ok := attrs[k]; ok && v != "" {
			callerID = v
			break
		}
	}
	for _, k := range a.keySet.AuthTypeKeys {
		if v, ok := attrs[k]; ok && v != "" {
			authType = v
			break
		}
	}
	return
}

// AdapterRegistry manages versioned runtime adapters.
type AdapterRegistry struct {
	mu       sync.RWMutex
	adapters map[string]RuntimeAdapter
}

// NewAdapterRegistry creates an empty AdapterRegistry.
func NewAdapterRegistry() *AdapterRegistry {
	return &AdapterRegistry{
		adapters: make(map[string]RuntimeAdapter),
	}
}

// Register adds or replaces a RuntimeAdapter.
func (r *AdapterRegistry) Register(adapter RuntimeAdapter) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.adapters[adapter.Version()] = adapter
}

// Get finds an adapter for the requested runtime version, or returns ErrUnknownRuntimeVersion.
func (r *AdapterRegistry) Get(version string) (RuntimeAdapter, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	// Default fallback to 0.9.9 if version is empty
	if version == "" {
		version = RuntimeVersion0_9_9
	}

	adapter, ok := r.adapters[version]
	if !ok {
		return nil, fmt.Errorf("%w: %q (known versions: %v)", ErrUnknownRuntimeVersion, version, r.knownVersionsLocked())
	}
	return adapter, nil
}

func (r *AdapterRegistry) knownVersionsLocked() []string {
	var keys []string
	for k := range r.adapters {
		keys = append(keys, k)
	}
	return keys
}

// DefaultAdapterRegistry creates an AdapterRegistry seeded with the calibrated v0.9.9 adapter.
func DefaultAdapterRegistry() *AdapterRegistry {
	reg := NewAdapterRegistry()
	reg.Register(NewVersionedAdapter(KeySet{
		VersionKey: RuntimeVersion0_9_9,
		AgentNamespaceKeys: []string{
			AttrAgentNamespace,
			AttrServiceNamespace,
		},
		AgentNameKeys: []string{
			AttrAgentName,
			AttrServiceName,
		},
		AppNameKey: AttrAppName,
		ToolNameKeys: []string{
			AttrToolName,
			AttrToolNameAlt,
		},
		FunctionCallIDKeys: []string{
			AttrFunctionCallID,
			AttrFunctionCallIDAlt,
		},
		ContextIDKeys: []string{
			AttrContextID,
			AttrContextIDAlt,
			AttrContextIDSession,
		},
		TaskIDKeys: []string{
			AttrTaskID,
			AttrTaskIDAlt,
		},
		UserIDKeys: []string{
			AttrUserID,
			AttrUserIDAlt,
		},
		AuthTypeKeys: []string{
			AttrAuthType,
			AttrAuthTypeAlt,
		},
	}))
	return reg
}

func parseAppName(appName string) (string, string) {
	// Pattern: <namespace>__NS__<agent_name>
	parts := strings.Split(appName, "__NS__")
	if len(parts) == 2 {
		ns := strings.ReplaceAll(parts[0], "_", "-")
		name := strings.ReplaceAll(parts[1], "_", "-")
		return ns, name
	}
	return "", appName
}
