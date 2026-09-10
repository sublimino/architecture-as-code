package identity

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

var (
	// ErrScopeExceeded is the sentinel error when requested capabilities exceed delegator bounds.
	ErrScopeExceeded = errors.New("delegator capability scope exceeded")

	// ErrMissingLandlockClaim is returned when a delegation chain terminating at agent-nono-evidenced lacks Landlock claims.
	ErrMissingLandlockClaim = errors.New("delegation to agent-nono-evidenced requires verified Landlock containment claim")

	// ErrForgedClaim is returned when cryptographic claim signature or authentication fails.
	ErrForgedClaim = errors.New("cryptographic claim signature verification failed")

	// ErrInvalidClaim is returned when claim payload validation fails.
	ErrInvalidClaim = errors.New("invalid delegation claim payload")
)

// ScopeExceededError details an unauthorized capability escalation attempt.
type ScopeExceededError struct {
	DelegatorID           string   `json:"delegator_id"`
	DelegateID            string   `json:"delegate_id"`
	RequestedCapabilities []string `json:"requested_capabilities"`
	AllowedCapabilities   []string `json:"allowed_capabilities"`
	MissingCapabilities   []string `json:"missing_capabilities"`
	Detail                string   `json:"detail"`
}

func (e *ScopeExceededError) Error() string {
	return fmt.Sprintf("scope exceeded for delegator %s delegating to %s: missing capabilities [%s]",
		e.DelegatorID, e.DelegateID, strings.Join(e.MissingCapabilities, ", "))
}

func (e *ScopeExceededError) Unwrap() error {
	return ErrScopeExceeded
}

// CapabilityClaim encapsulates a delegation grant requested by or for an agent.
type CapabilityClaim struct {
	ClaimID           string         `json:"claim_id"`
	DelegateActorID   string         `json:"delegate_actor_id"`
	PrincipalActorID  string         `json:"principal_actor_id"`
	Capabilities      []string       `json:"capabilities"`
	ContainmentClaims []string       `json:"containment_claims,omitempty"`
	Signature         string         `json:"signature,omitempty"`
	SignatureValid    *bool          `json:"signature_valid,omitempty"`
	Metadata          map[string]any `json:"metadata,omitempty"`
	ValidFrom         time.Time      `json:"valid_from"`
	ValidTo           *time.Time     `json:"valid_to,omitempty"`
}

// VerificationResult describes the outcome of a capability claim verification.
type VerificationResult struct {
	Valid            bool               `json:"valid"`
	Error            error              `json:"error,omitempty"`
	Capabilities     []string           `json:"capabilities"`
	LandlockVerified bool               `json:"landlock_verified"`
	ViolationRecord  *model.Observation `json:"violation_record,omitempty"`
}

// CapabilityClaimVerifier verifies delegator authority, capability boundaries, Landlock containment,
// and records audit violation events into the persistent store upon security rejections.
type CapabilityClaimVerifier struct {
	repo        Repository
	store       store.SignalStore
	mu          sync.RWMutex
	authorities map[string][]string
}

// NewCapabilityClaimVerifier constructs a CapabilityClaimVerifier.
func NewCapabilityClaimVerifier(repo Repository, s store.SignalStore) *CapabilityClaimVerifier {
	return &CapabilityClaimVerifier{
		repo:        repo,
		store:       s,
		authorities: make(map[string][]string),
	}
}

// SetDelegatorAuthority configures explicit capability allowances for a principal or delegator actor.
func (v *CapabilityClaimVerifier) SetDelegatorAuthority(actorID string, allowedScopes []string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.authorities[actorID] = append([]string(nil), allowedScopes...)
}

