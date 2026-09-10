package correlation

import (
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

const (
	DefaultCandidateWindow       = 10 * time.Minute
	DefaultMaxDistinctIdentities = 64
	DefaultMaxMergeDegree        = 16
	DefaultMaxCandidatePairs     = 10000
	DefaultMaxWeakCandidates     = 256
)

// ResolverOptions bound identity bridges, not observations belonging to one
// proven identity. Zero fields receive safe defaults.
type ResolverOptions struct {
	CandidateWindow       time.Duration
	MaxDistinctIdentities int
	MaxMergeDegree        int
	MaxCandidatePairs     int
	MaxWeakCandidates     int
}

func (o ResolverOptions) defaults() ResolverOptions {
	if o.CandidateWindow <= 0 {
		o.CandidateWindow = DefaultCandidateWindow
	}
	if o.MaxDistinctIdentities <= 0 {
		o.MaxDistinctIdentities = DefaultMaxDistinctIdentities
	}
	if o.MaxMergeDegree <= 0 {
		o.MaxMergeDegree = DefaultMaxMergeDegree
	}
	if o.MaxCandidatePairs <= 0 {
		o.MaxCandidatePairs = DefaultMaxCandidatePairs
	}
	if o.MaxWeakCandidates <= 0 {
		o.MaxWeakCandidates = DefaultMaxWeakCandidates
	}
	return o
}

func observationIdentifier(id string) model.TypedIdentifier {
	return model.TypedIdentifier{Issuer: "signal-ingest", Scheme: "observation", Value: id}
}

func typedPrincipal(value, issuer string) model.TypedIdentifier {
	scheme := "principal-id"
	if strings.HasPrefix(value, "system:serviceaccount:") {
		scheme = "kubernetes-service-account"
	}
	return model.TypedIdentifier{Issuer: issuer, Scheme: scheme, Value: value}
}

func typedSPIFFE(value string) (model.TypedIdentifier, bool) {
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "spiffe" || u.Host == "" || u.Path == "" {
		return model.TypedIdentifier{}, false
	}
	return model.TypedIdentifier{Issuer: u.Host, Scheme: "spiffe", Value: value}, true
}

func addIdentifier(dst []model.TypedIdentifier, id model.TypedIdentifier) []model.TypedIdentifier {
	if id.Issuer == "" || id.Scheme == "" || id.Value == "" {
		return dst
	}
	for _, existing := range dst {
		if existing == id {
			return dst
		}
	}
	return append(dst, id)
}

// contractIdentifiers parses source/field shapes emitted by collectors. It
// does not authenticate the producer; Engine gates these values through its
// injected ProducerVerifier before granting merge authority.
func contractIdentifiers(o model.Observation) []model.TypedIdentifier {
	ids := make([]model.TypedIdentifier, 0, 2)
	switch o.Source {
	case "spire-agent":
		if o.Labels["event_type"] != "spire_svid_issuance" {
			break
		}
		if raw := o.Labels["spiffe_id"]; raw != "" && raw == o.ActorHint {
			if id, ok := typedSPIFFE(raw); ok {
				ids = addIdentifier(ids, id)
			}
		}
		if p := o.PrincipalID; p != "" && p == o.Labels["sa_principal"] {
			ids = addIdentifier(ids, typedPrincipal(p, "kubernetes"))
		}
	case "openbao-audit":
		if raw := o.Labels["spiffe_id"]; raw != "" && raw == o.ActorHint {
			if id, ok := typedSPIFFE(raw); ok {
				ids = addIdentifier(ids, id)
			}
		}
		if p := o.PrincipalID; p != "" && p == o.Labels["sa_principal"] {
			ids = addIdentifier(ids, typedPrincipal(p, "kubernetes"))
		}
	case "k8s-apiserver-audit":
		if p := o.PrincipalID; p != "" && p == o.ActorHint {
			if id, ok := typedSPIFFE(p); ok {
				if o.Labels["spiffe_id"] == p {
					ids = addIdentifier(ids, id)
				}
			} else {
				ids = addIdentifier(ids, typedPrincipal(p, "kubernetes"))
			}
		}
	case "gcp-cloud-audit":
		p := o.Labels["principal_email"]
		if p != "" && p != "unknown" && p == o.ActorHint {
			issuer := "gcp:" + o.Labels["project_id"]
			ids = addIdentifier(ids, typedPrincipal(p, issuer))
		}
	}
	sort.Slice(ids, func(i, j int) bool { return identifierLess(ids[i], ids[j]) })
	return ids
}

// identifierLess is the canonical total order: authenticated SPIFFE identity
// precedes generic principal aliases, then issuer/scheme/value breaks ties.
// A local service-account name must never erase a SPIFFE trust-domain boundary.
func identifierLess(a, b model.TypedIdentifier) bool {
	if (a.Scheme == "spiffe") != (b.Scheme == "spiffe") {
		return a.Scheme == "spiffe"
	}
	return a.String() < b.String()
}

func identifiersIntersect(a, b []model.TypedIdentifier) bool {
	for _, x := range a {
		for _, y := range b {
			if x == y {
				return true
			}
		}
	}
	return false
}

func commonIdentifier(a, b []model.TypedIdentifier) (model.TypedIdentifier, bool) {
	for _, x := range a {
		for _, y := range b {
			if x == y {
				return x, true
			}
		}
	}
	return model.TypedIdentifier{}, false
}

func hintsConflict(a, b model.Observation) bool {
	return a.ActorHint != "" && b.ActorHint != "" && a.ActorHint != b.ActorHint
}

func edgeID(typ model.EdgeType, a, b, detail string) string {
	if typ != model.EdgeActsOnBehalfOf && b < a {
		a, b = b, a
	}
	return string(typ) + "|" + a + "|" + b + "|" + detail
}

func makeEdge(typ model.EdgeType, fidelity model.EdgeFidelity, a, b model.Observation, source, field, rule, reason string, authenticated, accepted bool) model.CorrelationEdge {
	from, to := observationIdentifier(a.ID), observationIdentifier(b.ID)
	return model.CorrelationEdge{ID: edgeID(typ, a.ID, b.ID, field+"|"+rule), Type: typ, Fidelity: fidelity, From: from, To: to,
		FromObservation: a.ID, ToObservation: b.ID, Directed: typ == model.EdgeActsOnBehalfOf,
		Provenance: model.EdgeProvenance{ObservationIDs: []string{a.ID, b.ID}, Source: source, Field: field, Rule: rule,
			Authenticated: authenticated, Accepted: accepted, Reason: reason, Timestamp: maxTime(a.Timestamp, b.Timestamp)}}
}

func maxTime(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

type disjointSet struct {
	parent, size []int
	ids          []map[string]struct{}
	hints        []map[string]struct{}
	degree       []int
}

func newDisjointSet(obs []model.Observation, verified [][]model.TypedIdentifier) *disjointSet {
	d := &disjointSet{parent: make([]int, len(obs)), size: make([]int, len(obs)), ids: make([]map[string]struct{}, len(obs)), hints: make([]map[string]struct{}, len(obs)), degree: make([]int, len(obs))}
	for i, o := range obs {
		d.parent[i] = i
		d.size[i] = 1
		d.ids[i] = map[string]struct{}{}
		d.hints[i] = map[string]struct{}{}
		for _, id := range verified[i] {
			d.ids[i][id.String()] = struct{}{}
		}
		if o.ActorHint != "" {
			d.hints[i][o.ActorHint] = struct{}{}
		}
	}
	return d
}
func (d *disjointSet) find(x int) int {
	for d.parent[x] != x {
		d.parent[x] = d.parent[d.parent[x]]
		x = d.parent[x]
	}
	return x
}
func disjointStrings(a, b map[string]struct{}) bool {
	if len(a) == 0 || len(b) == 0 {
		return false
	}
	for v := range a {
		if _, ok := b[v]; ok {
			return false
		}
	}
	return true
}
func equalStringSets(a, b map[string]struct{}) bool {
	if len(a) != len(b) {
		return false
	}
	for value := range a {
		if _, ok := b[value]; !ok {
			return false
		}
	}
	return true
}
func (d *disjointSet) union(a, b, maxIDs, maxDegree int, cannot map[[2]int]struct{}) (bool, string) {
	ra, rb := d.find(a), d.find(b)
	if ra == rb {
		return true, "already connected"
	}
	for pair := range cannot {
		x, y := d.find(pair[0]), d.find(pair[1])
		if (x == ra && y == rb) || (x == rb && y == ra) {
			return false, "cannot-link conflict"
		}
	}
	if len(d.hints[ra]) > 0 && len(d.hints[rb]) > 0 && !equalStringSets(d.hints[ra], d.hints[rb]) {
		return false, "conflicting actor hints"
	}
	mergedIDs := len(d.ids[ra])
	for id := range d.ids[rb] {
		if _, ok := d.ids[ra][id]; !ok {
			mergedIDs++
		}
	}
	if mergedIDs > maxIDs {
		return false, "distinct identity cap"
	}
	bridge := mergedIDs > len(d.ids[ra]) && mergedIDs > len(d.ids[rb])
	combinedDegree := d.degree[ra] + d.degree[rb]
	if bridge {
		combinedDegree++
	}
	if combinedDegree > maxDegree {
		return false, "merge degree cap"
	}
	if d.size[ra] < d.size[rb] {
		ra, rb = rb, ra
	}
	d.parent[rb] = ra
	d.size[ra] += d.size[rb]
	for id := range d.ids[rb] {
		d.ids[ra][id] = struct{}{}
	}
	for h := range d.hints[rb] {
		d.hints[ra][h] = struct{}{}
	}
	d.degree[ra] = combinedDegree
	return true, "accepted deterministic identity"
}

func cloneEdge(e model.CorrelationEdge) model.CorrelationEdge {
	e.Provenance.ObservationIDs = append([]string(nil), e.Provenance.ObservationIDs...)
	return e
}
func cloneActor(a *model.ProvisionalActor) *model.ProvisionalActor {
	if a == nil {
		return nil
	}
	c := *a
	c.EvidenceChain = append([]model.EvidenceLink(nil), a.EvidenceChain...)
	c.CorrelationKeys = append([]string(nil), a.CorrelationKeys...)
	c.Aliases = append([]string(nil), a.Aliases...)
	if a.Attributes != nil {
		c.Attributes = make(map[string]string, len(a.Attributes))
		for k, v := range a.Attributes {
			c.Attributes[k] = v
		}
	}
	c.AcceptedEdges = append([]model.CorrelationEdge(nil), a.AcceptedEdges...)
	for i := range c.AcceptedEdges {
		c.AcceptedEdges[i] = cloneEdge(c.AcceptedEdges[i])
	}
	c.DeclinedEdges = append([]model.CorrelationEdge(nil), a.DeclinedEdges...)
	for i := range c.DeclinedEdges {
		c.DeclinedEdges[i] = cloneEdge(c.DeclinedEdges[i])
	}
	c.Delegations = append([]model.CorrelationEdge(nil), a.Delegations...)
	for i := range c.Delegations {
		c.Delegations[i] = cloneEdge(c.Delegations[i])
	}
	c.Lineage = append([]model.ActorLineage(nil), a.Lineage...)
	if a.PromotedAt != nil {
		v := *a.PromotedAt
		c.PromotedAt = &v
	}
	if a.ResolvedAt != nil {
		v := *a.ResolvedAt
		c.ResolvedAt = &v
	}
	if a.AgentRegistryID != nil {
		v := *a.AgentRegistryID
		c.AgentRegistryID = &v
	}
	if a.QuarantineDetails != nil {
		v := *a.QuarantineDetails
		c.QuarantineDetails = &v
	}
	return &c
}
func cloneSnapshot(s model.ResolverSnapshot) model.ResolverSnapshot {
	c := s
	c.Actors = make([]*model.ProvisionalActor, len(s.Actors))
	for i, a := range s.Actors {
		c.Actors[i] = cloneActor(a)
	}
	c.AcceptedEdges = append([]model.CorrelationEdge(nil), s.AcceptedEdges...)
	for i := range c.AcceptedEdges {
		c.AcceptedEdges[i] = cloneEdge(c.AcceptedEdges[i])
	}
	c.DeclinedEdges = append([]model.CorrelationEdge(nil), s.DeclinedEdges...)
	for i := range c.DeclinedEdges {
		c.DeclinedEdges[i] = cloneEdge(c.DeclinedEdges[i])
	}
	c.Delegations = append([]model.CorrelationEdge(nil), s.Delegations...)
	for i := range c.Delegations {
		c.Delegations[i] = cloneEdge(c.Delegations[i])
	}
	c.Lineage = append([]model.ActorLineage(nil), s.Lineage...)
	return c
}

func representative(component []int, observations []model.Observation, verified [][]model.TypedIdentifier) model.TypedIdentifier {
	ids := make([]model.TypedIdentifier, 0)
	for _, i := range component {
		for _, id := range verified[i] {
			ids = addIdentifier(ids, id)
		}
	}
	if len(ids) == 0 {
		for _, i := range component {
			ids = addIdentifier(ids, observationIdentifier(observations[i].ID))
		}
	}
	sort.Slice(ids, func(i, j int) bool { return identifierLess(ids[i], ids[j]) })
	return ids[0]
}

func attachEdge(actor *model.ProvisionalActor, e model.CorrelationEdge, declined bool) {
	if declined {
		actor.DeclinedEdges = append(actor.DeclinedEdges, e)
	} else if e.Type == model.EdgeActsOnBehalfOf {
		actor.Delegations = append(actor.Delegations, e)
	} else {
		actor.AcceptedEdges = append(actor.AcceptedEdges, e)
	}
}

func deriveLineage(previous model.ResolverSnapshot, actors []*model.ProvisionalActor) []model.ActorLineage {
	oldMembers := map[string]map[string]struct{}{}
	for _, a := range previous.Actors {
		m := map[string]struct{}{}
		for _, ev := range a.EvidenceChain {
			m[ev.ObservationID] = struct{}{}
		}
		oldMembers[a.ID] = m
	}
	overlaps := map[string][]string{}
	for old, m := range oldMembers {
		for _, a := range actors {
			for _, ev := range a.EvidenceChain {
				if _, ok := m[ev.ObservationID]; ok {
					overlaps[old] = append(overlaps[old], a.ID)
					break
				}
			}
		}
	}
	var out []model.ActorLineage
	for old, news := range overlaps {
		sort.Strings(news)
		for _, next := range news {
			out = append(out, model.ActorLineage{OldCanonicalID: old, NewCanonicalID: next, Split: len(news) > 1, Reason: "deterministic epoch rebuild"})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].OldCanonicalID == out[j].OldCanonicalID {
			return out[i].NewCanonicalID < out[j].NewCanonicalID
		}
		return out[i].OldCanonicalID < out[j].OldCanonicalID
	})
	return out
}

func validateEdge(e model.CorrelationEdge) error {
	if !e.Type.IsValid() {
		return fmt.Errorf("unknown correlation edge type %q", e.Type)
	}
	return nil
}
