package validator

import (
	"testing"
	"time"
)

func TestValidateSeparationOfDuties(t *testing.T) {
	c := Candidate{
		CandidateID: "cand-1",
		CommitSHA:   "0123456789abcdef0123456789abcdef01234567",
		AuthorApp:   "platform-forge",
	}

	// Passing case: distinct identities
	eValid := QAEvidence{
		EvidenceID:  "evi-1",
		CandidateID: "cand-1",
		CommitSHA:   "0123456789abcdef0123456789abcdef01234567",
		Verdict:     "pass",
		QASignerApp: "qa-evidence-verifier",
	}
	if err := ValidateSeparationOfDuties(c, eValid); err != nil {
		t.Errorf("expected clean validation, got: %v", err)
	}

	// Violation case: self-signing
	eSelfSign := QAEvidence{
		EvidenceID:  "evi-2",
		CandidateID: "cand-1",
		CommitSHA:   "0123456789abcdef0123456789abcdef01234567",
		Verdict:     "pass",
		QASignerApp: "platform-forge",
	}
	if err := ValidateSeparationOfDuties(c, eSelfSign); err == nil {
		t.Errorf("expected separation of duties error, got nil")
	}
}

func TestValidatePromotionContract(t *testing.T) {
	p := Promotion{
		PromotionID:       "promo-1",
		ReleaseDigest:     "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		CommitSHA:         "0123456789abcdef0123456789abcdef01234567",
		EvidenceID:        "evi-1",
		ApproverHuman:     "andy@control-plane.io",
		TargetEnvironment: "demo-1",
		ApprovedAt:        time.Now().UTC(),
	}
	e := QAEvidence{
		EvidenceID: "evi-1",
		CommitSHA:  "0123456789abcdef0123456789abcdef01234567",
		Verdict:    "pass",
	}

	if err := ValidatePromotionContract(p, e); err != nil {
		t.Fatalf("unexpected promotion error: %v", err)
	}

	// Human missing
	pNoHuman := p
	pNoHuman.ApproverHuman = ""
	if err := ValidatePromotionContract(pNoHuman, e); err == nil {
		t.Errorf("expected error on missing human approver, got nil")
	}

	// Failed verdict
	eFail := e
	eFail.Verdict = "fail"
	if err := ValidatePromotionContract(p, eFail); err == nil {
		t.Errorf("expected error on failing QA verdict, got nil")
	}
}
