package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/frameworks"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// PolicyStore manages versioned policy bundles across tenants and frameworks.
type PolicyStore struct {
	mu        sync.RWMutex
	bundles   map[string]map[string][]*PolicyBundle
	active    map[string]map[string]*PolicyBundle
	celEngine *CELEngine

	// obsBundles is the DURABLE observation-policy set: tenant -> bundles read
	// from POLICY_BUNDLES_DIR at boot (SLAWS v2 §4.4, D6). It is deliberately a
	// separate map from `bundles` above, which holds framework bundles and the
	// dry-run registrations the HTTP API accepts. Keeping them apart is what
	// makes "a registration never survives a restart" structural rather than a
	// convention someone has to remember.
	obsBundles map[string][]*obscel.Bundle

	pseudonymKey   []byte
	pseudonymEpoch uint32
}

// NewPolicyStore creates an initialized, thread-safe PolicyStore.
func NewPolicyStore(celEngine *CELEngine) *PolicyStore {
	return &PolicyStore{
		bundles:    make(map[string]map[string][]*PolicyBundle),
		active:     make(map[string]map[string]*PolicyBundle),
		celEngine:  celEngine,
		obsBundles: make(map[string][]*obscel.Bundle),
	}
}

// parseSemver parses semantic versions such as "v1.0.0", "v2.1", or "1.0.0".
func parseSemver(v string) ([]int, error) {
	v = strings.TrimPrefix(v, "v")
	v = strings.TrimPrefix(v, "V")
	parts := strings.Split(v, ".")
	if len(parts) == 0 {
		return nil, fmt.Errorf("empty version string")
	}
	nums := make([]int, len(parts))
	for i, p := range parts {
		clean := strings.TrimSpace(p)
		if idx := strings.IndexAny(clean, "-+"); idx != -1 {
			clean = clean[:idx]
		}
		n, err := strconv.Atoi(clean)
		if err != nil {
			return nil, fmt.Errorf("invalid version component %q in %q: %w", p, v, err)
		}
		nums[i] = n
	}
	return nums, nil
}

// compareSemver compares two semantic versions:
//
//	-1 if v1 < v2
//	 0 if v1 == v2
//	 1 if v1 > v2
func compareSemver(v1, v2 string) (int, error) {
	n1, err := parseSemver(v1)
	if err != nil {
		return 0, err
	}
	n2, err := parseSemver(v2)
	if err != nil {
		return 0, err
	}
	maxLen := len(n1)
	if len(n2) > maxLen {
		maxLen = len(n2)
	}
	for i := 0; i < maxLen; i++ {
		p1, p2 := 0, 0
		if i < len(n1) {
			p1 = n1[i]
		}
		if i < len(n2) {
			p2 = n2[i]
		}
		if p1 < p2 {
			return -1, nil
		}
		if p1 > p2 {
			return 1, nil
		}
	}
	return 0, nil
}

func (s *PolicyStore) registerLoadedFramework(fwID, ver string, fw *frameworks.Framework) {
	checks := frameworks.ChecksForVersion(fw, "")
	rules := make([]PolicyRule, 0, len(checks))
	for _, c := range checks {
		rules = append(rules, PolicyRule{
			ID:            c.Check.ID,
			Name:          c.Check.Name,
			Description:   c.Check.Description,
			CELExpression: c.Check.CELExpression,
			Severity:      c.Check.Severity,
			Remediation:   c.Check.Remediation,
			Status:        c.Check.Status,
			RiskTriple:    c.Check.RiskTriple,
			FreqTriple:    c.Check.FreqTriple,
		})
	}

	bundleVer := ver
	if !strings.HasPrefix(bundleVer, "v") && !strings.HasPrefix(bundleVer, "V") {
		bundleVer = "v" + bundleVer
	}
	// Pad if only 2 components (e.g. v2.1 -> v2.1.0)
	parts := strings.Split(bundleVer, ".")
	if len(parts) == 2 {
		bundleVer = bundleVer + ".0"
	}

	bundle := &PolicyBundle{
		ID:          fmt.Sprintf("%s-%s", fwID, bundleVer),
		FrameworkID: fwID,
		TenantID:    "", // global default
		Version:     bundleVer,
		Author:      "system",
		Description: fmt.Sprintf("Built-in regulatory framework bundle for %s", fw.Name),
		CreatedAt:   time.Now().UTC().Format(time.RFC3339),
		Status:      fw.Status,
		Rules:       rules,
	}

	if err := s.RegisterBundle("", bundle); err != nil {
		slog.Warn("skipping invalid framework bundle", "framework", fwID, "version", bundleVer, "error", err)
	}

	// Register alias between cis-kubernetes and k8s-cis-benchmark
	if fwID == "cis-kubernetes" {
		aliasBundle := *bundle
		aliasBundle.ID = fmt.Sprintf("k8s-cis-benchmark-%s", bundleVer)
		aliasBundle.FrameworkID = "k8s-cis-benchmark"
		if err := s.RegisterBundle("", &aliasBundle); err != nil {
			slog.Warn("skipping alias framework bundle", "framework", "k8s-cis-benchmark", "version", bundleVer, "error", err)
		}
	}
}

