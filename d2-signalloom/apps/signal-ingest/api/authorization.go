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
	Action            string                      `json:"action"`
	AgentIdentity     string                      `json:"agentIdentity"`
	ActsOnBehalfOf    string                      `json:"actsOnBehalfOf"`
	Principal         string                      `json:"principal"`
	Decision          string                      `json:"decision"`
	Confidence        float64                     `json:"confidence"`
	EvidenceRefs      []string                    `json:"evidenceRefs"`
	AttestationGitoid string                      `json:"attestationGitoid"`
	Complete          bool                        `json:"complete"`
	ActorID           string                      `json:"actorId,omitempty"`
	CanonicalID       string                      `json:"canonicalId,omitempty"`
	Aliases           []string                    `json:"aliases,omitempty"`
	EvidenceChain     []model.EvidenceLink        `json:"evidenceChain,omitempty"`
	DelegationChain   []identity.DelegationRecord `json:"delegationChain,omitempty"`
	CycleDetected     bool                        `json:"cycleDetected,omitempty"`
	Timestamp         *time.Time                  `json:"timestamp,omitempty"`
	Status            model.ActorStatus           `json:"status,omitempty"`
	QuarantineDetails *model.QuarantineRecord     `json:"quarantine_details,omitempty"`
	ViolationReason   string                      `json:"violation_reason,omitempty"`
	Error             string                      `json:"error,omitempty"`
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

	queryTime := time.Now().UTC()
	if asOfStr := r.URL.Query().Get("as_of"); asOfStr != "" {
		if t, err := time.Parse(time.RFC3339, asOfStr); err == nil {
			queryTime = t.UTC()
		} else if t, err := time.Parse(time.RFC3339Nano, asOfStr); err == nil {
			queryTime = t.UTC()
		}
	} else if asOfStr := r.URL.Query().Get("asOf"); asOfStr != "" {
		if t, err := time.Parse(time.RFC3339, asOfStr); err == nil {
			queryTime = t.UTC()
		} else if t, err := time.Parse(time.RFC3339Nano, asOfStr); err == nil {
			queryTime = t.UTC()
		}
	}

	actor := h.Engine.GetActor(id)
	if actor == nil {
		if repo := h.resolveRepository(); repo != nil {
			if snap, err := repo.GetActiveGraphForActorAsOf(r.Context(), id, queryTime); err == nil && snap != nil {
				actor = &model.ProvisionalActor{
					ID:         snap.Actor.ActorID,
					Status:     snap.Actor.Status,
					Confidence: 0.85,
					CreatedAt:  snap.Actor.CreatedAt,
					UpdatedAt:  snap.Actor.UpdatedAt,
					ResolvedAt: &queryTime,
				}
				for _, al := range snap.Aliases {
					actor.Aliases = append(actor.Aliases, al.AliasValue)
				}
				for _, d := range snap.DelegationsAsDelegate {
					actor.Delegations = append(actor.Delegations, model.CorrelationEdge{
						ID:       fmt.Sprintf("del-%d", d.ID),
						Type:     model.EdgeActsOnBehalfOf,
						Fidelity: model.FidelityDefinitive,
						From:     model.TypedIdentifier{Scheme: "actor", Value: d.DelegateActorID},
						To:       model.TypedIdentifier{Scheme: "actor", Value: d.PrincipalActorID},
						Provenance: model.EdgeProvenance{
							Source:        "identity_graph",
							Rule:          "delegation_claim",
							Authenticated: true,
							Accepted:      true,
							Timestamp:     d.ValidFrom,
						},
					})
				}
			} else if act, err := repo.GetActor(r.Context(), id); err == nil && act != nil {
				actor = &model.ProvisionalActor{
					ID:         act.ActorID,
					Status:     act.Status,
					Confidence: 0.85,
					CreatedAt:  act.CreatedAt,
					UpdatedAt:  act.UpdatedAt,
					ResolvedAt: &queryTime,
				}
			}
		}
	} else {
		cloned := *actor
		cloned.ResolvedAt = &queryTime
		actor = &cloned
	}
	if actor == nil && h.Engine != nil {
		if qRec, isQ := h.Engine.IsActorQuarantined(id); isQ {
			actor = &model.ProvisionalActor{
				ID:                id,
				Status:            model.ActorQuarantined,
				QuarantineDetails: qRec,
				CreatedAt:         qRec.AttemptedAt,
				UpdatedAt:         qRec.QuarantinedAt,
			}
		}
	}
	if actor == nil {
		writeError(w, http.StatusNotFound, "actor not found")
		return
	}

	actionHint := r.URL.Query().Get("action")
	chain := h.BuildAuthorizationChain(r.Context(), actor, actionHint)
	if chain.Decision == "REVOKED" || strings.HasPrefix(chain.Decision, "REVOKED") || actor.Status == "revoked" {
		w.Header().Set("X-Authorization-Status", "REVOKED")
		writeJSON(w, http.StatusForbidden, chain)
		return
	}
	if actor.Status == model.ActorQuarantined || chain.QuarantineDetails != nil {
		chain.Error = fmt.Sprintf("actor execution quarantined: unverified delegation chain (%s)", chain.ViolationReason)
		writeJSON(w, http.StatusForbidden, chain)
		return
	}
	writeJSON(w, http.StatusOK, chain)
}

