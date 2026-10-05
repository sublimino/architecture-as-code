// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/policy"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// Policy review API permissions.
//
// Two, not one, and deliberately neither of them observations:read. The decision this split
// encodes is that reading what the policy concluded and asserting whether it was right are
// different privileges held by different people: an evidence reader (the e2e key
// sldc-evidence-reader, a SIEM forwarder, an auditor) must be able to see nothing new and must
// certainly not be able to put a verdict into the evidence it is reading. Folding the reads into
// observations:read would have given every existing reader the findings and decisions feed with
// no grant; folding the write into either read would have made every reader a reviewer.
const (
	// PermissionPolicyRead gates the three read routes: findings, decisions, rates.
	PermissionPolicyRead Permission = "policy:read"
	// PermissionPolicyReview gates recording a verdict. No key holds it by default.
	PermissionPolicyReview Permission = "policy:review"
)

// policyWindows is the closed set of relative windows the review UI offers. A closed set rather
// than a parsed duration: an open duration parameter is an unbounded scan of the store behind an
// authenticated GET, and the four values are what the dashboard's control actually has.
var policyWindows = map[string]time.Duration{
	"5m":  5 * time.Minute,
	"10m": 10 * time.Minute,
	"30m": 30 * time.Minute,
	"90m": 90 * time.Minute,
}

// defaultPolicyWindow applies when a request names neither window nor since.
const defaultPolicyWindow = 30 * time.Minute

// Limits on the policy read routes.
const (
	// DefaultPolicyLimit is the page size when a request names no limit.
	DefaultPolicyLimit = 100
	// MaxPolicyLimit is the ceiling the contract fixes. A larger limit is a 400, not a silent clamp:
	// a caller that asked for 2000 and received 500 with no indication would under-report.
	MaxPolicyLimit = 500
	// MaxPolicyRateRows caps buckets x series on the rates route. The chart cannot render more and
	// an unbounded cross-product of layer x source x bucket is the one place these routes could be
	// made to allocate without limit.
	MaxPolicyRateRows = 2000
	// MaxReviewBodyBytes bounds the review request body. A verdict and a 500-rune note fit in well
	// under 4KB; 16KB leaves room for UTF-8 and JSON escaping without admitting a payload.
	MaxReviewBodyBytes = 16 * 1024
)

// policyReadRequest is the parsed, validated, tenancy-resolved shape of a policy read.
type policyReadRequest struct {
	after  time.Time
	limit  int
	tenant string
	all    bool
}

// parsePolicyRead validates the query and resolves tenancy, writing the refusal itself and
// returning ok=false when the request cannot be served. One function for all three read routes so
// a parameter cannot mean one thing on findings and another on rates.
func parsePolicyRead(w http.ResponseWriter, r *http.Request) (policyReadRequest, bool) {
	q := r.URL.Query()
	var out policyReadRequest

	window, since := q.Get("window"), q.Get("since")
	switch {
	case window != "" && since != "":
		// Both name a start. Picking one silently would make the other parameter a no-op that a
		// caller reasonably believes is in force.
		writeError(w, http.StatusBadRequest, "window and since are mutually exclusive")
		return out, false
	case since != "":
		t, err := time.Parse(time.RFC3339, since)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid 'since' time: "+err.Error())
			return out, false
		}
		out.after = t.UTC()
	case window != "":
		d, ok := policyWindows[window]
		if !ok {
			writeError(w, http.StatusBadRequest, "invalid 'window': want one of "+strings.Join(policyWindowNames(), ", "))
			return out, false
		}
		out.after = time.Now().UTC().Add(-d)
	default:
		out.after = time.Now().UTC().Add(-defaultPolicyWindow)
	}

	out.limit = DefaultPolicyLimit
	if raw := q.Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid 'limit': "+err.Error())
			return out, false
		}
		if n <= 0 || n > MaxPolicyLimit {
			writeError(w, http.StatusBadRequest, "limit must be in [1, "+strconv.Itoa(MaxPolicyLimit)+"]")
			return out, false
		}
		out.limit = n
	}

	tenant, all, ok := policyTenantScope(w, r)
	if !ok {
		return out, false
	}
	out.tenant, out.all = tenant, all
	return out, true
}