// LoadFrameworks imports existing frameworks from disk as default global bundles.
func (s *PolicyStore) LoadFrameworks(policyRoot string) error {
	available, err := frameworks.ListFrameworks(policyRoot)
	if err != nil {
		return fmt.Errorf("listing frameworks from %s: %w", policyRoot, err)
	}

	for fwID, versions := range available {
		for _, ver := range versions {
			fw, err := frameworks.Load(policyRoot, fwID, ver)
			if err != nil {
				slog.Error("failed loading framework", "framework", fwID, "version", ver, "error", err)
				continue
			}
			s.registerLoadedFramework(fwID, ver, fw)
		}
	}
	return nil
}

// LoadBuiltinFrameworks imports embedded canonical framework definitions from BuiltinFS.
func (s *PolicyStore) LoadBuiltinFrameworks() error {
	available, err := frameworks.ListEmbeddedFrameworks()
	if err != nil {
		return fmt.Errorf("listing embedded frameworks: %w", err)
	}

	for fwID, versions := range available {
		for _, ver := range versions {
			fw, err := frameworks.LoadEmbeddedFramework(fwID, ver)
			if err != nil {
				slog.Error("failed loading embedded framework", "framework", fwID, "version", ver, "error", err)
				continue
			}
			s.registerLoadedFramework(fwID, ver, fw)
		}
	}
	return nil
}

// calculateChecksum computes SHA-256 for a bundle.
func calculateChecksum(bundle *PolicyBundle) string {
	raw, err := json.Marshal(bundle.Rules)
	if err != nil {
		h := sha256.Sum256([]byte(bundle.Version + bundle.FrameworkID))
		return hex.EncodeToString(h[:])
	}
	h := sha256.Sum256(raw)
	return hex.EncodeToString(h[:])
}

// SetPseudonymConfig sets the root key and epoch for actor pseudonymisation.
func (s *PolicyStore) SetPseudonymConfig(root []byte, epoch uint32) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pseudonymKey = append([]byte(nil), root...)
	s.pseudonymEpoch = epoch
}

// PseudonymiserFor returns an obscel.HMACPseudonymiser for tenantID.
func (s *PolicyStore) PseudonymiserFor(tenantID string) (*obscel.HMACPseudonymiser, error) {
	s.mu.RLock()
	key := s.pseudonymKey
	epoch := s.pseudonymEpoch
	s.mu.RUnlock()

	if len(key) < obscel.MinRootKeyBytes {
		if raw := os.Getenv("SIGNAL_SEGMENT_PSEUDONYM_KEY"); raw != "" {
			if decoded, err := hex.DecodeString(raw); err == nil && len(decoded) >= obscel.MinRootKeyBytes {
				var ep uint32
				if rawEpoch := os.Getenv("SIGNAL_SEGMENT_PSEUDONYM_EPOCH"); rawEpoch != "" {
					if p, err := strconv.ParseUint(rawEpoch, 10, 32); err == nil {
						ep = uint32(p)
					}
				}
				s.SetPseudonymConfig(decoded, ep)
				key = decoded
				epoch = ep
			}
		}
	}
	if len(key) < obscel.MinRootKeyBytes {
		return nil, obscel.ErrRootKeyTooShort
	}
	return obscel.NewHMACPseudonymiser(key, tenantID, epoch)
}

