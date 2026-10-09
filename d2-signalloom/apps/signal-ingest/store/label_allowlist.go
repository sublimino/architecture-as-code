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
	// SLAWS v2 D3: findings and decisions are observations in this store. These keys are
	// closed policy metadata or sha256-derived identifiers; none names a person.
	// Collector operational records (buffer_eviction, projection_failure) are typed by this key.
	"type": {},
	// actor_pseudonym is the keyed pseudonym of the actor on a stored finding or
	// decision (policy.LabelActor). It is admitted because the v2 schema removed
	// the cleartext actor_hint column and with it the only way warm-up could tell
	// one actor-keyed counter from another after a restart: every window keyed on
	// `actor` collapsed into a single counter.
	//
	// The key is deliberately NOT `actor`, which stays on the forbidden list in
	// segment_schema_v2_test.go. This allow-list bounds KEYS and never VALUES, so
	// admitting `actor` would let any collector ship a cleartext identity under a
	// key that reads as legitimate. `actor_pseudonym` names its own value class:
	// a cleartext value under it is self-evidently wrong rather than plausibly
	// right, and policy is its only writer -- see
	// TestFindingObservation_ActorPseudonymLabelIsAPseudonym, which pins the
	// value shape at the writer, which is the only place a value CAN be checked.
	"actor_pseudonym": {},
	// SLAWS v2 §2.3: the awslogs projection (CloudTrail, IAM, VPC Flow). Keys only; values are
	// AWS-shaped scalars (account id, region, event names, resource type and name, addresses,
	// ports, byte counts). Found missing on kind-osramp: the first fixture observation was refused.
	"aws_account_id": {},
	// actor_account_id is the ACTING principal's AWS account, parsed from
	// userIdentity.arn. It is the same class of value as aws_account_id above --
	// a 12-digit account number, chosen by nobody, naming no natural person -- and
	// it is admitted for a specific reason: obs.actor is a keyed pseudonym by the
	// time a policy rule sees it, so "did this call cross an account boundary"
	// cannot be answered by dissecting the actor any more. This label is how that
	// question survives into a v2 segment and therefore into a replay.
	"actor_account_id":      {},
	"aws_region":            {},
	"event_source":          {},
	"event_name":            {},
	"error_code":            {},
	"resource_type":         {},
	"resource_name":         {},
	"source_ip":             {},
	"dst_ip":                {},
	"dst_port":              {},
	"protocol":              {},
	"bytes":                 {},
	"bundle_id":             {},
	"bundle_version":        {},
	"source_observation_id": {},
	"mode":                  {},
	"window_id":             {},
	"count":                 {},
	"finding_ids":           {},
	// SLAWS review API: a human's verdict on a decision is a policy_review observation
	// (policy/review.go). decision_id is the sha256-derived decision identifier; verdict is a
	// three-value closed vocabulary; reviewer is the authenticated reviewing principal.
	//
	// `note` is the one key here whose value is free text a person types, so it is the one entry
	// that needs the limit on this control stated against it rather than against the list as a
	// whole: Append checks the KEY and never the VALUE, so a reviewer can put anything in a note
	// and it reaches a signed segment verbatim. Three things bound that and none of them is this
	// allow-list — policy.MaxReviewNoteLen caps it at 500 runes, only a principal holding
	// policy:review can write one at all, and the note is attributed to the reviewer who typed
	// it. Refusing the key instead would have cost the only field that says WHY a decision was
	// judged the way it was, which is the whole evidentiary point of recording the judgement.
	"decision_id":    {},
	"verdict":        {},
	"reviewer":       {},
	"note":           {},
	"severity":       {},
	"category":       {},
	"outcome":        {},
	"direction":      {},
	"port":           {},
	"region":         {},
	"zone":           {},
	"environment":    {},
	"provider":       {},
	"engine":         {},
	"policy":         {},
	"policy_version": {},
	"quarantine":     {},
	"correlation_id": {},
	"trust_domain":   {},
	"attestation":    {},
	"signature_algo": {},
	"schema":         {},

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
	// domain: the attributed canonical domain for an egress connect observation (SLWD Phase 2).
	"domain": {},
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

// homeDirectoryUserInText is homeDirectoryUser for free text, where the account name ends at the
// first whitespace rather than at the next path separator.
var homeDirectoryUserInText = regexp.MustCompile(`(^|/)(home|Users)/[^/\s]+`)

// redactHomeDirectoryUserInText applies the same rule to a free-text column (the sentinel's
// description carries its target path).
func redactHomeDirectoryUserInText(text string) string {
	return homeDirectoryUserInText.ReplaceAllString(text, "${1}${2}/[REDACTED_USER]")
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
