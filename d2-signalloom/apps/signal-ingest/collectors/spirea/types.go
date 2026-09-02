// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package spirea

import (
	"time"
)

// SVIDType defines the format of the issued credential (X.509 or JWT).
type SVIDType string

const (
	SVIDTypeX509 SVIDType = "X509"
	SVIDTypeJWT  SVIDType = "JWT"
)

// SVIDIssuanceEvent represents an attestation and credential issuance event from SPIRE.
type SVIDIssuanceEvent struct {
	Timestamp      time.Time `json:"timestamp"`
	SPIFFEID       string    `json:"spiffe_id"`
	TrustDomain    string    `json:"trust_domain"`
	SVIDType       SVIDType  `json:"svid_type"`
	SerialNumber   string    `json:"serial_number,omitempty"`
	JWTID          string    `json:"jwt_id,omitempty"`
	IssuedAt       time.Time `json:"issued_at"`
	ExpiresAt      time.Time `json:"expires_at"`
	TTLSeconds     int64     `json:"ttl_seconds"`
	PodName        string    `json:"pod_name,omitempty"`
	PodNamespace   string    `json:"pod_namespace,omitempty"`
	ServiceAccount string    `json:"service_account,omitempty"`
	NodeName       string    `json:"node_name,omitempty"`
	Selectors      []string  `json:"selectors,omitempty"`
}

// ActiveIdentityLease tracks the runtime mapping between a SPIFFE SVID and an OpenBao accessor.
type ActiveIdentityLease struct {
	SPIFFEID       string
	Namespace      string
	ServiceAccount string
	AgentRole      string
	AccessorHash   string
	IssuedAt       time.Time
	ExpiresAt      time.Time
	LastActivity   time.Time
	ActiveLeases   []string
}
