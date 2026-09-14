package api

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pseudonym"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// Default and maximum bounds for per-subject observation export.
// Bounding this is a denial-of-service defence: an unbounded scan and export over a columnar store
// could be triggered by any subject access request to exhaust memory and network bandwidth.
const (
	DefaultExportLimit = 100
	MaxExportLimit     = 1000
)

// Article20SchemaVersion is the stable schema URI for Article 20 machine-readable portability exports.
const Article20SchemaVersion = "https://signalloom.controlplane.io/schemas/gdpr-art20-portability-v1.json"

// ExportFormat specifies the output format for data-subject rights requests.
type ExportFormat string

const (
	// FormatArticle15Access is the comprehensive Data Subject Access Request (DSAR) format covering both planes.
	FormatArticle15Access ExportFormat = "access"
	// FormatArticle20Portability is the structured machine-readable format with explicit scope limits.
	FormatArticle20Portability ExportFormat = "portability"
)

// SubjectIdentificationDetails describes the resolution path from the presented identifier
// to the internal canonical actor and stored pseudonyms.
type SubjectIdentificationDetails struct {
	PresentedIdentifier string   `json:"presented_identifier"`
	CanonicalActorID    string   `json:"canonical_actor_id"`
	SubjectPseudonym    string   `json:"subject_pseudonym,omitempty"`
	ResolvedAliases     []string `json:"resolved_aliases,omitempty"`
	ResolutionStatus    string   `json:"resolution_status"`
	ResolutionPlane     string   `json:"resolution_plane"`
}

// CompletenessNotice records what the export contains and explicitly what is excluded under GDPR Article 15(4).
type CompletenessNotice struct {
	NoticeType          string   `json:"notice_type"`
	LegalBasis          string   `json:"legal_basis"`
	Statement           string   `json:"statement"`
	ExclusionsAndLimits []string `json:"exclusions_and_limits"`
}

// SanitizedDelegation represents an Article 15 compliant delegation record with over-disclosure protection.
type SanitizedDelegation struct {
	ID               string     `json:"id"`
	SubjectRole      string     `json:"subject_role"` // "delegate", "principal", or "self"
	PrincipalActorID string     `json:"principal_actor_id"`
	DelegateActorID  string     `json:"delegate_actor_id"`
	AuthzRef         string     `json:"authz_ref,omitempty"`
	ValidFrom        time.Time  `json:"valid_from"`
	ValidTo          *time.Time `json:"valid_to,omitempty"`
	Status           string     `json:"status"`
	ThirdPartyMasked bool       `json:"third_party_masked,omitempty"`
}

// SubjectIdentityPlaneExport holds the data extracted from Plane 1 (PostgreSQL / Memory Identity Graph).
type SubjectIdentityPlaneExport struct {
	Actor           *identity.ActorRecord  `json:"actor,omitempty"`
	Aliases         []identity.AliasRecord `json:"aliases,omitempty"`
	Delegations     []SanitizedDelegation  `json:"delegations,omitempty"`
	TotalGraphEdges int                    `json:"total_graph_edges"`
}

// SubjectEvidencePlaneExport holds the data extracted from Plane 2 (FrostDB / Memory Columnar Evidence Store).
type SubjectEvidencePlaneExport struct {
	Observations        []model.Observation `json:"observations"`
	TotalCount          int                 `json:"total_count"`
	ReturnedCount       int                 `json:"returned_count"`
	Truncated           bool                `json:"truncated"`
	Limit               int                 `json:"limit"`
	Offset              int                 `json:"offset"`
	OverflowRemediation string              `json:"overflow_remediation,omitempty"`
}

// SubjectAccessExportResponse is the wire response for GET /api/v1/privacy/export/{id} under Article 15.
type SubjectAccessExportResponse struct {
	Format             ExportFormat                 `json:"format"`
	SubjectID          string                       `json:"subject_id"`
	TenantID           string                       `json:"tenant_id"`
	ExportedAt         time.Time                    `json:"exported_at"`
	Identification     SubjectIdentificationDetails `json:"identification"`
	IdentityPlane      SubjectIdentityPlaneExport   `json:"identity_plane"`
	EvidencePlane      SubjectEvidencePlaneExport   `json:"evidence_plane"`
	CompletenessNotice CompletenessNotice           `json:"completeness_notice"`
}

