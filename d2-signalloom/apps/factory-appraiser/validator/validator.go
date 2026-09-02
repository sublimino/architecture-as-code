package validator

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

var (
	sha1Regex   = regexp.MustCompile("^[0-9a-f]{40}$")
	sha256Regex = regexp.MustCompile("^sha256:[0-9a-f]{64}$")
)

// Intent represents a typed work intent.
type Intent struct {
	ID               string    `json:"id"`
	Timestamp        time.Time `json:"timestamp"`
	Author           string    `json:"author"`
	IntentType       string    `json:"intent_type"`
	TargetRepository string    `json:"target_repository"`
	Description      string    `json:"description"`
	Expiry           time.Time `json:"expiry"`
}

// Candidate represents a code change candidate.
type Candidate struct {
	CandidateID string    `json:"candidate_id"`
	IntentID    string    `json:"intent_id"`
	CommitSHA   string    `json:"commit_sha"`
	Branch      string    `json:"branch"`
	AuthorApp   string    `json:"author_app"`
	CreatedAt   time.Time `json:"created_at"`
}

// QAEvidence represents signed verification evidence.
type QAEvidence struct {
	EvidenceID      string    `json:"evidence_id"`
	CandidateID     string    `json:"candidate_id"`
	CommitSHA       string    `json:"commit_sha"`
	TestSuiteDigest string    `json:"test_suite_digest"`
	Verdict         string    `json:"verdict"`
	QASignerApp     string    `json:"qa_signer_app"`
	SignedAt        time.Time `json:"signed_at"`
}

// Promotion represents a promotion record.
type Promotion struct {
	PromotionID       string    `json:"promotion_id"`
	ReleaseDigest     string    `json:"release_digest"`
	CommitSHA         string    `json:"commit_sha"`
	EvidenceID        string    `json:"evidence_id"`
	ApproverHuman     string    `json:"approver_human"`
	TargetEnvironment string    `json:"target_environment"`
	ApprovedAt        time.Time `json:"approved_at"`
}

// ValidateSeparationOfDuties ensures that the authoring app is distinct from the QA signer app.
func ValidateSeparationOfDuties(c Candidate, e QAEvidence) error {
	if c.CommitSHA != e.CommitSHA {
		return fmt.Errorf("commit SHA mismatch: candidate has %s, evidence has %s", c.CommitSHA, e.CommitSHA)
	}
	if c.AuthorApp == "" || e.QASignerApp == "" {
		return fmt.Errorf("author_app and qa_signer_app must be specified")
	}
	if strings.EqualFold(c.AuthorApp, e.QASignerApp) {
		return fmt.Errorf("separation of duties violation: candidate author (%s) cannot self-sign QA evidence", c.AuthorApp)
	}
	return nil
}

// ValidatePromotionContract ensures human approval, valid immutable digest, and clean QA evidence.
func ValidatePromotionContract(p Promotion, e QAEvidence) error {
	if !sha256Regex.MatchString(p.ReleaseDigest) {
		return fmt.Errorf("invalid release digest format: %s", p.ReleaseDigest)
	}
	if !sha1Regex.MatchString(p.CommitSHA) {
		return fmt.Errorf("invalid commit SHA format: %s", p.CommitSHA)
	}
	if p.ApproverHuman == "" {
		return fmt.Errorf("promotion requires explicit human approver (fail-closed)")
	}
	if e.Verdict != "pass" {
		return fmt.Errorf("promotion blocked: QA evidence verdict is %s (must be pass)", e.Verdict)
	}
	if p.CommitSHA != e.CommitSHA {
		return fmt.Errorf("promotion commit mismatch: promotion has %s, evidence has %s", p.CommitSHA, e.CommitSHA)
	}
	return nil
}