// handleQueryAuthorization serves GET /api/v1/authorization.
func (h *Handlers) handleQueryAuthorization(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	queryTime := time.Now().UTC()
	if asOfStr := r.URL.Query().Get("as_of"); asOfStr != "" {
		if t, err := time.Parse(time.RFC3339, asOfStr); err == nil {
			queryTime = t.UTC()
		} else if t, err := time.Parse(time.RFC3339Nano, asOfStr); err == nil {
			queryTime = t.UTC()
		}
	} else if asOfStr := r.URL.Query().Get("asOf"); asOfStr != "" {
		if t, err := time.Parse(time.RFC3339, asOfStr); err == nil {
			queryTime = t.UTC()
		} else if t, err := time.Parse(time.RFC3339Nano, asOfStr); err == nil {
			queryTime = t.UTC()
		}
	}

	// If filtered by actor_id
	if actorID := r.URL.Query().Get("actor_id"); actorID != "" {
		actor := h.Engine.GetActor(actorID)
		if actor == nil {
			if repo := h.resolveRepository(); repo != nil {
				if snap, err := repo.GetActiveGraphForActorAsOf(ctx, actorID, queryTime); err == nil && snap != nil {
					actor = &model.ProvisionalActor{
						ID:         snap.Actor.ActorID,
						Status:     snap.Actor.Status,
						Confidence: 0.85,
						CreatedAt:  snap.Actor.CreatedAt,
						UpdatedAt:  snap.Actor.UpdatedAt,
						ResolvedAt: &queryTime,
					}
					for _, al := range snap.Aliases {
						actor.Aliases = append(actor.Aliases, al.AliasValue)
					}
					for _, d := range snap.DelegationsAsDelegate {
						actor.Delegations = append(actor.Delegations, model.CorrelationEdge{
							ID:       fmt.Sprintf("del-%d", d.ID),
							Type:     model.EdgeActsOnBehalfOf,
							Fidelity: model.FidelityDefinitive,
							From:     model.TypedIdentifier{Scheme: "actor", Value: d.DelegateActorID},
							To:       model.TypedIdentifier{Scheme: "actor", Value: d.PrincipalActorID},
							Provenance: model.EdgeProvenance{
								Source:        "identity_graph",
								Rule:          "delegation_claim",
								Authenticated: true,
								Accepted:      true,
								Timestamp:     d.ValidFrom,
							},
						})
					}
				} else if act, err := repo.GetActor(ctx, actorID); err == nil && act != nil {
					actor = &model.ProvisionalActor{
						ID:         act.ActorID,
						Status:     act.Status,
						Confidence: 0.85,
						CreatedAt:  act.CreatedAt,
						UpdatedAt:  act.UpdatedAt,
						ResolvedAt: &queryTime,
					}
				}
			}
		} else {
			cloned := *actor
			cloned.ResolvedAt = &queryTime
			actor = &cloned
		}
		if actor == nil && h.Engine != nil {
			if qRec, isQ := h.Engine.IsActorQuarantined(actorID); isQ {
				actor = &model.ProvisionalActor{
					ID:                actorID,
					Status:            model.ActorQuarantined,
					QuarantineDetails: qRec,
					CreatedAt:         qRec.AttemptedAt,
					UpdatedAt:         qRec.QuarantinedAt,
				}
			}
		}
		if actor == nil {
			writeError(w, http.StatusNotFound, "actor not found")
			return
		}
		actionHint := r.URL.Query().Get("action")
		chain := h.BuildAuthorizationChain(ctx, actor, actionHint)
		if chain.Decision == "REVOKED" || strings.HasPrefix(chain.Decision, "REVOKED") || actor.Status == "revoked" {
			w.Header().Set("X-Authorization-Status", "REVOKED")
			writeJSON(w, http.StatusForbidden, chain)
			return
		}
		if actor.Status == model.ActorQuarantined || chain.QuarantineDetails != nil {
			chain.Error = fmt.Sprintf("actor execution quarantined: unverified delegation chain (%s)", chain.ViolationReason)
			writeJSON(w, http.StatusForbidden, chain)
			return
		}
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
					if a.Status == model.ActorQuarantined || chain.QuarantineDetails != nil {
						chain.Error = fmt.Sprintf("actor execution quarantined: unverified delegation chain (%s)", chain.ViolationReason)
						writeJSON(w, http.StatusForbidden, chain)
						return
					}
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
	seenActorIDs := make(map[string]bool)
	for _, a := range actors {
		seenActorIDs[a.ID] = true
	}
	if h.Engine != nil {
		for qActorID, qRec := range h.Engine.GetQuarantinedActors() {
			if !seenActorIDs[qActorID] {
				actors = append(actors, &model.ProvisionalActor{
					ID:                qActorID,
					Status:            model.ActorQuarantined,
					QuarantineDetails: qRec,
					CreatedAt:         qRec.AttemptedAt,
					UpdatedAt:         qRec.QuarantinedAt,
				})
				seenActorIDs[qActorID] = true
			}
		}
	}
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

	if repo := h.resolveRepository(); repo != nil {
		if actRec, err := repo.GetActor(ctx, actor.ID); err == nil && actRec != nil {
			if actRec.Status == "revoked" || actRec.Status == model.ActorRevoked {
				actor.Status = model.ActorRevoked
			}
		}
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
	var delegationChain []identity.DelegationRecord
	cycleDetected := false

	if repo := h.resolveRepository(); repo != nil {
			now := time.Now().UTC()
			if actor.ResolvedAt != nil && !actor.ResolvedAt.IsZero() {
				now = *actor.ResolvedAt
			}
			dels, isCycle, err := repo.FindTransitiveDelegations(ctx, actor.ID, now, 8)
			if err == nil && len(dels) > 0 {
				delegationChain = dels
				cycleDetected = isCycle
				terminalPrincipal := dels[len(dels)-1].PrincipalActorID
				if isSelfIdentity(principal, actor) || len(dels) > 1 {
					principal = terminalPrincipal
				}
				if actsOnBehalfOf == "" {
					if len(dels) == 1 {
						actsOnBehalfOf = fmt.Sprintf("%s acts-on-behalf-of %s (authz: %s)", dels[0].DelegateActorID, dels[0].PrincipalActorID, dels[0].AuthzRef)
					} else {
						var hops []string
						for _, d := range dels {
							hops = append(hops, fmt.Sprintf("%s -> %s", d.DelegateActorID, d.PrincipalActorID))
						}
						actsOnBehalfOf = fmt.Sprintf("%s acts-on-behalf-of %s via chain [%s]", agentIdentity, terminalPrincipal, strings.Join(hops, ", "))
					}
				}
			}
			// Also check by canonical ID and aliases
			if actsOnBehalfOf == "" || isSelfIdentity(principal, actor) {
				candidates := append([]string{actor.CanonicalID}, actor.Aliases...)
				for _, candidate := range candidates {
					if candidate == "" {
						continue
					}
					aliasDels, isCycle, err := repo.FindTransitiveDelegations(ctx, candidate, now, 8)
					if err == nil && len(aliasDels) > 0 {
						delegationChain = aliasDels
						cycleDetected = isCycle
						terminalPrincipal := aliasDels[len(aliasDels)-1].PrincipalActorID
						if isSelfIdentity(principal, actor) || len(aliasDels) > 1 {
							principal = terminalPrincipal
						}
						if actsOnBehalfOf == "" {
							if len(aliasDels) == 1 {
								actsOnBehalfOf = fmt.Sprintf("%s acts-on-behalf-of %s (authz: %s)", aliasDels[0].DelegateActorID, aliasDels[0].PrincipalActorID, aliasDels[0].AuthzRef)
							} else {
								var hops []string
								for _, d := range aliasDels {
									hops = append(hops, fmt.Sprintf("%s -> %s", d.DelegateActorID, d.PrincipalActorID))
								}
								actsOnBehalfOf = fmt.Sprintf("%s acts-on-behalf-of %s via chain [%s]", agentIdentity, terminalPrincipal, strings.Join(hops, ", "))
							}
						}
						break
					}
				}
			}

			// If no active delegations found at 'now', check if actor or its aliases had delegations that were revoked
			if len(delegationChain) == 0 && actor.Status != "revoked" {
				candidates := append([]string{actor.ID, actor.CanonicalID}, actor.Aliases...)
				for _, cand := range candidates {
					if cand == "" {
						continue
					}
					if actRec, err := repo.GetActor(ctx, cand); err == nil && actRec != nil && (actRec.Status == "revoked" || actRec.Status == model.ActorRevoked) {
						actor.Status = "revoked"
						break
					}
					if pastDels, err := repo.GetDelegationsForDelegateAsOf(ctx, cand, now.Add(-24*time.Hour)); err == nil && len(pastDels) > 0 {
						actor.Status = "revoked"
						break
					}
				}
			}
		}

	// If actsOnBehalfOf is still empty and not revoked, derive from principalID or evidence links
	if actor.Status == "revoked" || actor.Status == model.ActorRevoked {
		actsOnBehalfOf = fmt.Sprintf("%s delegation revoked (valid_to clamped)", agentIdentity)
	} else if actsOnBehalfOf == "" && principal != "" && !isSelfIdentity(principal, actor) {
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

	// 5. Decision & Quarantine evaluation
	var qRec *model.QuarantineRecord
	if actor.QuarantineDetails != nil {
		qRec = actor.QuarantineDetails
	} else if h.Engine != nil {
		if q, isQ := h.Engine.IsActorQuarantined(actor.ID); isQ {
			qRec = q
		} else if q, isQ := h.Engine.IsActorQuarantined(actor.CanonicalID); isQ {
			qRec = q
		} else {
			for _, al := range actor.Aliases {
				if q, isQ := h.Engine.IsActorQuarantined(al); isQ {
					qRec = q
					break
				}
			}
		}
	}

	decision := string(actor.Status)
	if qRec != nil || actor.Status == model.ActorQuarantined {
		decision = "denied:quarantined"
	} else if actor.Status == "revoked" || actor.Status == model.ActorRevoked {
		decision = "REVOKED"
		if actsOnBehalfOf == "" || strings.HasSuffix(actsOnBehalfOf, principal) {
			actsOnBehalfOf = fmt.Sprintf("%s delegation revoked (valid_to clamped)", agentIdentity)
		}
	} else if actor.Status == model.ActorPromoted {
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

	// Completeness predicate: all 7 hops must be non-empty, authorized, and confidence > 0.
	complete := (decision != "REVOKED" && !strings.HasPrefix(decision, "REVOKED")) &&
		decision != "denied:quarantined" &&
		qRec == nil &&
		actor.Status != model.ActorQuarantined &&
		agentIdentity != "" &&
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

	vReason := ""
	if qRec != nil {
		vReason = string(qRec.ViolationReason)
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
		DelegationChain:   delegationChain,
		CycleDetected:     cycleDetected,
		Timestamp:         ts,
		Status:            actor.Status,
		QuarantineDetails: qRec,
		ViolationReason:   vReason,
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
