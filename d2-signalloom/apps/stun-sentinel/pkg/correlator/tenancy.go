// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"fmt"
	"regexp"
	"strings"
)

// UnattributedTenantID marks an observation from a workload the operator's
// tenant map does not name. It is signal-ingest's reserved quarantine tenant
// (identity.QuarantineTenant), which no principal may claim, and it cannot
// collide with a real tenant: underscores are outside the tenant grammar.
const UnattributedTenantID = "__unattributed__"

// retiredTenantTypo fails closed everywhere else in the estate
// (scripts/derive_tenant_hash.py RETIRED_TENANTS); it must not be configurable here.
const retiredTenantTypo = "kurasi"

var (
	// tenantNameRE is fe-signalloom's tenant grammar (pkg/tenant/hash.go).
	// ASCII only, so a homoglyph such as "kusarі" cannot be configured.
	tenantNameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)
	// dnsLabelRE is a Kubernetes namespace name.
	dnsLabelRE = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)
	// dnsSubdomainRE is a Kubernetes service account name.
	dnsSubdomainRE = regexp.MustCompile(`^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$`)
)

// TenantMap attributes a workload to a tenant from where it runs, never from
// anything it says about itself. Pod labels are written by whoever creates
// the pod, so they cannot carry tenancy (review M5).
//
// Keys are "namespace" or "namespace/serviceAccount"; a service account entry
// wins over its namespace's entry. A shared namespace such as
// fe-signalloom-agents should be mapped per service account only.
//
// Residual, stated plainly: anyone who can create pods in a namespace can run
// them as ANY service account in that namespace, so a service-account key is
// only as strong as the namespace's pod-create RBAC. The namespace is the real
// boundary.
type TenantMap struct {
	byNamespace      map[string]string
	byServiceAccount map[string]string // "namespace/serviceAccount"
}

// ParseTenantMap reads entries "key=tenant" separated by commas or newlines.
// Any malformed, non-ASCII, reserved or duplicate entry rejects the whole map:
// a partially applied map would attribute some workloads and silently not
// others.
func ParseTenantMap(spec string) (*TenantMap, error) {
	tm := &TenantMap{byNamespace: map[string]string{}, byServiceAccount: map[string]string{}}
	for _, entry := range strings.FieldsFunc(spec, func(r rune) bool { return r == ',' || r == '\n' }) {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		key, tenant, ok := strings.Cut(entry, "=")
		if !ok {
			return nil, fmt.Errorf("tenant map entry %q is not key=tenant", entry)
		}
		key, tenant = strings.TrimSpace(key), strings.TrimSpace(tenant)
		if !tenantNameRE.MatchString(tenant) {
			return nil, fmt.Errorf("tenant map entry %q: tenant %q must match %s", entry, tenant, tenantNameRE)
		}
		if tenant == retiredTenantTypo {
			return nil, fmt.Errorf("tenant map entry %q: tenant %q is the retired typo of kusari (Shared Pattern 1)", entry, tenant)
		}
		ns, sa, perSA := strings.Cut(key, "/")
		if !dnsLabelRE.MatchString(ns) {
			return nil, fmt.Errorf("tenant map entry %q: namespace %q is not a Kubernetes namespace name", entry, ns)
		}
		target := tm.byNamespace
		if perSA {
			if !dnsSubdomainRE.MatchString(sa) {
				return nil, fmt.Errorf("tenant map entry %q: service account %q is not a Kubernetes service account name", entry, sa)
			}
			target = tm.byServiceAccount
		}
		if _, dup := target[key]; dup {
			return nil, fmt.Errorf("tenant map entry %q: duplicate key %q", entry, key)
		}
		target[key] = tenant
	}
	return tm, nil
}

// Len is the number of entries.
func (t *TenantMap) Len() int {
	if t == nil {
		return 0
	}
	return len(t.byNamespace) + len(t.byServiceAccount)
}

// Resolve returns the tenant for a workload, or UnattributedTenantID.
func (t *TenantMap) Resolve(namespace, serviceAccount string) string {
	if t == nil {
		return UnattributedTenantID
	}
	if serviceAccount == "" {
		serviceAccount = "default" // what the API server admits an unset name as
	}
	if tenant, ok := t.byServiceAccount[namespace+"/"+serviceAccount]; ok {
		return tenant
	}
	if tenant, ok := t.byNamespace[namespace]; ok {
		return tenant
	}
	return UnattributedTenantID
}

// WithTenantMap sets the operator's tenant attribution. Without one, every
// observation is UnattributedTenantID.
func WithTenantMap(tm *TenantMap) Option {
	return func(m *SentinelProbeManager) {
		m.tenants = tm
	}
}