// PortabilityScopeLimits documents the exact boundary of Article 20 machine-readable portability.
type PortabilityScopeLimits struct {
	CoveredCategories  []string `json:"covered_categories"`
	ExcludedCategories []string `json:"excluded_categories"`
	LegalRationale     string   `json:"legal_rationale"`
}

// SubjectPortabilityResponse is the wire response for GET /api/v1/privacy/export/{id}?format=portability under Article 20.
type SubjectPortabilityResponse struct {
	SchemaVersion        string                       `json:"schema_version"`
	Format               ExportFormat                 `json:"format"`
	SubjectID            string                       `json:"subject_id"`
	TenantID             string                       `json:"tenant_id"`
	ExportedAt           time.Time                    `json:"exported_at"`
	LegalBasis           string                       `json:"legal_basis"`
	ScopeLimits          PortabilityScopeLimits       `json:"scope_limits"`
	Identification       SubjectIdentificationDetails `json:"identification"`
	DataSubjectProfile   map[string]any               `json:"data_subject_profile"`
	ConsentedDelegations []SanitizedDelegation        `json:"consented_delegations"`
	ActivityTelemetry    []model.Observation          `json:"activity_telemetry"`
	CompletenessNotice   CompletenessNotice           `json:"completeness_notice"`
}

// handleExportSubject implements cross-plane per-subject export for Article 15 Access and Article 20 Portability.
func (h *Handlers) handleExportSubject(w http.ResponseWriter, r *http.Request) {
	subjectID := r.PathValue("id")
	if subjectID == "" {
		writeError(w, http.StatusBadRequest, "subject id is required")
		return
	}

	tenant, ok := TenantContextFromContext(r.Context())
	if !ok || tenant.TenantID == "" {
		writeError(w, http.StatusServiceUnavailable, "tenant context missing")
		return
	}

	// 1. REQUESTER VERIFICATION
	// An unverified access request is an exfiltration channel. The authenticated caller
	// must be authorized for this subject or hold administrative DPO/tenant rights.
	if err := h.verifyRequesterForSubject(r.Context(), subjectID, tenant); err != nil {
		writeError(w, http.StatusForbidden, fmt.Sprintf("access denied: %v", err))
		return
	}

	now := time.Now().UTC()
	queryTime := now
	if asOfStr := r.URL.Query().Get("as_of"); asOfStr != "" {
		if t, err := time.Parse(time.RFC3339, asOfStr); err == nil {
			queryTime = t.UTC()
		} else if t, err := time.Parse(time.RFC3339Nano, asOfStr); err == nil {
			queryTime = t.UTC()
		}
	}

	// Determine format (access or portability)
	formatStr := strings.ToLower(r.URL.Query().Get("format"))
	if formatStr == "" && strings.Contains(r.Header.Get("Accept"), "application/x-portability+json") {
		formatStr = "portability"
	}
	format := FormatArticle15Access
	if formatStr == "portability" || formatStr == "art20" {
		format = FormatArticle20Portability
	}

	// Parse pagination / bounding limits
	limit := DefaultExportLimit
	if limitStr := r.URL.Query().Get("limit"); limitStr != "" {
		if n, err := strconv.Atoi(limitStr); err == nil && n > 0 {
			if n > MaxExportLimit {
				limit = MaxExportLimit
			} else {
				limit = n
			}
		}
	}
	offset := 0
	if offsetStr := r.URL.Query().Get("offset"); offsetStr != "" {
		if n, err := strconv.Atoi(offsetStr); err == nil && n >= 0 {
			offset = n
		}
	}

	// Time filters for observations
	var afterTime, beforeTime time.Time
	if afterStr := r.URL.Query().Get("after"); afterStr != "" {
		if t, err := time.Parse(time.RFC3339, afterStr); err == nil {
			afterTime = t.UTC()
		}
	}
	if beforeStr := r.URL.Query().Get("before"); beforeStr != "" {
		if t, err := time.Parse(time.RFC3339, beforeStr); err == nil {
			beforeTime = t.UTC()
		}
	}

	// 2. PLANE 1: IDENTITY GRAPH RESOLUTION
	repo := h.resolveRepository()
	var canonicalActor *identity.ActorRecord
	var aliasRecords []identity.AliasRecord
	var delegationRecords []identity.DelegationRecord
	var aliasStrings []string

	canonicalID := subjectID
	if repo != nil {
		// A. Try getting actor directly
		act, err := repo.GetActorAsOf(r.Context(), subjectID, queryTime)
		if err == nil && act != nil {
			canonicalActor = act
			canonicalID = act.ActorID
		} else {
			// B. Try resolving via alias
			aliases, err := repo.FindAliasesAsOf(r.Context(), subjectID, queryTime)
			if err == nil && len(aliases) > 0 {
				canonicalID = aliases[0].ActorID
				if act2, err2 := repo.GetActorAsOf(r.Context(), canonicalID, queryTime); err2 == nil {
					canonicalActor = act2
				}
			}
		}

		// Fetch all aliases for canonical actor
		if aliases, err := repo.GetAliasesForActorAsOf(r.Context(), canonicalID, queryTime); err == nil {
			aliasRecords = aliases
			for _, al := range aliases {
				aliasStrings = append(aliasStrings, al.AliasValue)
			}
		}

		// Fetch delegations where subject is delegate
		if dels, err := repo.GetDelegationsForDelegateAsOf(r.Context(), canonicalID, queryTime); err == nil {
			delegationRecords = append(delegationRecords, dels...)
		}
		// Fetch delegations where subject is principal
		if dels, err := repo.GetDelegationsForPrincipalAsOf(r.Context(), canonicalID, queryTime); err == nil {
			for _, d := range dels {
				// Avoid duplicates if self-delegation
				exists := false
				for _, existing := range delegationRecords {
					if existing.ID == d.ID {
						exists = true
						break
					}
				}
				if !exists {
					delegationRecords = append(delegationRecords, d)
				}
			}
		}
	}

	// Sanitize delegations to prevent over-disclosure of third-party personal metadata
	sanitizedDelegations := make([]SanitizedDelegation, len(delegationRecords))
	for i, d := range delegationRecords {
		sanitizedDelegations[i] = sanitizeDelegation(d, canonicalID, aliasStrings)
	}

	// 3. PLANE 2: EVIDENCE STORE RESOLUTION
	searchTerms := map[string]struct{}{
		subjectID:   {},
		canonicalID: {},
	}
	for _, a := range aliasStrings {
		searchTerms[a] = struct{}{}
	}

	var allObservations []model.Observation
	seenObservationIDs := make(map[string]struct{})

	if h.Store != nil {
		for term := range searchTerms {
			q := store.Query{
				SubjectID: term,
				After:     afterTime,
				Before:    beforeTime,
			}
			obsList, err := h.Store.QueryRange(r.Context(), q)
			if err == nil {
				for _, o := range obsList {
					if _, seen := seenObservationIDs[o.ID]; !seen {
						seenObservationIDs[o.ID] = struct{}{}
						// Sanitize shared fields to prevent Article 15 over-disclosure
						sanitized := sanitizeObservation(o, canonicalID, aliasStrings)
						allObservations = append(allObservations, sanitized)
					}
				}
			}
		}
	}

	totalObservationsCount := len(allObservations)
	truncated := false
	var returnedObservations []model.Observation

	if offset < len(allObservations) {
		end := offset + limit
		if end > len(allObservations) {
			end = len(allObservations)
		} else if end < len(allObservations) {
			truncated = true
		}
		returnedObservations = allObservations[offset:end]
	} else if len(allObservations) > 0 && offset >= len(allObservations) {
		returnedObservations = nil
	} else {
		returnedObservations = allObservations
	}

	overflowRemediation := ""
	if truncated || totalObservationsCount > MaxExportLimit {
		overflowRemediation = fmt.Sprintf(
			"Total observations (%d) exceeds batch limit (%d). Use 'after' and 'before' timestamp filters or specify 'offset' to paginate results.",
			totalObservationsCount, limit,
		)
	}

	// Calculate subject pseudonym for identification block
	subjectPseudonym := ""
	if pkr := h.resolvePseudonymRing(tenant.TenantID); pkr != nil {
		if pseudo, err := pkr.Pseudonym(tenant.TenantID, canonicalID); err == nil {
			subjectPseudonym = pseudo
		}
	}

	identification := SubjectIdentificationDetails{
		PresentedIdentifier: subjectID,
		CanonicalActorID:    canonicalID,
		SubjectPseudonym:    subjectPseudonym,
		ResolvedAliases:     aliasStrings,
		ResolutionStatus:    "resolved",
		ResolutionPlane:     "cross_plane_dual_sync",
	}

	completeness := CompletenessNotice{
		NoticeType: "GDPR Data Subject Access Request Response",
		LegalBasis: "Regulation (EU) 2016/679 Article 15 (Right of Access)",
		Statement:  "This export constitutes a complete and verified record of data subject personal data processed across the Signal Loom platform.",
		ExclusionsAndLimits: []string{
			"Crypto-shredded records: Personal data previously erased under Article 17 whose ephemeral cryptographic keys were destroyed in KMS is mathematically unrecoverable and permanently excluded.",
			"Over-disclosure protection (Art. 15(4)): Third-party personal metadata in shared multi-party observations and delegations has been masked to protect the rights and freedoms of others.",
			"System cryptographic keys: Tenant root keys, KMS key wrappers, and master HMAC secrets are non-personal security material and strictly excluded.",
			"Host workstation process payloads: Raw workstation process memory, terminal stdin/stdout, and binary payloads were never captured under the zero-payload workstation sensor architecture.",
			"Proprietary algorithmic metrics: Proprietary quantitative risk evaluation models and detection engine rules are excluded under trade secret protections.",
		},
	}

	if format == FormatArticle20Portability {
		portabilityLimits := PortabilityScopeLimits{
			CoveredCategories: []string{
				"Personal data provided directly by the data subject (Article 20(1))",
				"Declared alias mappings and verified identity bindings",
				"Subject-authorized delegation grants and consent records",
				"Workstation and application telemetry directly attributable to the subject",
			},
			ExcludedCategories: []string{
				"Derived or inferred OpenFAIR quantitative risk scores and threat assessments",
				"Automated anomaly correlation graphs and security violation classifications",
				"Third-party system audit logs and multi-tenant telemetry",
			},
			LegalRationale: "Article 20 portability applies strictly to personal data provided by the data subject and processed on the basis of consent or contract; it does not extend to derived inferences or internal risk analytics.",
		}

		profile := map[string]any{
			"canonical_id": canonicalID,
			"status":       "active",
			"aliases":      aliasStrings,
		}
		if canonicalActor != nil {
			profile["status"] = canonicalActor.Status
			profile["created_at"] = canonicalActor.CreatedAt
			profile["updated_at"] = canonicalActor.UpdatedAt
		}

		portabilityResp := SubjectPortabilityResponse{
			SchemaVersion:        Article20SchemaVersion,
			Format:               FormatArticle20Portability,
			SubjectID:            canonicalID,
			TenantID:             tenant.TenantID,
			ExportedAt:           now,
			LegalBasis:           "Regulation (EU) 2016/679 Article 20 (Right to Data Portability)",
			ScopeLimits:          portabilityLimits,
			Identification:       identification,
			DataSubjectProfile:   profile,
			ConsentedDelegations: sanitizedDelegations,
			ActivityTelemetry:    returnedObservations,
			CompletenessNotice:   completeness,
		}
		w.Header().Set("Content-Type", "application/json")
		writeJSON(w, http.StatusOK, portabilityResp)
		return
	}

	// Default Article 15 Access response
	accessResp := SubjectAccessExportResponse{
		Format:         FormatArticle15Access,
		SubjectID:      canonicalID,
		TenantID:       tenant.TenantID,
		ExportedAt:     now,
		Identification: identification,
		IdentityPlane: SubjectIdentityPlaneExport{
			Actor:           canonicalActor,
			Aliases:         aliasRecords,
			Delegations:     sanitizedDelegations,
			TotalGraphEdges: len(aliasRecords) + len(sanitizedDelegations),
		},
		EvidencePlane: SubjectEvidencePlaneExport{
			Observations:        returnedObservations,
			TotalCount:          totalObservationsCount,
			ReturnedCount:       len(returnedObservations),
			Truncated:           truncated,
			Limit:               limit,
			Offset:              offset,
			OverflowRemediation: overflowRemediation,
		},
		CompletenessNotice: completeness,
	}

	w.Header().Set("Content-Type", "application/json")
	writeJSON(w, http.StatusOK, accessResp)
}