func policyWindowNames() []string {
	names := make([]string, 0, len(policyWindows))
	for k := range policyWindows {
		names = append(names, k)
	}
	sort.Slice(names, func(i, j int) bool { return policyWindows[names[i]] < policyWindows[names[j]] })
	return names
}

// policyTenantScope resolves which tenant's policy records the request may read.
//
// The base is observationReadScope, the same function every observation read uses, so a reviewer
// cannot see a finding it could not have seen as an observation. The `tenant` parameter narrows
// that and never widens it: a cross-tenant reader may pick one tenant out of the whole set, and a
// scoped principal may name its OWN tenant (which is a no-op, and accepting it keeps a dashboard
// from having to know whether its user is a superadmin before building a URL) but naming any
// other tenant is 403, never an empty result. An empty result would be a worse answer than a
// refusal: it reads as "that tenant has no decisions".
func policyTenantScope(w http.ResponseWriter, r *http.Request) (string, bool, bool) {
	tenant, all := observationReadScope(r)
	requested := r.URL.Query().Get("tenant")
	if requested == "" {
		return tenant, all, true
	}
	if !actingTenantPattern.MatchString(requested) {
		writeError(w, http.StatusBadRequest, "invalid 'tenant'")
		return "", false, false
	}
	if !all && requested != tenant {
		writeError(w, http.StatusForbidden, "cross_tenant_read_required")
		return "", false, false
	}
	return requested, false, true
}

// policySourceRows reads the window once and returns the deduplicated rows of one policy source,
// scoped to the request's tenancy. The limit is NOT applied here: findings and decisions are
// sorted newest-first before truncation, and rates aggregates the whole window.
func (h *Handlers) policySourceRows(r *http.Request, req policyReadRequest, source string) ([]model.Observation, error) {
	rows, err := h.policyWindowRows(r, req)
	if err != nil {
		return nil, err
	}
	out := make([]model.Observation, 0, len(rows))
	for i := range rows {
		if rows[i].Source == source {
			out = append(out, rows[i])
		}
	}
	return out, nil
}

// policyWindowRows is every observation in the window the request may see, deduplicated.
//
// DedupeByID runs before the tenancy filter and before any aggregation, for the same reason
// handleQueryObservations runs it before the limit: a duplicated row in a pre-Deduper segment is
// a burst that never happened, and counting it twice in a rate chart or listing it twice in a
// review queue would put a fiction in front of the human whose judgement we are recording.
func (h *Handlers) policyWindowRows(r *http.Request, req policyReadRequest) ([]model.Observation, error) {
	rows, err := h.Store.QueryRange(r.Context(), store.Query{After: req.after})
	if err != nil {
		return nil, err
	}
	rows = store.DedupeByID(rows)
	return scopeObservations(rows, req.tenant, req.all, 0), nil
}

// findingView is the wire shape of a stage-1 finding, per the dashboard contract.
type findingView struct {
	ID                  string            `json:"id"`
	Timestamp           time.Time         `json:"timestamp"`
	TenantID            string            `json:"tenant_id"`
	Actor               string            `json:"actor"`
	Layer               string            `json:"layer"`
	SourceObservationID string            `json:"source_observation_id"`
	RuleID              string            `json:"rule_id"`
	BundleID            string            `json:"bundle_id"`
	BundleVersion       string            `json:"bundle_version"`
	Severity            string            `json:"severity"`
	Mode                string            `json:"mode"`
	Labels              map[string]string `json:"labels"`
}

// reviewView is a recorded verdict as the decisions feed carries it.
type reviewView struct {
	ID         string    `json:"id"`
	Verdict    string    `json:"verdict"`
	Note       string    `json:"note"`
	Reviewer   string    `json:"reviewer"`
	ReviewedAt time.Time `json:"reviewed_at"`
}

// decisionView is the wire shape of a stage-2 decision plus its latest review.
type decisionView struct {
	ID            string      `json:"id"`
	Timestamp     time.Time   `json:"timestamp"`
	TenantID      string      `json:"tenant_id"`
	Actor         string      `json:"actor"`
	WindowID      string      `json:"window_id"`
	RuleID        string      `json:"rule_id"`
	BundleID      string      `json:"bundle_id"`
	BundleVersion string      `json:"bundle_version"`
	Severity      string      `json:"severity"`
	Mode          string      `json:"mode"`
	Count         int         `json:"count"`
	FindingIDs    []string    `json:"finding_ids"`
	Review        *reviewView `json:"review"`
}

