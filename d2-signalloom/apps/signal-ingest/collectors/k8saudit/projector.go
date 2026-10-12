// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package k8saudit

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// ObservationSource is the stable string every observation from this vertical carries,
// gated on by every rule in policy/bundles/kusari/k8s-audit.yaml
// (obs.source == "k8saudit-kube"). It is distinct from the identity-auth
// projection's "k8s-apiserver-audit" so the two streams never cross a rule.
const ObservationSource = "k8saudit-kube"

// Label keys this projection materialises. The set is the binding "k8s label
// contract" (docs/EAP/policy-detection-coverage-catalogue.md). ProjectedKeys()
// returns it for the coverage gate; every entry must be in the store default
// allow-list or a frostdb-tagged Append refuses the batch.
const (
	LabelVerb         = "verb"
	LabelResource     = "resource"
	LabelSubresource  = "subresource"
	LabelResourceKind = "resource_kind"
	LabelAPIGroup     = "api_group"
	LabelAPIVersion   = "api_version"
	LabelNamespace    = "namespace"
	LabelName         = "name"
	LabelDecision     = "decision"
	LabelResponseCode = "response_code"
	LabelSourceIP     = "source_ip"
	LabelAuditID      = "audit_id"
	LabelStage        = "stage"
	LabelReason       = "reason"
	LabelUserAgent    = "user_agent"
)

// StageResponseComplete is the one stage this vertical treats as authoritative.
// Every rule requires it; the projection emits all stages so the filter is a
// visible, mutation-testable control in the label space rather than an invisible
// drop (see Projector.Project).
const StageResponseComplete = "ResponseComplete"

// ProjectedKeys returns, sorted-stably by declaration, every label key the
// projection can emit. The coverage gate asserts each is allow-listed (L2), and
// store/label_allowlist_k8saudit_test.go holds an independent copy.
func ProjectedKeys() []string {
	return []string{
		LabelVerb, LabelResource, LabelSubresource, LabelResourceKind,
		LabelAPIGroup, LabelAPIVersion, LabelNamespace, LabelName,
		LabelDecision, LabelResponseCode, LabelSourceIP, LabelAuditID,
		LabelStage, LabelReason, LabelUserAgent,
	}
}

// Projector turns kube-apiserver audit events into observations. It holds no
// state, so one instance is safe to share and a nil-receiver call is as valid as
// any other.
type Projector struct{}