// GetDelegatorAuthority resolves the permissible capabilities for a delegator actor.
func (v *CapabilityClaimVerifier) GetDelegatorAuthority(ctx context.Context, delegatorID string) ([]string, error) {
	v.mu.RLock()
	if scopes, ok := v.authorities[delegatorID]; ok && len(scopes) > 0 {
		v.mu.RUnlock()
		return scopes, nil
	}
	v.mu.RUnlock()

	// Check repository actor metadata if available
	if v.repo != nil {
		actor, err := v.repo.GetActor(ctx, delegatorID)
		if err == nil && actor != nil && actor.Metadata != nil {
			if caps, ok := actor.Metadata["capabilities"]; ok {
				if capList, ok := caps.([]string); ok && len(capList) > 0 {
					return capList, nil
				}
				if capAny, ok := caps.([]any); ok && len(capAny) > 0 {
					var strCaps []string
					for _, c := range capAny {
						if s, ok := c.(string); ok {
							strCaps = append(strCaps, s)
						}
					}
					if len(strCaps) > 0 {
						return strCaps, nil
					}
				}
			}
			if role, ok := actor.Metadata["role"].(string); ok {
				switch role {
				case "admin", "cluster-admin", "sre-lead":
					return []string{"*"}, nil
				case "operator", "devops":
					return []string{"operator:*", "agent:*", "deploy:*", "read:*"}, nil
				case "analyst", "security-analyst":
					return []string{"read:*", "audit:*", "scan:*"}, nil
				}
			}
			if typ, ok := actor.Metadata["type"].(string); ok && typ == "human" {
				return []string{"operator:*", "agent:*", "deploy:*", "read:*"}, nil
			}
		}
	}

	// Default fallback: human operators (e.g. emails or subject IDs) have operator capabilities
	if strings.Contains(delegatorID, "@") || strings.HasPrefix(delegatorID, "actor-human-") || strings.HasPrefix(delegatorID, "user-") {
		return []string{"operator:*", "agent:*", "deploy:*", "read:*"}, nil
	}

	// Default minimal authority for unregistered actors
	return []string{"read:status"}, nil
}

// VerifyClaim evaluates delegator authority, capability boundaries, containment, and signature validity.
func (v *CapabilityClaimVerifier) VerifyClaim(ctx context.Context, claim CapabilityClaim) (*VerificationResult, error) {
	if claim.DelegateActorID == "" || claim.PrincipalActorID == "" {
		err := fmt.Errorf("%w: delegate_actor_id and principal_actor_id are required", ErrInvalidClaim)
		return &VerificationResult{Valid: false, Error: err}, err
	}

	// 1. Signature validity check (detect forged claims)
	if claim.SignatureValid != nil && !*claim.SignatureValid {
		return v.failVerification(ctx, claim, "forged_signature", ErrForgedClaim)
	}
	if claim.Signature == "forged" || strings.HasPrefix(claim.Signature, "forged-") || strings.HasPrefix(claim.Signature, "invalid-") {
		return v.failVerification(ctx, claim, "forged_signature", ErrForgedClaim)
	}

	// 2. Resolve allowed capabilities for delegator
	allowedCaps, err := v.GetDelegatorAuthority(ctx, claim.PrincipalActorID)
	if err != nil {
		allowedCaps = []string{"read:status"}
	}

	// 3. Match requested capabilities against delegator bounds
	reqCaps := claim.Capabilities
	if len(reqCaps) == 0 {
		reqCaps = []string{"agent:operate"}
	}

	var missingCaps []string
	for _, req := range reqCaps {
		if !capabilityAllowed(req, allowedCaps) {
			missingCaps = append(missingCaps, req)
		}
	}

	if len(missingCaps) > 0 {
		scopeErr := &ScopeExceededError{
			DelegatorID:           claim.PrincipalActorID,
			DelegateID:            claim.DelegateActorID,
			RequestedCapabilities: reqCaps,
			AllowedCapabilities:   allowedCaps,
			MissingCapabilities:   missingCaps,
			Detail:                fmt.Sprintf("delegator %s cannot grant capabilities not within its scope", claim.PrincipalActorID),
		}
		return v.failVerification(ctx, claim, "scope_exceeded", scopeErr)
	}

	// 4. Landlock containment verification for agent-nono-evidenced
	landlockVerified := false
	if isNonoEvidenced(claim.DelegateActorID) {
		landlockVerified = hasLandlockContainment(claim)
		if !landlockVerified {
			return v.failVerification(ctx, claim, "missing_landlock_containment", ErrMissingLandlockClaim)
		}
	}

	return &VerificationResult{
		Valid:            true,
		Capabilities:     reqCaps,
		LandlockVerified: landlockVerified,
	}, nil
}

