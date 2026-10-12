// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package k8saudit is the Kubernetes kube-apiserver audit THREAT vertical: one
// projection of a kube-apiserver audit event onto a model.Observation on
// model.LayerKubernetes, Source "k8saudit-kube", fed by a pluggable Source
// (warden-local file / fixture live today; EKS/GKE/AKS cloud seams deferred).
//
// It is deliberately decoupled from the existing api/audit package, which
// projects the SAME source onto model.LayerIdentityAuth for delegation and
// impersonation tracking. The split is documented in contract_doc.go: that one
// answers "who delegated to whom", this one answers "what dangerous thing was
// done in the cluster". They coexist; neither is the other's refactor.
package k8saudit

import "time"

// AuditEvent is the subset of an audit.k8s.io/v1 Event this vertical reads. It
// is this package's own wire type, not api/audit.K8sEvent, so the two verticals
// cannot drift into each other through a shared struct — the same reason obscel
// defines its own Observation rather than importing the app type.
type AuditEvent struct {
	AuditID                  string            `json:"auditID"`
	Stage                    string            `json:"stage"`
	Verb                     string            `json:"verb"`
	User                     UserInfo          `json:"user"`
	ImpersonatedUser         *UserInfo         `json:"impersonatedUser,omitempty"`
	SourceIPs                []string          `json:"sourceIPs,omitempty"`
	UserAgent                string            `json:"userAgent,omitempty"`
	ObjectRef                *ObjectRef        `json:"objectRef,omitempty"`
	ResponseStatus           *ResponseStatus   `json:"responseStatus,omitempty"`
	Annotations              map[string]string `json:"annotations,omitempty"`
	RequestObject            *TypeMeta         `json:"requestObject,omitempty"`
	StageTimestamp           time.Time         `json:"stageTimestamp"`
	RequestReceivedTimestamp time.Time         `json:"requestReceivedTimestamp"`
}

// UserInfo is the audit user record. Only the username is read; groups and UID
// are identity detail this vertical does not project (identity lives in the
// pseudonymised actor, never in a label).
type UserInfo struct {
	Username string `json:"username"`
}

// ObjectRef is the audited resource reference.
type ObjectRef struct {
	Resource    string `json:"resource"`
	Namespace   string `json:"namespace,omitempty"`
	Name        string `json:"name,omitempty"`
	APIGroup    string `json:"apiGroup,omitempty"`
	APIVersion  string `json:"apiVersion,omitempty"`
	Subresource string `json:"subresource,omitempty"`
}

// ResponseStatus is the audited response. Code becomes response_code; Reason
// becomes the reason label.
type ResponseStatus struct {
	Code   int32  `json:"code"`
	Reason string `json:"reason,omitempty"`
}

// TypeMeta carries the Kind of a request object, the only field read from it so
// resource_kind can be projected without admitting the request body.
type TypeMeta struct {
	Kind string `json:"kind,omitempty"`
}

// EventList mirrors audit.k8s.io/v1 EventList, the shape the apiserver audit
// webhook POSTs. A warden-local file is JSON-lines of Event instead; the source
// handles both.
type EventList struct {
	Kind       string       `json:"kind"`
	APIVersion string       `json:"apiVersion"`
	Items      []AuditEvent `json:"items"`
}

// decisionAnnotation is the audit annotation the apiserver sets to the authorizer
// verdict ("allow" or "forbid"). It is the authoritative decision; the response
// code is only a fallback for a record that lacks it.
const decisionAnnotation = "authorization.k8s.io/decision"