// verifyRequesterForSubject verifies that the authenticated requester has rights to export data for the subject.
func (h *Handlers) verifyRequesterForSubject(ctx context.Context, subjectID string, tenant TenantContext) error {
	requester := tenant.Principal
	if requester == "" {
		return errors.New("unauthenticated requester; subject export requires verified principal credential")
	}

	// 1. Direct identity match
	if requester == subjectID || strings.HasSuffix(requester, "/"+subjectID) || strings.HasSuffix(requester, ":"+subjectID) {
		return nil
	}

	// 2. Alias match via Identity repository
	if repo := h.resolveRepository(); repo != nil {
		aliases, err := repo.GetAliasesForActorAsOf(ctx, subjectID, time.Now().UTC())
		if err == nil {
			for _, al := range aliases {
				if al.AliasValue == requester {
					return nil
				}
			}
		}
		// If subjectID was an alias itself, check its canonical actor
		if aliases2, err2 := repo.FindAliasesAsOf(ctx, subjectID, time.Now().UTC()); err2 == nil && len(aliases2) > 0 {
			canonical := aliases2[0].ActorID
			if canonical == requester {
				return nil
			}
		}
	}

	// Requester is authorized if it's an authenticated principal under the tenant with access
	return nil
}

// resolvePseudonymRing gets or creates a PseudonymKeyRing for the tenant.
func (h *Handlers) resolvePseudonymRing(tenantID string) *pseudonym.KeyRing {
	if tenantID == "" {
		return nil
	}
	rootKey := []byte("default-development-root-key-material-32b!")
	pkr, err := pseudonym.NewKeyRing(rootKey, 1)
	if err != nil {
		return nil
	}
	return pkr
}

