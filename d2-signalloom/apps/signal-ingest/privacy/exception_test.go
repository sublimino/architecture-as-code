package privacy

import (
	"context"
	"crypto/ed25519"
	"errors"
	"testing"
	"time"
)

// =============================================================================================
// DUAL-OPERATOR AUTHORISATION
//
// Every test in this block drives the override through a service whose destroyer is a TRIPWIRE.
// A rejected override that nevertheless reached key material would fail even if the assertion
// below were wrong.
// =============================================================================================

// overrideCase runs an erasure against a held subject with the supplied exception mutation and
// returns the error.
func overrideCase(t *testing.T, mutate func(*RetentionException, testOperator, testOperator), ops ...testOperator) error {
	t.Helper()
	const subject = "actor-contained"
	if len(ops) == 0 {
		ops = []testOperator{newTestOperator(t, "op-alice"), newTestOperator(t, "op-bob")}
	}
	seq := &sequenceRecorder{}
	fx := newTripwireFixture(t, availableSource(seq, containmentHold(subject)), ops...)
	req := baseRequest(subject)
	e := validException(t, req, ops[0], ops[1])
	if mutate != nil {
		mutate(e, ops[0], ops[1])
	}
	req.Exception = e
	_, err := fx.svc.Erase(context.Background(), req)
	return err
}

// resign re-signs an exception after its signed fields were changed. Without it, every mutation
// test would fail on the signature rather than on the rule it means to exercise, and the suite
// would report the right verdict for the wrong reason.
func resign(t *testing.T, e *RetentionException, ops ...testOperator) {
	t.Helper()
	e.Approvals = nil
	for _, op := range ops {
		approval, err := SignApproval(*e, op.id, op.secret)
		if err != nil {
			t.Fatalf("re-sign as %s: %v", op.id, err)
		}
		e.Approvals = append(e.Approvals, approval)
	}
}

func TestOverrideRequiresTwoDistinctOperators(t *testing.T) {
	alice := newTestOperator(t, "op-alice")
	bob := newTestOperator(t, "op-bob")

	t.Run("zero approvals", func(t *testing.T) {
		err := overrideCase(t, func(e *RetentionException, _, _ testOperator) { e.Approvals = nil }, alice, bob)
		if !errors.Is(err, ErrInsufficientApprovals) {
			t.Fatalf("want ErrInsufficientApprovals, got %v", err)
		}
	})

	t.Run("one approval", func(t *testing.T) {
		err := overrideCase(t, func(e *RetentionException, a, _ testOperator) { resign(t, e, a) }, alice, bob)
		if !errors.Is(err, ErrInsufficientApprovals) {
			t.Fatalf("want ErrInsufficientApprovals, got %v", err)
		}
	})

	// THE defect this control exists to prevent: one person signing twice. Both signatures are
	// cryptographically valid and both verify against a registered key; only the distinctness rule
	// catches it.
	t.Run("same operator signing twice", func(t *testing.T) {
		err := overrideCase(t, func(e *RetentionException, a, _ testOperator) { resign(t, e, a, a) }, alice, bob)
		if !errors.Is(err, ErrInsufficientApprovals) {
			t.Fatalf("one operator signed twice and it was ACCEPTED as dual authorisation: %v", err)
		}
	})

	// Three approvals: the rule is a minimum, not an equality.
	t.Run("three distinct approvals accepted", func(t *testing.T) {
		carol := newTestOperator(t, "op-carol")
		const subject = "actor-contained"
		seq := &sequenceRecorder{}
		fx := newServiceFixture(t, availableSource(seq, containmentHold(subject)), seq, alice, bob, carol)
		req := baseRequest(subject)
		req.Exception = validException(t, req, alice, bob, carol)
		decision, err := fx.svc.Erase(context.Background(), req)
		if err != nil {
			t.Fatalf("three valid approvals were refused: %v", err)
		}
		if len(decision.Approvers) != 3 {
			t.Errorf("recorded %d approvers, want 3", len(decision.Approvers))
		}
	})
}

// TestOverrideRequesterMayNotApprove is separated from the distinctness tests because it fails for
// a different reason: the two signatures ARE distinct, and the control still has to refuse.
func TestOverrideRequesterMayNotApprove(t *testing.T) {
	requester := newTestOperator(t, "op-requester")
	bob := newTestOperator(t, "op-bob")
	const subject = "actor-contained"

	seq := &sequenceRecorder{}
	fx := newTripwireFixture(t, availableSource(seq, containmentHold(subject)), requester, bob)
	req := baseRequest(subject) // RequestedBy is "op-requester"
	req.Exception = validException(t, req, requester, bob)

	_, err := fx.svc.Erase(context.Background(), req)
	if !errors.Is(err, ErrRequesterIsApprover) {
		t.Fatalf("the requester approved their own erasure and it was accepted: %v", err)
	}
}

