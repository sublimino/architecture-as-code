package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// AuthorizationChainResponse defines the stable typed response for the
// end-to-end authorization chain query over the resolved identity graph
// and attested evidence.
type AuthorizationChainResponse struct {
	Action            string               `json:"action"`
	AgentIdentity     string               `json:"agentIdentity"`
	ActsOnBehalfOf    string               `json:"actsOnBehalfOf"`
	Principal         string               `json:"principal"`
	Decision          string               `json:"decision"`
	Confidence        float64              `json:"confidence"`
	EvidenceRefs      []string             `json:"evidenceRefs"`
	AttestationGitoid string               `json:"attestationGitoid"`
	Complete          bool                 `json:"complete"`
	ActorID           string               `json:"actorId,omitempty"`
	CanonicalID       string               `json:"canonicalId,omitempty"`
	Aliases           []string             `json:"aliases,omitempty"`
	EvidenceChain     []model.EvidenceLink `json:"evidenceChain,omitempty"`
	Timestamp         *time.Time           `json:"timestamp,omitempty"`
}

// AuthorizationQueryResponse wraps estate-wide authorization chain queries.
type AuthorizationQueryResponse struct {
	Chains        []AuthorizationChainResponse `json:"chains"`
	Total         int                          `json:"total"`
	CompleteCount int                          `json:"complete_count"`
	KPIFraction   float64                      `json:"kpi_fraction"`
}

// handleGetActorAuthorization serves GET /api/v1/actors/{id}/authorization.
func (h *Handlers) handleGetActorAuthorization(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "actor id is required")
		return
	}

	actor := h.Engine.GetActor(id)
	if actor == nil {
		writeError(w, http.StatusNotFound, "actor not found")
		return
	}

	actionHint := r.URL.Query().Get("action")
	chain := h.BuildAuthorizationChain(r.Context(), actor, actionHint)
	writeJSON(w, http.StatusOK, chain)
}

// handleQueryAuthorization serves GET /api/v1/authorization.
func (h *Handlers) handleQueryAuthorization(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// If filtered by actor_id
	if actorID := r.URL.Query().Get("actor_id"); actorID != "" {
		actor := h.Engine.GetActor(actorID)
		if actor == nil {
			writeError(w, http.StatusNotFound, "actor not found")
			return
		}
		actionHint := r.URL.Query().Get("action")
		chain := h.BuildAuthorizationChain(ctx, actor, actionHint)
		writeJSON(w, http.StatusOK, chain)
		return
	}

	// If filtered by action or observation ID
	if action := r.URL.Query().Get("action"); action != "" {
		actors := h.Engine.GetActors()
		for _, a := range actors {
			for _, ev := range a.EvidenceChain {
				if ev.ObservationID == action || strings.Contains(strings.ToLower(ev.Contribution), strings.ToLower(action)) {
					chain := h.BuildAuthorizationChain(ctx, a, action)
					writeJSON(w, http.StatusOK, chain)
					return
				}
			}
		}
		writeError(w, http.StatusNotFound, "action authorization not found")
		return
	}

	// Estate-wide authorization chains query
	actors := h.Engine.GetActors()
	chains := make([]AuthorizationChainResponse, 0, len(actors))
	completeCount := 0

	for _, a := range actors {
		chain := h.BuildAuthorizationChain(ctx, a, "")
		if chain.Complete {
			completeCount++
		}
		chains = append(chains, chain)
	}

	kpiFraction := 0.0
	if len(actors) > 0 {
		kpiFraction = float64(completeCount) / float64(len(actors))
	}

	resp := AuthorizationQueryResponse{
		Chains:        chains,
		Total:         len(actors),
		CompleteCount: completeCount,
		KPIFraction:   kpiFraction,
	}

	writeJSON(w, http.StatusOK, resp)
}