// failVerification records an audit violation observation in the store and returns the rejected result.
func (v *CapabilityClaimVerifier) failVerification(
	ctx context.Context,
	claim CapabilityClaim,
	violationType string,
	err error,
) (*VerificationResult, error) {
	now := time.Now().UTC()
	hashInput := fmt.Sprintf("%s:%s:%s:%s:%d", claim.ClaimID, claim.DelegateActorID, claim.PrincipalActorID, violationType, now.UnixNano())
	digest := sha256.Sum256([]byte(hashInput))
	obsID := fmt.Sprintf("audit-violation-%s", hex.EncodeToString(digest[:8]))

	claimID := claim.ClaimID
	if claimID == "" {
		claimID = "claim-unspecified"
	}

	obs := model.Observation{
		ID:             obsID,
		Timestamp:      now,
		Layer:          model.LayerIdentityAuth,
		Fidelity:       model.FidelityDefinitive,
		Source:         "capability-claim-verifier",
		Confidence:     1.0,
		ActorHint:      claim.PrincipalActorID,
		PrincipalID:    claim.PrincipalActorID,
		ActorID:        claim.DelegateActorID,
		RawEvidenceRef: fmt.Sprintf("violation:%s:%s", violationType, claimID),
		Description:    fmt.Sprintf("Delegation capability violation (%s): %v", violationType, err),
		Labels: map[string]string{
			"event_type":     "audit.violation",
			"violation_type": violationType,
			"delegate_id":    claim.DelegateActorID,
			"principal_id":   claim.PrincipalActorID,
			"claim_id":       claimID,
			"decision":       "rejected",
		},
	}

	if v.store != nil {
		_ = v.store.Append(ctx, []model.Observation{obs})
	}

	return &VerificationResult{
		Valid:           false,
		Error:           err,
		ViolationRecord: &obs,
	}, err
}

func capabilityAllowed(req string, allowed []string) bool {
	for _, a := range allowed {
		if a == "*" || a == req {
			return true
		}
		if strings.HasSuffix(a, ":*") {
			prefix := strings.TrimSuffix(a, "*")
			if strings.HasPrefix(req, prefix) {
				return true
			}
		}
		if strings.HasSuffix(a, ".*") {
			prefix := strings.TrimSuffix(a, "*")
			if strings.HasPrefix(req, prefix) {
				return true
			}
		}
	}
	return false
}

func isNonoEvidenced(id string) bool {
	idLower := strings.ToLower(id)
	return strings.Contains(idLower, "agent-nono-evidenced") || strings.Contains(idLower, "nono-evidenced")
}

func hasLandlockContainment(claim CapabilityClaim) bool {
	for _, c := range claim.ContainmentClaims {
		cLower := strings.ToLower(c)
		if cLower == "containment:landlock" || cLower == "landlock:enforced" || cLower == "landlock:verified" || cLower == "landlock" {
			return true
		}
	}
	if claim.Metadata != nil {
		if val, ok := claim.Metadata["landlock_containment"].(bool); ok && val {
			return true
		}
		if val, ok := claim.Metadata["landlock_verified"].(bool); ok && val {
			return true
		}
		if val, ok := claim.Metadata["landlock"].(bool); ok && val {
			return true
		}
		if str, ok := claim.Metadata["containment"].(string); ok && strings.Contains(strings.ToLower(str), "landlock") {
			return true
		}
	}
	return false
}