// HasPseudonymConfig reports whether pseudonym root key material is configured.
func (s *PolicyStore) HasPseudonymConfig() bool {
	s.mu.RLock()
	hasKey := len(s.pseudonymKey) >= obscel.MinRootKeyBytes
	s.mu.RUnlock()
	if hasKey {
		return true
	}
	if raw := os.Getenv("SIGNAL_SEGMENT_PSEUDONYM_KEY"); raw != "" {
		if decoded, err := hex.DecodeString(raw); err == nil && len(decoded) >= obscel.MinRootKeyBytes {
			return true
		}
	}
	return false
}

// RegisterBundle validates and stores a new versioned policy bundle atomically.
func (s *PolicyStore) RegisterBundle(tenantID string, bundle *PolicyBundle) error {
	if bundle == nil {
		return fmt.Errorf("bundle cannot be nil")
	}
	if bundle.FrameworkID == "" {
		return fmt.Errorf("framework_id is required")
	}
	if bundle.Version == "" {
		return fmt.Errorf("version is required")
	}
	if len(bundle.Rules) == 0 {
		return fmt.Errorf("at least one policy rule is required in bundle")
	}

	if len(bundle.ActorVars) > 0 {
		if !s.HasPseudonymConfig() {
			return fmt.Errorf("bundle %s declares actor_vars but SIGNAL_SEGMENT_PSEUDONYM_KEY is not configured", bundle.ID)
		}
		ps, err := s.PseudonymiserFor(tenantID)
		if err != nil {
			return fmt.Errorf("creating pseudonymiser for tenant %s: %w", tenantID, err)
		}
		staged := make(map[string][]string, len(bundle.ActorVars))
		for _, name := range bundle.ActorVars {
			values, ok := bundle.Vars[name]
			if !ok {
				continue
			}
			out := make([]string, len(values))
			for i, v := range values {
				p, err := ps.Pseudonym(v)
				if err != nil {
					return fmt.Errorf("pseudonymising vars.%s[%d] of bundle %s: %w", name, i, bundle.ID, err)
				}
				out[i] = p
			}
			staged[name] = out
		}
		if bundle.Vars == nil && len(staged) > 0 {
			bundle.Vars = make(map[string][]string)
		}
		for name, values := range staged {
			bundle.Vars[name] = values
		}
	}

	// 1. Atomic CEL validation: Compile all rules upfront before acquiring write lock.
	for i, rule := range bundle.Rules {
		if bundle.Status == "placeholder" || rule.Status == "placeholder" {
			continue
		}
		if strings.TrimSpace(rule.CELExpression) == "" {
			return fmt.Errorf("rule %d (%s) has empty cel_expression", i, rule.ID)
		}
		if _, err := s.celEngine.CompileRule(rule.CELExpression); err != nil {
			return fmt.Errorf("rule %d (%s) failed CEL compilation: %w", i, rule.ID, err)
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	tenantKey := tenantID
	frameworkKey := bundle.FrameworkID

	if s.bundles[tenantKey] == nil {
		s.bundles[tenantKey] = make(map[string][]*PolicyBundle)
	}
	if s.active[tenantKey] == nil {
		s.active[tenantKey] = make(map[string]*PolicyBundle)
	}

	history := s.bundles[tenantKey][frameworkKey]
	if len(history) > 0 {
		latest := history[len(history)-1]
		cmp, err := compareSemver(bundle.Version, latest.Version)
		if err != nil {
			return fmt.Errorf("version check error: %w", err)
		}
		if cmp <= 0 {
			return fmt.Errorf("version %q must be strictly greater than latest registered version %q: versions must increase monotonically", bundle.Version, latest.Version)
		}
	}

	if bundle.CreatedAt == "" {
		bundle.CreatedAt = time.Now().UTC().Format(time.RFC3339)
	}
	if bundle.ID == "" {
		bundle.ID = fmt.Sprintf("%s-%s", bundle.FrameworkID, bundle.Version)
	}
	bundle.TenantID = tenantID
	bundle.Checksum = calculateChecksum(bundle)

	s.bundles[tenantKey][frameworkKey] = append(s.bundles[tenantKey][frameworkKey], bundle)
	s.active[tenantKey][frameworkKey] = bundle

	return nil
}

// Rollback reverts a framework bundle for a tenant to a specific historical version byte-for-byte.
func (s *PolicyStore) Rollback(tenantID, frameworkID, targetVersion string) (*PolicyBundle, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	tenantKey := tenantID
	history := s.bundles[tenantKey][frameworkID]
	if len(history) == 0 && tenantKey != "" {
		// If tenant has no history, check global fallback
		history = s.bundles[""][frameworkID]
	}
	if len(history) == 0 {
		return nil, fmt.Errorf("no version history found for framework %q", frameworkID)
	}

	var matched *PolicyBundle
	for _, b := range history {
		if b.Version == targetVersion {
			matched = b
			break
		}
	}

	if matched == nil {
		return nil, fmt.Errorf("target version %q not found in history for framework %q", targetVersion, frameworkID)
	}

	// Restore active pointer
	if s.active[tenantKey] == nil {
		s.active[tenantKey] = make(map[string]*PolicyBundle)
	}
	s.active[tenantKey][frameworkID] = matched

	return matched, nil
}

func resolveFrameworkAlias(id string) string {
	if id == "k8s-cis-benchmark" {
		return "cis-kubernetes"
	}
	if id == "cis-kubernetes" {
		return "k8s-cis-benchmark"
	}
	return ""
}

// GetActiveBundle returns the current active bundle for a tenant and framework.
// Tenant-specific bundles override global default frameworks.
func (s *PolicyStore) GetActiveBundle(tenantID, frameworkID, version string) (*PolicyBundle, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// If specific version is requested
	if version != "" {
		for _, fId := range []string{frameworkID, resolveFrameworkAlias(frameworkID)} {
			if fId == "" {
				continue
			}
			if tenantHistory := s.bundles[tenantID][fId]; len(tenantHistory) > 0 {
				for _, b := range tenantHistory {
					if b.Version == version {
						return b, nil
					}
				}
			}
			if globalHistory := s.bundles[""][fId]; len(globalHistory) > 0 {
				for _, b := range globalHistory {
					if b.Version == version {
						return b, nil
					}
				}
			}
		}
		return nil, fmt.Errorf("bundle version %q not found for framework %q", version, frameworkID)
	}

	// Otherwise return active bundle
	if active := s.active[tenantID][frameworkID]; active != nil {
		return active, nil
	}
	if active := s.active[""][frameworkID]; active != nil {
		return active, nil
	}
	if alias := resolveFrameworkAlias(frameworkID); alias != "" {
		if active := s.active[tenantID][alias]; active != nil {
			return active, nil
		}
		if active := s.active[""][alias]; active != nil {
			return active, nil
		}
	}

	return nil, fmt.Errorf("no active bundle found for framework %q", frameworkID)
}

// ListPolicies returns summaries of all registered frameworks and version histories for a tenant.
func (s *PolicyStore) ListPolicies(tenantID string) []PolicyBundleSummary {
	s.mu.RLock()
	defer s.mu.RUnlock()

	frameworksMap := make(map[string]bool)
	for fw := range s.bundles[""] {
		frameworksMap[fw] = true
	}
	for fw := range s.bundles[tenantID] {
		frameworksMap[fw] = true
	}

	summaries := make([]PolicyBundleSummary, 0, len(frameworksMap))
	for fw := range frameworksMap {
		var active *PolicyBundle
		if a := s.active[tenantID][fw]; a != nil {
			active = a
		} else {
			active = s.active[""][fw]
		}

		// Collect version history
		historySource := s.bundles[tenantID][fw]
		if len(historySource) == 0 {
			historySource = s.bundles[""][fw]
		}

		historyItems := make([]VersionHistoryItem, 0, len(historySource))
		latestVer := ""
		if len(historySource) > 0 {
			latestVer = historySource[len(historySource)-1].Version
			for _, b := range historySource {
				historyItems = append(historyItems, VersionHistoryItem{
					Version:     b.Version,
					Author:      b.Author,
					Description: b.Description,
					CreatedAt:   b.CreatedAt,
					RuleCount:   len(b.Rules),
					Checksum:    b.Checksum,
				})
			}
		}

		activeVer := ""
		if active != nil {
			activeVer = active.Version
		}

		summaries = append(summaries, PolicyBundleSummary{
			FrameworkID:    fw,
			TenantID:       tenantID,
			ActiveVersion:  activeVer,
			LatestVersion:  latestVer,
			ActiveBundle:   active,
			VersionHistory: historyItems,
		})
	}

	return summaries
}

// EvaluateBundle runs CEL evaluation of a bundle against the provided context.
func (s *PolicyStore) EvaluateBundle(ctx context.Context, bundle *PolicyBundle, req *EvaluatePoliciesRequest) (*EvaluatePoliciesResponse, error) {
	start := time.Now()

	inputMap := map[string]any{
		"agent":    req.Agent,
		"request":  req.Request,
		"manifest": req.Manifest,
		"object":   req.Object,
	}
	if inputMap["manifest"] == nil && inputMap["object"] != nil {
		inputMap["manifest"] = inputMap["object"]
	}
	if inputMap["object"] == nil && inputMap["manifest"] != nil {
		inputMap["object"] = inputMap["manifest"]
	}

	compliant := true
	passedCount := 0
	failedCount := 0
	var totalExposure float64
	results := make([]RuleEvaluationResult, 0, len(bundle.Rules))

	for _, rule := range bundle.Rules {
		if bundle.Status == "placeholder" || rule.Status == "placeholder" {
			results = append(results, RuleEvaluationResult{
				RuleID:      rule.ID,
				Name:        rule.Name,
				Passed:      false,
				Status:      "NOT_EVALUATED",
				Severity:    rule.Severity,
				Remediation: rule.Remediation,
				Error:       "NOT_EVALUATED",
				Cost:        0,
				LatencyMs:   0,
			})
			continue
		}

		rStart := time.Now()
		passed, cost, err := s.celEngine.Evaluate(ctx, rule.CELExpression, inputMap)
		rLatency := float64(time.Since(rStart).Microseconds()) / 1000.0

		errStr := ""
		if err != nil {
			errStr = err.Error()
			passed = false
		}

		if passed {
			passedCount++
		} else {
			failedCount++
			compliant = false
		}

		seed := checkSeed(rule.ID)
		risk := fair.Simulate(rule.RiskTriple, rule.FreqTriple, seed)
		if !passed {
			totalExposure += risk.CarriedGBP
		}

		results = append(results, RuleEvaluationResult{
			RuleID:      rule.ID,
			Name:        rule.Name,
			Passed:      passed,
			Status:      "EVALUATED",
			Severity:    rule.Severity,
			Remediation: rule.Remediation,
			Error:       errStr,
			Cost:        cost,
			LatencyMs:   rLatency,
			ALE:         risk.ALE,
			VaR95:       risk.VaR95,
			TVaR:        risk.TVaR,
			CarriedGBP:  risk.CarriedGBP,
		})
	}

	totalLatency := float64(time.Since(start).Microseconds()) / 1000.0

	return &EvaluatePoliciesResponse{
		Compliant:     compliant,
		TenantID:      req.TenantID,
		FrameworkID:   bundle.FrameworkID,
		PolicyVersion: bundle.Version,
		TotalRules:    len(bundle.Rules),
		PassedRules:   passedCount,
		FailedRules:   failedCount,
		TotalExposure: totalExposure,
		Results:       results,
		EvaluatedAt:   time.Now().UTC().Format(time.RFC3339),
		EvaluationMs:  totalLatency,
	}, nil
}