// BuildAuthorizationChain constructs the 7-hop authorization chain for an actor.
func (h *Handlers) BuildAuthorizationChain(ctx context.Context, actor *model.ProvisionalActor, actionHint string) AuthorizationChainResponse {
	if actor == nil {
		return AuthorizationChainResponse{}
	}

	// 1. Agent Identity
	agentIdentity := actor.CanonicalID
	if agentIdentity == "" {
		agentIdentity = actor.ID
	}
	// Prefer SPIFFE ID alias if present
	for _, alias := range actor.Aliases {
		if strings.HasPrefix(alias, "spiffe://") {
			agentIdentity = alias
			break
		}
	}

	// 2. Principal Identity & 3. Acts-On-Behalf-Of Delegation
	principal := actor.PrincipalID
	actsOnBehalfOf := ""

	// Check delegations on actor
	if len(actor.Delegations) > 0 {
		del := actor.Delegations[0]
		if del.To.Value != "" {
			if isSelfIdentity(principal, actor) {
				principal = del.To.Value
			}
			actsOnBehalfOf = fmt.Sprintf("%s acts-on-behalf-of %s", del.From.Value, del.To.Value)
			if del.Provenance.Rule != "" {
				actsOnBehalfOf += fmt.Sprintf(" via %s", del.Provenance.Rule)
			}
		}
	}

	// Check IdentityStore repository if available
	if h.IdentityStore != nil {
		if repo, ok := h.IdentityStore.(identity.Repository); ok {
			now := time.Now().UTC()
			if actor.ResolvedAt != nil && !actor.ResolvedAt.IsZero() {
				now = *actor.ResolvedAt
			}
			delegations, err := repo.GetDelegationsForDelegateAsOf(ctx, actor.ID, now)
			if err == nil && len(delegations) > 0 {
				del := delegations[0]
				if isSelfIdentity(principal, actor) {
					principal = del.PrincipalActorID
				}
				if actsOnBehalfOf == "" {
					actsOnBehalfOf = fmt.Sprintf("%s acts-on-behalf-of %s (authz: %s)", del.DelegateActorID, del.PrincipalActorID, del.AuthzRef)
				}
			}
			// Also check by canonical ID and aliases
			if actsOnBehalfOf == "" || isSelfIdentity(principal, actor) {
				candidates := append([]string{actor.CanonicalID}, actor.Aliases...)
				for _, candidate := range candidates {
					if candidate == "" {
						continue
					}
					aliasDels, err := repo.GetDelegationsForDelegateAsOf(ctx, candidate, now)
					if err == nil && len(aliasDels) > 0 {
						del := aliasDels[0]
						if isSelfIdentity(principal, actor) {
							principal = del.PrincipalActorID
						}
						if actsOnBehalfOf == "" {
							actsOnBehalfOf = fmt.Sprintf("%s acts-on-behalf-of %s (authz: %s)", del.DelegateActorID, del.PrincipalActorID, del.AuthzRef)
						}
						break
					}
				}
			}
		}
	}

	// If actsOnBehalfOf is still empty, derive from principalID or evidence links
	if actsOnBehalfOf == "" && principal != "" && !isSelfIdentity(principal, actor) {
		actsOnBehalfOf = fmt.Sprintf("%s acts-on-behalf-of %s", agentIdentity, principal)
	}

	if actsOnBehalfOf == "" {
		for _, ev := range actor.EvidenceChain {
			if strings.Contains(strings.ToLower(ev.Contribution), "acts-on-behalf-of") || strings.Contains(strings.ToLower(ev.Contribution), "delegation") {
				actsOnBehalfOf = ev.Contribution
				break
			}
		}
	}

	// If principal is still empty or self-identity, check evidence chain contributions and labels
	if isSelfIdentity(principal, actor) {
		for _, key := range actor.CorrelationKeys {
			if strings.HasPrefix(key, "principal:") || (strings.Contains(key, "@") && !isSelfIdentity(key, actor)) {
				principal = strings.TrimPrefix(key, "principal:")
				break
			}
		}
	}

	// Fallback principal derivation from attributes if present
	if isSelfIdentity(principal, actor) && actor.Attributes != nil {
		if p, ok := actor.Attributes["principal_id"]; ok && p != "" && !isSelfIdentity(p, actor) {
			principal = p
		} else if u, ok := actor.Attributes["impersonated_user"]; ok && u != "" && !isSelfIdentity(u, actor) {
			principal = u
		}
	}

	// If principal is empty or matches agent's own identity (self), look for distinct principal in store observations
	if isSelfIdentity(principal, actor) && h.Store != nil && len(actor.EvidenceChain) > 0 {
		obsList, err := h.Store.QueryRange(ctx, store.Query{Limit: 200})
		if err == nil {
			for _, o := range obsList {
				for _, ev := range actor.EvidenceChain {
					if o.ID == ev.ObservationID {
						if o.ImpersonatedUser != "" && !isSelfIdentity(o.ImpersonatedUser, actor) {
							principal = o.ImpersonatedUser
							break
						} else if o.PrincipalID != "" && !isSelfIdentity(o.PrincipalID, actor) {
							principal = o.PrincipalID
							break
						} else if o.Labels != nil && o.Labels["principal"] != "" && !isSelfIdentity(o.Labels["principal"], actor) {
							principal = o.Labels["principal"]
							break
						} else if o.Labels != nil && o.Labels["sa_principal"] != "" && !isSelfIdentity(o.Labels["sa_principal"], actor) {
							principal = o.Labels["sa_principal"]
							break
						}
					}
				}
				if !isSelfIdentity(principal, actor) {
					break
				}
			}
		}
	}

	// If actsOnBehalfOf is still empty and principal is resolved, derive delegation link
	if actsOnBehalfOf == "" && principal != "" {
		actsOnBehalfOf = fmt.Sprintf("%s acts-on-behalf-of %s", agentIdentity, principal)
	}

	// 4. Action
	action := actionHint
	if action == "" {
		if len(actor.EvidenceChain) > 0 {
			lastEv := actor.EvidenceChain[len(actor.EvidenceChain)-1]
			action = lastEv.Contribution
		} else {
			action = fmt.Sprintf("Execution authorization for actor %s", actor.ID)
		}
	}

	// 5. Decision
	decision := string(actor.Status)
	if actor.Status == model.ActorPromoted {
		decision = "authorized:promoted"
	} else if actor.Status == model.ActorActionable {
		decision = "authorized:actionable"
	} else if actor.Status == model.ActorProvisional {
		if actor.Confidence >= 0.7 {
			decision = "authorized:provisional_high_confidence"
		} else {
			decision = "evaluated:provisional"
		}
	}

	// 6. Confidence & Evidence Refs
	confidence := actor.Confidence
	evidenceRefs := make([]string, 0, len(actor.EvidenceChain))
	seenRefs := make(map[string]bool)

	for _, ev := range actor.EvidenceChain {
		if ev.ObservationID != "" && !seenRefs[ev.ObservationID] {
			seenRefs[ev.ObservationID] = true
			evidenceRefs = append(evidenceRefs, ev.ObservationID)
		}
	}

	// Query store observations if available to collect rich raw evidence refs
	if h.Store != nil && len(actor.EvidenceChain) > 0 {
		obsList, err := h.Store.QueryRange(ctx, store.Query{Limit: 200})
		if err == nil {
			for _, o := range obsList {
				for _, ev := range actor.EvidenceChain {
					if o.ID == ev.ObservationID && o.RawEvidenceRef != "" && !seenRefs[o.RawEvidenceRef] {
						seenRefs[o.RawEvidenceRef] = true
						evidenceRefs = append(evidenceRefs, o.RawEvidenceRef)
					}
				}
			}
		}
	}

	// 7. Attestation GitOID
	// Compute or retrieve cryptographic GitOID (SHA256 Git blob hash) over the evidence chain and authorization record.
	attestationGitoid := deriveAttestationGitoid(actor.ID, agentIdentity, principal, decision, confidence, evidenceRefs)

	// Completeness predicate: all 7 hops must be non-empty and confidence > 0.
	complete := agentIdentity != "" &&
		actsOnBehalfOf != "" &&
		principal != "" &&
		decision != "" &&
		confidence > 0 &&
		len(evidenceRefs) > 0 &&
		attestationGitoid != ""

	var ts *time.Time
	if !actor.UpdatedAt.IsZero() {
		t := actor.UpdatedAt
		ts = &t
	} else if !actor.CreatedAt.IsZero() {
		t := actor.CreatedAt
		ts = &t
	}

	return AuthorizationChainResponse{
		Action:            action,
		AgentIdentity:     agentIdentity,
		ActsOnBehalfOf:    actsOnBehalfOf,
		Principal:         principal,
		Decision:          decision,
		Confidence:        confidence,
		EvidenceRefs:      evidenceRefs,
		AttestationGitoid: attestationGitoid,
		Complete:          complete,
		ActorID:           actor.ID,
		CanonicalID:       actor.CanonicalID,
		Aliases:           actor.Aliases,
		EvidenceChain:     actor.EvidenceChain,
		Timestamp:         ts,
	}
}

// deriveAttestationGitoid produces a deterministic GitOID formatted as sha256 blob
// over the authorization chain statement.
func deriveAttestationGitoid(actorID, agentIdentity, principal, decision string, confidence float64, evidenceRefs []string) string {
	payload := fmt.Sprintf("signalloom-attestation/v1\nactor:%s\nagent:%s\nprincipal:%s\ndecision:%s\nconfidence:%.4f\nrefs:%s",
		actorID, agentIdentity, principal, decision, confidence, strings.Join(evidenceRefs, ","))

	// Format as Git blob object: "blob <length>\0<content>"
	blobPrefix := fmt.Sprintf("blob %d\x00", len(payload))
	blob := append([]byte(blobPrefix), []byte(payload)...)
	digest := sha256.Sum256(blob)
	return hex.EncodeToString(digest[:])
}

// isSelfIdentity checks whether an identity string represents the actor itself
// rather than a distinct principal human/authority.
func isSelfIdentity(p string, actor *model.ProvisionalActor) bool {
	if p == "" || p == actor.ID || p == actor.CanonicalID {
		return true
	}
	for _, a := range actor.Aliases {
		if p == a {
			return true
		}
	}
	return false
}
