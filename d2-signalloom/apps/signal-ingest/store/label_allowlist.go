// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build frostdb

package store

import (
	"errors"
	"fmt"
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
// Every entry is infrastructure topology or event classification. Nothing here identifies a natural
// person, and nothing here is free text — the values are drawn from bounded vocabularies produced
// by the collectors themselves.
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