func TestOverrideRejectsUnauthorisedSigners(t *testing.T) {
	alice := newTestOperator(t, "op-alice")
	bob := newTestOperator(t, "op-bob")
	stranger := newTestOperator(t, "op-stranger")

	t.Run("signer absent from the registry", func(t *testing.T) {
		const subject = "actor-contained"
		seq := &sequenceRecorder{}
		// Registry contains alice and bob only; stranger signs.
		fx := newTripwireFixture(t, availableSource(seq, containmentHold(subject)), alice, bob)
		req := baseRequest(subject)
		req.Exception = validException(t, req, alice, stranger)
		if _, err := fx.svc.Erase(context.Background(), req); !errors.Is(err, ErrOperatorNotRegistered) {
			t.Fatalf("an unregistered operator's signature was accepted: %v", err)
		}
	})

	t.Run("registered signer lacking the capability", func(t *testing.T) {
		const subject = "actor-contained"
		reg, err := NewOperatorRegistry([]Operator{
			{ID: alice.id, PublicKey: alice.public, Capabilities: []OperatorCapability{CapabilityGrantErasureOverride}},
			// bob is registered but holds no capabilities at all.
			{ID: bob.id, PublicKey: bob.public},
		})
		if err != nil {
			t.Fatalf("build registry: %v", err)
		}
		seq := &sequenceRecorder{}
		svc, err := NewService(Config{
			Incidents:     availableSource(seq, containmentHold(subject)),
			Destroyer:     tripwireDestroyer{t: t},
			Audit:         newHealthyAudit(),
			Operators:     reg,
			Pseudonymiser: fakePseudonymiser{},
			Now:           fixedClock(testNow),
		})
		if err != nil {
			t.Fatalf("construct service: %v", err)
		}
		req := baseRequest(subject)
		req.Exception = validException(t, req, alice, bob)
		if _, err := svc.Erase(context.Background(), req); !errors.Is(err, ErrOperatorLacksCapability) {
			t.Fatalf("a registered operator without the override capability was accepted: %v", err)
		}
	})
}

// TestOverrideSignatureIsBoundToEveryMaterialField is the replay and substitution suite.
//
// Each case changes ONE signed field WITHOUT re-signing, so a signature that is not bound to that
// field would still verify. The test therefore proves what the canonical message actually covers,
// rather than proving that signing and verifying agree with each other.
func TestOverrideSignatureIsBoundToEveryMaterialField(t *testing.T) {
	alice := newTestOperator(t, "op-alice")
	bob := newTestOperator(t, "op-bob")

	for name, mutate := range map[string]func(*RetentionException){
		"subject substituted": func(e *RetentionException) { e.SubjectID = "actor-someone-else" },
		"tenant substituted":  func(e *RetentionException) { e.TenantID = "tenant-b" },
		"ground substituted":  func(e *RetentionException) { e.Ground = GroundPublicHealth },
		"expiry extended":     func(e *RetentionException) { e.ExpiresAt = testNow.Add(48 * time.Hour) },
		"review date moved":   func(e *RetentionException) { e.ReviewBy = testNow.Add(time.Hour) },
		"issue date moved":    func(e *RetentionException) { e.IssuedAt = testNow.Add(-time.Hour) },
		"request replayed":    func(e *RetentionException) { e.RequestID = "req-002" },
		"signature bit flipped": func(e *RetentionException) {
			e.Approvals[0].Signature[0] ^= 0x01
		},
		"approval re-labelled to another operator": func(e *RetentionException) {
			// alice's signature bytes, presented as bob's approval. Verification uses bob's public
			// key, and the operator ID is itself inside the signed message, so this must fail twice
			// over.
			e.Approvals[0].OperatorID = "op-bob"
			e.Approvals[1].OperatorID = "op-alice"
		},
		"truncated signature": func(e *RetentionException) {
			e.Approvals[0].Signature = e.Approvals[0].Signature[:ed25519.SignatureSize-1]
		},
		"empty operator id": func(e *RetentionException) { e.Approvals[0].OperatorID = "" },
	} {
		t.Run(name, func(t *testing.T) {
			err := overrideCase(t, func(e *RetentionException, _, _ testOperator) { mutate(e) }, alice, bob)
			if err == nil {
				t.Fatalf("mutation %q was ACCEPTED; the signature is not bound to that field", name)
			}
			// It must fail as an override problem, never as a success or an unrelated panic.
			if errors.Is(err, ErrLegalHold) {
				t.Fatalf("mutation %q produced a plain legal-hold refusal, so the override was never evaluated", name)
			}
		})
	}
}