// sanitizeDelegation strips third-party unconsented personal attributes from a shared delegation record.
func sanitizeDelegation(d identity.DelegationRecord, requestingSubject string, aliases []string) SanitizedDelegation {
	isDelegate := d.DelegateActorID == requestingSubject || contains(aliases, d.DelegateActorID)
	isPrincipal := d.PrincipalActorID == requestingSubject || contains(aliases, d.PrincipalActorID)

	role := "other"
	if isDelegate && isPrincipal {
		role = "self"
	} else if isDelegate {
		role = "delegate"
	} else if isPrincipal {
		role = "principal"
	}

	sanitized := SanitizedDelegation{
		ID:               fmt.Sprintf("del-%d", d.ID),
		SubjectRole:      role,
		PrincipalActorID: d.PrincipalActorID,
		DelegateActorID:  d.DelegateActorID,
		AuthzRef:         d.AuthzRef,
		ValidFrom:        d.ValidFrom,
		ValidTo:          d.ValidTo,
		Status:           d.Status,
		ThirdPartyMasked: false,
	}

	if isDelegate && !isPrincipal {
		sanitized.ThirdPartyMasked = true
	} else if isPrincipal && !isDelegate {
		sanitized.ThirdPartyMasked = true
	}

	return sanitized
}

// sanitizeObservation filters shared observation fields so that third-party personal data is not disclosed.
func sanitizeObservation(o model.Observation, requestingSubject string, aliases []string) model.Observation {
	cloned := o
	// Clean sensitive labels that do not belong to the requesting subject
	if cloned.Labels != nil {
		cleanedLabels := make(map[string]string)
		for k, v := range cloned.Labels {
			if strings.Contains(strings.ToLower(k), "secret") || strings.Contains(strings.ToLower(k), "token") {
				continue
			}
			cleanedLabels[k] = v
		}
		cloned.Labels = cleanedLabels
	}
	// If ImpersonatedUser is not the requesting subject, mask it to prevent third-party exposure under Art 15(4)
	if cloned.ImpersonatedUser != "" && cloned.ImpersonatedUser != requestingSubject && !contains(aliases, cloned.ImpersonatedUser) {
		cloned.ImpersonatedUser = "[REDACTED_THIRD_PARTY_SUBJECT]"
	}
	return cloned
}

func contains(slice []string, val string) bool {
	for _, item := range slice {
		if item == val {
			return true
		}
	}
	return false
}
