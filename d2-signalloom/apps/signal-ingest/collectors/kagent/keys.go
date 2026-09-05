// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package kagent

// Calibration constants pinned from live Kagent invocation trace.
const (
	// RuntimeVersion0_9_9 is the pinned upstream Kagent chart/ADK runtime version.
	RuntimeVersion0_9_9 = "0.9.9"

	// DefaultTrustDomain is the canonical SPIFFE trust domain for Signal Loom.
	DefaultTrustDomain = "signalloom.demo"

	// OTel span names emitted by Kagent runtime and Go ADK.
	SpanNameExecute       = "Execute"
	SpanNameToolExecution = "Tool execution"
	SpanNameTaskAlt       = "kagent.task"
	SpanNameToolAlt       = "agent.tool"

	// OTel attribute keys for agent identity.
	AttrAgentNamespace   = "kagent.namespace"
	AttrAgentName        = "kagent.agent_name"
	AttrAppName          = "kagent.app_name"
	AttrServiceNamespace = "service.namespace"
	AttrServiceName      = "service.name"

	// OTel attribute keys for tool execution.
	AttrToolName          = "tool.name"
	AttrToolNameAlt       = "tool"
	AttrFunctionCallID    = "tool.function_call_id"
	AttrFunctionCallIDAlt = "functionCallID"

	// A2A protocol context attribute keys.
	AttrContextID        = "a2a.context_id"
	AttrContextIDAlt     = "contextID"
	AttrContextIDSession = "sessionID"
	AttrTaskID           = "a2a.task_id"
	AttrTaskIDAlt        = "taskID"
	AttrUserID           = "a2a.user_id"
	AttrUserIDAlt        = "userID"
	AttrAuthType         = "a2a.auth_type"
	AttrAuthTypeAlt      = "auth_type"
	AttrRuntimeVersion   = "kagent.runtime_version"
)