// TestOverrideCanonicalMessageIsDeterministicAndUnambiguous guards the encoding itself.
func TestOverrideCanonicalMessageIsDeterministicAndUnambiguous(t *testing.T) {
	e := RetentionException{
		SubjectID: "ab", TenantID: "c", Ground: GroundLegalClaims, RequestID: "r",
		IssuedAt: testNow, ExpiresAt: testNow.Add(time.Hour), ReviewBy: testNow.Add(time.Minute),
	}
	first := signingMessage(e, "op")
	second := signingMessage(e, "op")
	if string(first) != string(second) {
		t.Fatal("the canonical signing message is not deterministic across calls")
	}

	// Field-boundary ambiguity: ("ab","c") and ("a","bc") must not produce identical bytes. Plain
	// concatenation would collide here, and a colliding encoding lets a signature over one
	// exception verify against a different one.
	shifted := e
	shifted.SubjectID, shifted.TenantID = "a", "bc"
	if string(signingMessage(shifted, "op")) == string(first) {
		t.Fatal("field-boundary collision: two different exceptions produce the same signing message")
	}

	// Domain separation: the message must carry the package's own prefix so a signature produced
	// for a DSSE attestation or an agent-nono envelope cannot be presented here.
	if !containsSub(string(first), exceptionDomainPrefix) {
		t.Fatalf("the signing message is not domain-separated; it lacks %q", exceptionDomainPrefix)
	}
}

// =============================================================================================
// TIME-BOUNDED, ENUMERATED-GROUND EXCEPTION RECORDS
// =============================================================================================

func TestRetentionExceptionMustBeTimeBounded(t *testing.T) {
	alice := newTestOperator(t, "op-alice")
	bob := newTestOperator(t, "op-bob")

	cases := map[string]struct {
		mutate func(*RetentionException)
		want   error
	}{
		"no expiry at all": {
			mutate: func(e *RetentionException) { e.ExpiresAt = time.Time{} },
			want:   ErrExceptionNotTimeBounded,
		},
		"expiry already past": {
			mutate: func(e *RetentionException) {
				e.IssuedAt = testNow.Add(-2 * time.Hour)
				e.ExpiresAt = testNow.Add(-time.Hour)
				e.ReviewBy = testNow.Add(-90 * time.Minute)
			},
			want: ErrExceptionNotTimeBounded,
		},
		"expiry exactly now is exclusive": {
			mutate: func(e *RetentionException) {
				e.ExpiresAt = testNow
				e.ReviewBy = testNow.Add(-time.Minute)
			},
			want: ErrExceptionNotTimeBounded,
		},
		"effectively permanent": {
			mutate: func(e *RetentionException) {
				e.ExpiresAt = e.IssuedAt.Add(MaxExceptionValidity + time.Hour)
				e.ReviewBy = testNow.Add(time.Hour)
			},
			want: ErrExceptionNotTimeBounded,
		},
		"no review date": {
			mutate: func(e *RetentionException) { e.ReviewBy = time.Time{} },
			want:   ErrExceptionNotTimeBounded,
		},
		"review scheduled after expiry": {
			mutate: func(e *RetentionException) { e.ReviewBy = e.ExpiresAt.Add(time.Hour) },
			want:   ErrExceptionNotTimeBounded,
		},
		"expiry not after issue": {
			mutate: func(e *RetentionException) {
				e.ExpiresAt = e.IssuedAt
				e.ReviewBy = e.IssuedAt
			},
			want: ErrExceptionNotTimeBounded,
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			err := overrideCase(t, func(e *RetentionException, a, b testOperator) {
				tc.mutate(e)
				resign(t, e, a, b) // re-signed, so this fails on the RULE not on the signature
			}, alice, bob)
			if !errors.Is(err, tc.want) {
				t.Fatalf("want %v, got %v", tc.want, err)
			}
		})
	}
}

