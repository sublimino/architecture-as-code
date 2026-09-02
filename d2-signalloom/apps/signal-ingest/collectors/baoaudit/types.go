// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package baoaudit

import (
	"time"
)

// OpenBaoAuditEvent models the standard JSON audit log format emitted by OpenBao audit devices.
type OpenBaoAuditEvent struct {
	Type     string            `json:"type"` // "request" or "response"
	Time     string            `json:"time"`
	Auth     *AuditAuth        `json:"auth,omitempty"`
	Request  *AuditRequest     `json:"request,omitempty"`
	Response *AuditResponse    `json:"response,omitempty"`
	Error    string            `json:"error,omitempty"`
}

// AuditAuth contains authentication and token context for the operation.
type AuditAuth struct {
	ClientToken   string            `json:"client_token,omitempty"`
	Accessor      string            `json:"accessor,omitempty"`
	DisplayName   string            `json:"display_name,omitempty"`
	Policies      []string          `json:"policies,omitempty"`
	TokenPolicies []string          `json:"token_policies,omitempty"`
	Metadata      map[string]string `json:"metadata,omitempty"`
	EntityID      string            `json:"entity_id,omitempty"`
	TokenType     string            `json:"token_type,omitempty"`
	TokenTTL      int64             `json:"token_ttl,omitempty"`
	TokenIssueTime string           `json:"token_issue_time,omitempty"`
}

// AuditRequest contains the request parameters sent to OpenBao.
type AuditRequest struct {
	ID                  string                 `json:"id,omitempty"`
	ClientID            string                 `json:"client_id,omitempty"`
	Operation           string                 `json:"operation"` // "read", "create", "update", "delete", "list", "renew", "revoke"
	ClientToken         string                 `json:"client_token,omitempty"`
	ClientTokenAccessor string                 `json:"client_token_accessor,omitempty"`
	Namespace           map[string]interface{} `json:"namespace,omitempty"`
	Path                string                 `json:"path"`
	Data                map[string]interface{} `json:"data,omitempty"`
	PolicyOverride      bool                   `json:"policy_override,omitempty"`
	RemoteAddress       string                 `json:"remote_address,omitempty"`
	WrapTTL             int64                  `json:"wrap_ttl,omitempty"`
	Headers             map[string]interface{} `json:"headers,omitempty"`
}

// AuditResponse contains the outcome returned by OpenBao.
type AuditResponse struct {
	StatusCode int                    `json:"status_code,omitempty"`
	Headers    map[string]interface{} `json:"headers,omitempty"`
	Data       map[string]interface{} `json:"data,omitempty"`
	Auth       *AuditAuth             `json:"auth,omitempty"`
	Secret     *AuditSecret           `json:"secret,omitempty"`
	MountType  string                 `json:"mount_type,omitempty"`
}

// AuditSecret contains lease metadata for dynamic secrets.
type AuditSecret struct {
	LeaseID       string `json:"lease_id,omitempty"`
	Renewable     bool   `json:"renewable,omitempty"`
	LeaseDuration int64  `json:"lease_duration,omitempty"`
}

// ParsedAuditRecord is the enriched internal representation of an OpenBao audit event.
type ParsedAuditRecord struct {
	Timestamp      time.Time
	Type           string
	Operation      string
	Path           string
	AccessorHash   string
	SPIFFEID       string
	Namespace      string
	ServiceAccount string
	AgentRole      string
	Policies       []string
	LeaseID        string
	LeaseDuration  time.Duration
	IsError        bool
	ErrorMessage   string
	RawJSON        []byte
}