// reviewResponse is the 201 body of a recorded review.
type reviewResponse struct {
	ID         string    `json:"id"`
	DecisionID string    `json:"decision_id"`
	Verdict    string    `json:"verdict"`
	Note       string    `json:"note"`
	Reviewer   string    `json:"reviewer"`
	ReviewedAt time.Time `json:"reviewed_at"`
}

// rateBucketView is one point of one series on the live chart.
type rateBucketView struct {
	BucketStart time.Time `json:"bucket_start"`
	Layer       string    `json:"layer"`
	Source      string    `json:"source"`
	Count       int       `json:"count"`
}

// handlePolicyFindings answers GET /api/v1/policy/findings.
func (h *Handlers) handlePolicyFindings(w http.ResponseWriter, r *http.Request) {
	req, ok := parsePolicyRead(w, r)
	if !ok {
		return
	}
	rows, err := h.policySourceRows(r, req, obscel.SourceFinding)
	if err != nil {
		slog.Error("policy findings query failed", "error", err)
		writeError(w, http.StatusInternalServerError, "query failed")
		return
	}
	sortByTimestampDesc(rows)
	if len(rows) > req.limit {
		rows = rows[:req.limit]
	}
	out := make([]findingView, 0, len(rows))
	for i := range rows {
		o := &rows[i]
		out = append(out, findingView{
			ID: o.ID, Timestamp: o.Timestamp, TenantID: o.Labels[policy.TenantLabel],
			Actor: o.ActorHint, Layer: string(o.Layer),
			SourceObservationID: o.Labels[policy.LabelSourceObsID],
			RuleID:              o.Labels[policy.LabelRuleID],
			BundleID:            o.Labels[policy.LabelBundleID],
			BundleVersion:       o.Labels[policy.LabelBundleVersion],
			Severity:            o.Labels[policy.LabelSeverity],
			Mode:                o.Labels[policy.LabelMode],
			Labels:              o.Labels,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

// handlePolicyDecisions answers GET /api/v1/policy/decisions, joining each decision to the latest
// verdict recorded against it.
func (h *Handlers) handlePolicyDecisions(w http.ResponseWriter, r *http.Request) {
	req, ok := parsePolicyRead(w, r)
	if !ok {
		return
	}
	rows, err := h.policyWindowRows(r, req)
	if err != nil {
		slog.Error("policy decisions query failed", "error", err)
		writeError(w, http.StatusInternalServerError, "query failed")
		return
	}

	// A review is written when the human clicks, which can be long after the decision it judges.
	// So the reviews are collected over the WHOLE store rather than the requested window: a
	// decision inside a 5m window whose verdict was recorded an hour later must still show that
	// verdict, or the reviewer would see their own judgement vanish and record it again.
	latest, err := h.latestReviews(r)
	if err != nil {
		slog.Error("policy reviews query failed", "error", err)
		writeError(w, http.StatusInternalServerError, "query failed")
		return
	}

	decisions := make([]model.Observation, 0, len(rows))
	for i := range rows {
		if rows[i].Source == obscel.SourceDecision {
			decisions = append(decisions, rows[i])
		}
	}
	sortByTimestampDesc(decisions)
	if len(decisions) > req.limit {
		decisions = decisions[:req.limit]
	}

	out := make([]decisionView, 0, len(decisions))
	for i := range decisions {
		o := &decisions[i]
		v := decisionView{
			ID: o.ID, Timestamp: o.Timestamp, TenantID: o.Labels[policy.TenantLabel],
			Actor: o.ActorHint, WindowID: o.Labels[policy.LabelWindowID],
			RuleID:        o.Labels[policy.LabelRuleID],
			BundleID:      o.Labels[policy.LabelBundleID],
			BundleVersion: o.Labels[policy.LabelBundleVersion],
			Severity:      o.Labels[policy.LabelSeverity],
			Mode:          o.Labels[policy.LabelMode],
			Count:         labelInt(o.Labels[policy.LabelCount]),
			FindingIDs:    splitIDs(o.Labels[policy.LabelFindingIDs]),
		}
		if rv, found := latest[o.ID]; found {
			v.Review = &reviewView{ID: rv.ID, Verdict: string(rv.Verdict), Note: rv.Note,
				Reviewer: rv.Reviewer, ReviewedAt: rv.ReviewedAt}
		}
		out = append(out, v)
	}
	writeJSON(w, http.StatusOK, out)
}

// latestReviews indexes the newest review per decision, within the request's tenancy.
//
// "Newest" rather than "only": ReviewID hashes the verdict and the note, so a reviewer who
// changes their mind writes a SECOND review rather than overwriting the first. Both stay in the
// evidence; the feed shows the current position. A tie on timestamp is broken by ID so the answer
// is the same on every call rather than depending on store iteration order.
func (h *Handlers) latestReviews(r *http.Request) (map[string]policy.Review, error) {
	tenant, all := observationReadScope(r)
	rows, err := h.Store.QueryRange(r.Context(), store.Query{})
	if err != nil {
		return nil, err
	}
	rows = store.DedupeByID(rows)
	rows = scopeObservations(rows, tenant, all, 0)
	out := make(map[string]policy.Review)
	for i := range rows {
		if !policy.IsReview(&rows[i]) {
			continue
		}
		rv := policy.ReviewFromObservation(rows[i])
		if rv.DecisionID == "" {
			continue
		}
		cur, seen := out[rv.DecisionID]
		if !seen || rv.ReviewedAt.After(cur.ReviewedAt) ||
			(rv.ReviewedAt.Equal(cur.ReviewedAt) && rv.ID > cur.ID) {
			out[rv.DecisionID] = rv
		}
	}
	return out, nil
}

// reviewRequestBody is the closed wire shape of a POST review.
type reviewRequestBody struct {
	Verdict string `json:"verdict"`
	Note    string `json:"note"`
}

// handlePolicyReview answers POST /api/v1/policy/decisions/{id}/review.
func (h *Handlers) handlePolicyReview(w http.ResponseWriter, r *http.Request) {
	decisionID := r.PathValue("id")
	if decisionID == "" {
		writeError(w, http.StatusBadRequest, "decision id is required")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, MaxReviewBodyBytes)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "failed to read request body")
		return
	}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	// Closed-world decoding: a misspelled field is a 400 and not a silently ignored verdict.
	dec.DisallowUnknownFields()
	var body reviewRequestBody
	if err := dec.Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid review body: "+err.Error())
		return
	}

	verdict := policy.Verdict(body.Verdict)
	if !verdict.IsValid() {
		writeError(w, http.StatusBadRequest, "invalid 'verdict': want one of "+verdictNames())
		return
	}
	note, truncated := policy.NormaliseNote(body.Note)
	if truncated {
		// The note is the record of WHY, so silently shortening it would alter the reviewer's
		// stated reason and then attribute the altered version to them.
		writeError(w, http.StatusBadRequest,
			"note exceeds "+strconv.Itoa(policy.MaxReviewNoteLen)+" characters")
		return
	}

	// The decision has to exist and be visible to this principal, and both for the same reason:
	// a verdict against an unknown ID is an un-joinable row in the evidence, and a 404 for
	// another tenant's decision is what keeps this route from being an existence oracle over the
	// whole estate.
	decision, err := h.visibleDecision(r, decisionID)
	if err != nil {
		slog.Error("policy review decision lookup failed", "error", err)
		writeError(w, http.StatusInternalServerError, "query failed")
		return
	}
	if decision == nil {
		writeError(w, http.StatusNotFound, "decision not found")
		return
	}

	reviewer := reviewerPrincipal(r)
	if reviewer == "" {
		// Unreachable behind the router, which authenticates first. Explicit because an
		// unattributed verdict is worse than no verdict: it is a judgement in the evidence with
		// nobody's name on it.
		writeError(w, http.StatusUnauthorized, "authentication required")
		return
	}
	tenantID := decision.Labels[policy.TenantLabel]

	rv := policy.Review{
		ID:         policy.ReviewID(tenantID, decisionID, reviewer, string(verdict), note),
		DecisionID: decisionID, TenantID: tenantID, Verdict: verdict, Note: note,
		Reviewer: reviewer, ReviewedAt: h.clock().UTC(),
	}

	// Idempotency is checked before the write and answered as a conflict.
	//
	// The deduper behind Store.Append would collapse the replay by itself and return nil, so the
	// store is safe either way; what it cannot do is tell the caller which of the two happened.
	// A dashboard that double-fires on a slow click needs to know that the second call changed
	// nothing, and 409 says so. The check and the write are not atomic — two simultaneous
	// identical POSTs can both pass it — but the ID is derived, so the loser is deduplicated into
	// the same single row rather than producing a duplicate verdict.
	existing, err := h.observationByID(r, rv.ID)
	if err != nil {
		slog.Error("policy review idempotency check failed", "error", err)
		writeError(w, http.StatusInternalServerError, "query failed")
		return
	}
	if existing != nil {
		prior := policy.ReviewFromObservation(*existing)
		slog.Info("policy review already recorded", "decision", decisionID, "reviewer", reviewer,
			"verdict", string(verdict))
		writeJSON(w, http.StatusConflict, map[string]any{
			"error": "review already recorded",
			"review": reviewResponse{ID: prior.ID, DecisionID: prior.DecisionID,
				Verdict: string(prior.Verdict), Note: prior.Note, Reviewer: prior.Reviewer,
				ReviewedAt: prior.ReviewedAt},
		})
		return
	}

	obs := policy.ReviewObservation(rv, decision)
	if err := obs.Validate(); err != nil {
		slog.Error("policy review observation is invalid", "error", err)
		writeError(w, http.StatusInternalServerError, "failed to record review")
		return
	}
	// Store, not a side table: h.Store is the policy store wrapper in production, so this goes
	// through the same Append, the same deduper and the same segment attestation as every other
	// observation.
	if err := h.Store.Append(r.Context(), []model.Observation{obs}); err != nil {
		slog.Error("policy review append failed", "error", err, "decision", decisionID)
		writeError(w, http.StatusInternalServerError, "failed to record review")
		return
	}
	slog.Info("policy decision reviewed", "decision", decisionID, "verdict", string(verdict),
		"reviewer", reviewer, "tenant", tenantID)
	writeJSON(w, http.StatusCreated, reviewResponse{
		ID: rv.ID, DecisionID: rv.DecisionID, Verdict: string(rv.Verdict), Note: rv.Note,
		Reviewer: rv.Reviewer, ReviewedAt: rv.ReviewedAt,
	})
}

// handlePolicyRates answers GET /api/v1/policy/rates: a bucketed count per layer per source over
// EVERY observation in the window, raw and derived alike. The chart's job is to show the pipeline
// working — raw signal in, findings out, decisions out — so filtering to policy sources here
// would remove the denominator that makes the other two series mean anything.
func (h *Handlers) handlePolicyRates(w http.ResponseWriter, r *http.Request) {
	req, ok := parsePolicyRead(w, r)
	if !ok {
		return
	}
	bucket := time.Minute
	switch raw := r.URL.Query().Get("bucket"); raw {
	case "", "1m":
	case "5m":
		bucket = 5 * time.Minute
	default:
		writeError(w, http.StatusBadRequest, "invalid 'bucket': want 1m or 5m")
		return
	}

	rows, err := h.policyWindowRows(r, req)
	if err != nil {
		slog.Error("policy rates query failed", "error", err)
		writeError(w, http.StatusInternalServerError, "query failed")
		return
	}

	type seriesKey struct {
		bucket time.Time
		layer  string
		source string
	}
	counts := make(map[seriesKey]int)
	for i := range rows {
		counts[seriesKey{
			bucket: rows[i].Timestamp.UTC().Truncate(bucket),
			layer:  string(rows[i].Layer),
			source: rows[i].Source,
		}]++
	}

	out := make([]rateBucketView, 0, len(counts))
	for k, n := range counts {
		out = append(out, rateBucketView{BucketStart: k.bucket, Layer: k.layer, Source: k.source, Count: n})
	}
	// Oldest bucket first, then layer, then source: a chart reads left to right, and a stable
	// order means two calls over the same data draw the same picture.
	sort.Slice(out, func(i, j int) bool {
		if !out[i].BucketStart.Equal(out[j].BucketStart) {
			return out[i].BucketStart.Before(out[j].BucketStart)
		}
		if out[i].Layer != out[j].Layer {
			return out[i].Layer < out[j].Layer
		}
		return out[i].Source < out[j].Source
	})
	// The cap keeps the NEWEST rows. A truncated chart that drops the right-hand edge would hide
	// whatever is happening now, which is the only part anyone is watching.
	if len(out) > MaxPolicyRateRows {
		out = out[len(out)-MaxPolicyRateRows:]
	}
	writeJSON(w, http.StatusOK, out)
}

// visibleDecision returns the stored decision with this ID if the request's principal may see it,
// and nil if it does not exist or belongs to another tenant. The two are deliberately
// indistinguishable to the caller.
func (h *Handlers) visibleDecision(r *http.Request, id string) (*model.Observation, error) {
	obs, err := h.observationByID(r, id)
	if err != nil || obs == nil {
		return nil, err
	}
	if obs.Source != obscel.SourceDecision {
		// An ID that names a finding, a raw observation or a review is not a decision, and
		// accepting a verdict against one would put an un-joinable row in the evidence.
		return nil, nil
	}
	return obs, nil
}

// observationByID finds one observation the request's principal may read.
func (h *Handlers) observationByID(r *http.Request, id string) (*model.Observation, error) {
	tenant, all := observationReadScope(r)
	rows, err := h.Store.QueryRange(r.Context(), store.Query{})
	if err != nil {
		return nil, err
	}
	rows = scopeObservations(store.DedupeByID(rows), tenant, all, 0)
	for i := range rows {
		if rows[i].ID == id {
			return &rows[i], nil
		}
	}
	return nil, nil
}

// reviewerPrincipal names the human whose judgement is being recorded.
//
// For a gateway (fe-signalloom, holding tenant:act-for) that is the dashboard user it names in
// ActingSubjectHeader: the gateway's own key subject is shared by every user behind it, so
// attributing a verdict to it would record "the dashboard" rather than a person. For every other
// principal the header grants nothing and is ignored — exactly as in rateLimitKey — so a plain
// client cannot forge somebody else's name onto a verdict, and the attribution is the key's own
// subject.
//
// The gateway's subject is kept as a prefix rather than replaced, so a verdict reads
// "static-key/fe-signalloom-gateway/alice@example.com": the record says both who asserted it and
// which credential carried it, and the two cannot be confused.
func reviewerPrincipal(r *http.Request) string {
	p, ok := PrincipalFromContext(r.Context())
	if !ok {
		return ""
	}
	if !p.Permissions[PermissionActForTenant] {
		return p.Subject
	}
	values := r.Header.Values(ActingSubjectHeader)
	if len(values) != 1 || !actingSubjectPattern.MatchString(values[0]) {
		return p.Subject
	}
	return p.Subject + "/" + values[0]
}

func verdictNames() string {
	names := make([]string, 0, len(policy.Verdicts()))
	for _, v := range policy.Verdicts() {
		names = append(names, string(v))
	}
	return strings.Join(names, ", ")
}

// sortByTimestampDesc orders rows newest-first, breaking ties on ID so a page boundary is stable
// across calls rather than depending on the store's iteration order.
func sortByTimestampDesc(rows []model.Observation) {
	sort.Slice(rows, func(i, j int) bool {
		if !rows[i].Timestamp.Equal(rows[j].Timestamp) {
			return rows[i].Timestamp.After(rows[j].Timestamp)
		}
		return rows[i].ID < rows[j].ID
	})
}

// labelInt reads a non-negative integer label, returning 0 for anything else. A malformed count
// must not fail the whole feed: the decision is still real and still needs reviewing.
func labelInt(v string) int {
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

// splitIDs parses a comma-joined ID label into a slice, never nil: encoding/json renders a nil
// slice as `null`, and a dashboard that declared the field an array crashes dereferencing it
// (the same defect handleQueryObservations carries a comment about).
func splitIDs(v string) []string {
	if v == "" {
		return []string{}
	}
	parts := strings.Split(v, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// clock is the server time a review is stamped with; nil means time.Now. Injectable so a test can
// assert the timestamp rather than assert that it is approximately now.
func (h *Handlers) clock() time.Time {
	if h != nil && h.now != nil {
		return h.now()
	}
	return time.Now()
}