// Project maps one AuditEvent to one Observation, or (zero, false) when the
// event carries no usable identity or resource to attribute — a record with
// neither a username nor an objectRef is apiserver noise (a health probe, a
// watch bookmark) and projecting it would be an observation that names nothing.
//
// It projects EVERY stage. ResponseComplete filtering is a RULE concern
// (every k8s-audit.yaml rule gates on stage == "ResponseComplete"), not a
// projection drop: emitting all stages keeps the control in the label space,
// where dropping the rule gate measurably double-counts a single request across
// its RequestReceived / ResponseStarted / ResponseComplete records — the
// mutation the quality bar names. The acting identity (user, or impersonatedUser
// when present) goes to ActorHint, which the store pseudonymises into obs.actor;
// it is NEVER written as a label (binding correction C2).
func (Projector) Project(e AuditEvent, originRef string) (model.Observation, bool) {
	actor := actingIdentity(e)
	hasResource := e.ObjectRef != nil && e.ObjectRef.Resource != ""
	if actor == "" && !hasResource {
		return model.Observation{}, false
	}

	ts := e.StageTimestamp
	if ts.IsZero() {
		ts = e.RequestReceivedTimestamp
	}
	if ts.IsZero() {
		ts = time.Now().UTC()
	}

	auditID := e.AuditID
	if auditID == "" {
		auditID = fmt.Sprintf("k8saudit-%d-%s", ts.UnixNano(), e.Verb)
	}

	// The ref — and so the derived ID — includes the stage, so the four stages of
	// one request are four distinct observations the deduper keeps apart, while a
	// genuine redelivery of the SAME stage is recognised and dropped.
	stage := e.Stage
	if stage == "" {
		stage = "Unknown"
	}
	ref := originRef
	if ref == "" {
		ref = fmt.Sprintf("k8saudit://%s", auditID)
	}
	ref = fmt.Sprintf("%s#%s-%s", ref, auditID, stage)

	labels := map[string]string{
		LabelVerb:         e.Verb,
		LabelStage:        stage,
		LabelAuditID:      auditID,
		LabelDecision:     decisionOf(e),
		LabelResponseCode: responseCodeOf(e),
		LabelUserAgent:    e.UserAgent,
	}

	// api_group is always set: "" is the meaningful value for the core group, not
	// an absence, so a rule can read it without has() ambiguity.
	labels[LabelAPIGroup] = ""
	if e.ObjectRef != nil {
		labels[LabelResource] = e.ObjectRef.Resource
		labels[LabelAPIGroup] = e.ObjectRef.APIGroup
		putIfSet(labels, LabelSubresource, e.ObjectRef.Subresource)
		putIfSet(labels, LabelAPIVersion, e.ObjectRef.APIVersion)
		putIfSet(labels, LabelNamespace, e.ObjectRef.Namespace)
		putIfSet(labels, LabelName, e.ObjectRef.Name)
	}
	if e.RequestObject != nil {
		putIfSet(labels, LabelResourceKind, e.RequestObject.Kind)
	}
	if len(e.SourceIPs) > 0 {
		putIfSet(labels, LabelSourceIP, e.SourceIPs[0])
	}
	if e.ResponseStatus != nil {
		putIfSet(labels, LabelReason, e.ResponseStatus.Reason)
	}

	return model.Observation{
		ID:             derivedObservationID(ref),
		Timestamp:      ts.UTC(),
		Layer:          model.LayerKubernetes,
		Fidelity:       model.FidelityDefinitive, // a signed apiserver audit record is a definitive account of the call
		Source:         ObservationSource,
		Confidence:     1.0,
		ActorHint:      actor,
		RawEvidenceRef: ref,
		Labels:         labels,
		Description:    description(e, actor, labels),
	}, true
}

// actingIdentity is impersonatedUser when present and non-empty, else user.
// The impersonated subject is the principal that actually acted, which is the
// one a detection rule must judge.
func actingIdentity(e AuditEvent) string {
	if e.ImpersonatedUser != nil && e.ImpersonatedUser.Username != "" {
		return e.ImpersonatedUser.Username
	}
	return e.User.Username
}

// decisionOf returns the authorizer verdict: the audit annotation when present,
// else derived from the response code. Always "allow" or "forbid" so a rule can
// compare it without a third value to reason about.
func decisionOf(e AuditEvent) string {
	if e.Annotations != nil {
		if d := e.Annotations[decisionAnnotation]; d == "allow" || d == "forbid" {
			return d
		}
	}
	if e.ResponseStatus != nil && e.ResponseStatus.Code >= 400 {
		return "forbid"
	}
	return "allow"
}

// responseCodeOf is the HTTP status as a string, or "0" when the record carries
// no response (a non-terminal stage).
func responseCodeOf(e AuditEvent) string {
	if e.ResponseStatus == nil {
		return "0"
	}
	return strconv.Itoa(int(e.ResponseStatus.Code))
}

func putIfSet(m map[string]string, k, v string) {
	if v != "" {
		m[k] = v
	}
}

func derivedObservationID(ref string) string {
	sum := sha256.Sum256([]byte(ref))
	return hex.EncodeToString(sum[:])
}

func description(e AuditEvent, actor string, labels map[string]string) string {
	res := labels[LabelResource]
	if sub := labels[LabelSubresource]; sub != "" {
		res = res + "/" + sub
	}
	ns := labels[LabelNamespace]
	if ns == "" {
		ns = "<cluster>"
	}
	return fmt.Sprintf("k8s audit (%s): %s %s in %s by %s [%s]",
		labels[LabelStage], e.Verb, res, ns, actorLabel(actor), labels[LabelDecision])
}

// actorLabel is the actor rendered for the free-text description only. It is the
// cleartext identity; the description is redacted of secrets downstream, and the
// stored column is pseudonymised. It exists so an operator reading a finding can
// see who acted without joining back to the pseudonym table.
func actorLabel(actor string) string {
	if actor == "" {
		return "<anonymous>"
	}
	return actor
}
