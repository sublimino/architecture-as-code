// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build frostdb

package store

import (
	"errors"
	"fmt"
	"regexp"
	"sort"
)

// ErrLabelAllowListEmpty refuses an absent or empty allow-list.
//
// This is the fail-open case the card names explicitly. An empty set read as "no restriction
// configured, therefore allow everything" would leave the dynamic label space unbounded while the
// code reports that an allow-list is in force — a control that is present, configured, and inert.
var ErrLabelAllowListEmpty = errors.New(
	"store: label allow-list must be non-empty; an empty allow-list is a refusal, never a permit-all")

// DisallowedLabelKeyError names the key that was refused, so an operator can act on the message
// rather than bisecting a batch.
type DisallowedLabelKeyError struct {
	Key           string
	ObservationID string
}

func (e *DisallowedLabelKeyError) Error() string {
	return fmt.Sprintf(
		"store: label key %q is not in the segment label allow-list (observation %q); "+
			"the batch was refused before any Arrow record was built",
		e.Key, e.ObservationID)
}

// defaultLabelAllowList is the closed set of dynamic label keys permitted into a segment.
//
// Why a closed literal set rather than a deny-list or a pattern. `store/frostdb.go` materialises
// every label key the caller supplies as an Arrow column `labels.<key>`, so the key space is the
// caller's to choose. A fixed-column privacy audit therefore says nothing about `labels.*`, and a
// claim of "no direct identifiers in the segment" is unfalsifiable beyond whatever fixture the
// auditor happened to write. A deny-list has the same problem one level down: it bounds the keys
// somebody thought of. Only an allow-list makes the claim checkable, because the set of keys that
// can exist is the set of keys written here.
//
// Every entry is infrastructure topology or event classification, chosen so that no KEY names a
// natural person.
//
// The limit of this control, stated plainly: it constrains label KEYS only. Append checks `k` and
// never `v`, so a VALUE remains unconstrained free text. Several keys here routinely carry it —
// `reason` holds strings like `User "alice" cannot get pods`, and `name` can hold an email address.
// So this bounds the shape of the label space, not its contents; free-text values are covered only
// to the extent the description redactor covers them, which is not at all today. Raised by
// adversarial review (SLDP-P3-1, finding F3).
var defaultLabelAllowList = map[string]struct{}{
	// Kubernetes / workload topology
	"api_group":        {},
	"audit_id":         {},
	"delegation_basis": {},
	"env":              {},
	"hour":             {},
	"name":             {},
	"partition":        {},
	"status_code":      {},
	"namespace":        {},
	"pod":              {},
	"container":        {},
	"node":             {},
	"cluster":          {},
	"workload":         {},
	"workload_kind":    {},
	"service":          {},
	"resource":         {},
	"resource_kind":    {},
	"verb":             {},
	"api_version":      {},
	"subresource":      {},
	"decision":         {},
	"response_code":    {},
	"reason":           {},
	"stage":            {},
	"collector":        {},
	"connector":        {},
	"rule_id":          {},
	"rule_version":     {},
	"severity":         {},
	"category":         {},
	"outcome":          {},
	"protocol":         {},
	"direction":        {},
	"port":             {},
	"region":           {},
	"zone":             {},
	"environment":      {},
	"provider":         {},
	"engine":           {},
	"policy":           {},
	"policy_version":   {},
	"quarantine":       {},
	"correlation_id":   {},
	"trust_domain":     {},
	"attestation":      {},
	"signature_algo":   {},
	"schema":           {},

	// stun-sentinel kernel observations (review M4). These are the correlator's wire keys
	// (apps/stun-sentinel/pkg/correlator/ingest.go toIngest); `namespace` and `severity` were
	// already above. Without them a frostdb-tagged signal-ingest refused every sentinel POST.
	// The correlator no longer forwards pod labels, so this is the whole of its key space.
	//
	// syscall, direct_reaction: event classification from closed vocabularies
	// (sys_enter_openat, cgroup_frozen). No person.
	"syscall":         {},
	"direct_reaction": {},
	// pod_name, tenant_id: workload topology, the same class as `pod` and the tenancy every
	// segment is already scoped by. A pod name is chosen by a deployer, not a natural person.
	"pod_name":  {},
	"tenant_id": {},
	// cgroup_path: the kubelet slice of the attributed pod (kubepods-…-pod<uid>.slice). It
	// carries a pod UID, which is topology. The sentinel attributes events to pods only.
	"cgroup_path": {},
	// target: the file the workload opened. ADMITTED WITH A VALUE CONTROL, unlike every other
	// key: a path is named by whoever owns the file system, and one under a home directory names
	// an account (/home/alice/.ssh/id_rsa). The user component is replaced in Append by
	// labelValueRedactors below before any Arrow record is built, so a username never reaches a
	// signed segment. Refusing the key would have cost the one fact the containment evidence
	// needs (which sensitive file was opened); pseudonymising the whole path would have made
	// /etc/passwd and /etc/shadow unreadable to an operator for no privacy gain.
	"target": {},
}

// labelValueRedactors are applied to a label VALUE at the Append chokepoint, for the keys whose
// values can name a person. Keys absent here keep their values verbatim (see the limit stated on
// defaultLabelAllowList). An entry here without a matching allow-list key is dead.
var labelValueRedactors = map[string]func(string) string{
	"target": redactHomeDirectoryUser,
}

// homeDirectoryUser matches the account component of a home directory anywhere in a path, so a
// host-mounted prefix (/host/home/…, /var/home/…) is covered too. `/homework` is not a home root.
var homeDirectoryUser = regexp.MustCompile(`(^|/)(home|Users)/[^/]+`)

// redactHomeDirectoryUser replaces the account name in every home-directory component of p.
func redactHomeDirectoryUser(p string) string {
	return homeDirectoryUser.ReplaceAllString(p, "${1}${2}/[REDACTED_USER]")
}

// redactLabelValue returns the value a segment may hold for key.
func redactLabelValue(key, value string) string {
	if redact, ok := labelValueRedactors[key]; ok {
		return redact(value)
	}
	return value
}

// DefaultLabelAllowList returns a copy of the built-in allow-list.
func DefaultLabelAllowList() map[string]struct{} {
	out := make(map[string]struct{}, len(defaultLabelAllowList))
	for k := range defaultLabelAllowList {
		out[k] = struct{}{}
	}
	return out
}

// DefaultLabelAllowListKeys returns the allow-list as a sorted slice, for evidence and tests.
func DefaultLabelAllowListKeys() []string {
	keys := make([]string, 0, len(defaultLabelAllowList))
	for k := range defaultLabelAllowList {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// IsAllowedLabelKey reports whether a key may be materialised as a segment column under the
// built-in allow-list.
func IsAllowedLabelKey(key string) bool {
	_, ok := defaultLabelAllowList[key]
	return ok
}

// validateLabelAllowList refuses a nil or empty set.
func validateLabelAllowList(set map[string]struct{}) error {
	if len(set) == 0 {
		return ErrLabelAllowListEmpty
	}
	return nil
}