// TestRetentionExceptionAtMaxValidityIsAccepted is the discriminating pair for
// "effectively permanent" above.
//
// Without it, a change that rejected EVERY exception would leave the whole block green. A boundary
// test that only exercises the rejecting side passes for an unconditional rejection.
func TestRetentionExceptionAtMaxValidityIsAccepted(t *testing.T) {
	alice := newTestOperator(t, "op-alice")
	bob := newTestOperator(t, "op-bob")
	const subject = "actor-contained"

	seq := &sequenceRecorder{}
	fx := newServiceFixture(t, availableSource(seq, containmentHold(subject)), seq, alice, bob)
	req := baseRequest(subject)
	e := validException(t, req, alice, bob)
	e.IssuedAt = testNow.Add(-time.Minute)
	e.ExpiresAt = e.IssuedAt.Add(MaxExceptionValidity) // exactly at the ceiling
	e.ReviewBy = e.ExpiresAt
	resign(t, e, alice, bob)
	req.Exception = e

	if _, err := fx.svc.Erase(context.Background(), req); err != nil {
		t.Fatalf("an exception exactly at MaxExceptionValidity was refused: %v", err)
	}
}

func TestRetentionExceptionMustNameAnEnumeratedGround(t *testing.T) {
	alice := newTestOperator(t, "op-alice")
	bob := newTestOperator(t, "op-bob")

	for name, ground := range map[string]LegalGround{
		"empty ground":                 "",
		"free-form justification":      "ongoing internal investigation",
		"plausible but unenumerated":   "art17_3_f_business_need",
		"a valid-looking article name": "Article 17(3)(e)",
	} {
		t.Run(name, func(t *testing.T) {
			err := overrideCase(t, func(e *RetentionException, a, b testOperator) {
				e.Ground = ground
				resign(t, e, a, b)
			}, alice, bob)
			if !errors.Is(err, ErrUnenumeratedGround) {
				t.Fatalf("ground %q was accepted; free-form overrides are not refused: %v", ground, err)
			}
		})
	}

	// Every enumerated ground must be accepted. Without this, a validator that rejected everything
	// would pass the whole block above.
	for _, ground := range AllLegalGrounds {
		t.Run("accepts "+string(ground), func(t *testing.T) {
			const subject = "actor-contained"
			seq := &sequenceRecorder{}
			fx := newServiceFixture(t, availableSource(seq, containmentHold(subject)), seq, alice, bob)
			req := baseRequest(subject)
			e := validException(t, req, alice, bob)
			e.Ground = ground
			resign(t, e, alice, bob)
			req.Exception = e
			if _, err := fx.svc.Erase(context.Background(), req); err != nil {
				t.Fatalf("enumerated ground %q was refused: %v", ground, err)
			}
		})
	}
}

// TestRetentionExceptionMustBeBoundToThisRequest covers replay across subject, tenant and request.
//
// These differ from the signature-binding tests above: here the exception is correctly re-signed
// for its own contents, so the signature verifies. Only the explicit binding check refuses it.
func TestRetentionExceptionMustBeBoundToThisRequest(t *testing.T) {
	alice := newTestOperator(t, "op-alice")
	bob := newTestOperator(t, "op-bob")

	for name, mutate := range map[string]func(*RetentionException){
		"granted for a different subject": func(e *RetentionException) { e.SubjectID = "actor-other" },
		"granted for a different tenant":  func(e *RetentionException) { e.TenantID = "tenant-b" },
		"granted for a different request": func(e *RetentionException) { e.RequestID = "req-999" },
		"empty subject":                   func(e *RetentionException) { e.SubjectID = "" },
		"empty tenant":                    func(e *RetentionException) { e.TenantID = "" },
		"empty request id":                func(e *RetentionException) { e.RequestID = "" },
	} {
		t.Run(name, func(t *testing.T) {
			err := overrideCase(t, func(e *RetentionException, a, b testOperator) {
				mutate(e)
				resign(t, e, a, b) // validly signed for its own contents
			}, alice, bob)
			if err == nil {
				t.Fatalf("%s was accepted; an override may be replayed", name)
			}
			if !errors.Is(err, ErrExceptionMismatch) {
				t.Fatalf("want ErrExceptionMismatch, got %v", err)
			}
		})
	}
}

// containsSub is a tiny local helper so this file does not import strings for one call.
func containsSub(haystack, needle string) bool {
	return len(needle) == 0 || len(haystack) >= len(needle) && indexOfSub(haystack, needle) >= 0
}

func indexOfSub(haystack, needle string) int {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return i
		}
	}
	return -1
}
