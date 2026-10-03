// Package api provides batch chain verification and state tracking for Signal Loom ingestion.
package api

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"math"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

const (
	// HeaderBatchEpoch identifies the random sender start epoch.
	HeaderBatchEpoch = "X-SignalLoom-Batch-Epoch"
	// HeaderBatchSeq identifies the monotonically increasing 1-based sequence number within the epoch.
	HeaderBatchSeq = "X-SignalLoom-Batch-Seq"
	// HeaderBatchPrev carries the lowercase hex SHA-256 digest of the preceding batch body (empty for seq 1).
	HeaderBatchPrev = "X-SignalLoom-Batch-Prev"

	// DefaultMaxEpochsPerSubject bounds the number of concurrent epochs tracked per authenticated sender subject.
	DefaultMaxEpochsPerSubject = 8

	// DefaultWindowSizePerEpoch bounds the sequence-to-digest tracking window per epoch.
	DefaultWindowSizePerEpoch = 1024

	// DefaultMaxBodyBytes bounds the request body size before buffering and digest computation (4 MiB).
	DefaultMaxBodyBytes = 4 * 1024 * 1024

	// Outcome classification constants.
	OutcomeEpochStarted = "epoch_started"
	OutcomeResumed      = "resumed"
	OutcomeContiguous   = "contiguous"
	OutcomeBroken       = "broken"
	OutcomeGap          = "gap"
	OutcomeReordered    = "reordered"
	OutcomeReplayed     = "replayed"
	OutcomeConflict     = "conflict"
	OutcomeUnchained    = "unchained"
)

var (
	ErrPartialChainHeaders = errors.New("partial batch chain headers: all three headers must be present or all three absent")
	ErrInvalidEpoch        = errors.New("epoch must be 32 lowercase hex characters")
	ErrInvalidSeq          = errors.New("seq must be a positive integer in range 1..2^63-1")
	ErrInvalidPrev         = errors.New("prev must be 64 lowercase hex characters")
	ErrPrevNonEmptyAtSeq1  = errors.New("prev must be empty at seq 1")
)

// BatchChainHeaders holds parsed and validated batch chain headers.
type BatchChainHeaders struct {
	Epoch string
	Seq   uint64
	Prev  string
}

// BatchChainDetail represents the structured detail payload written to signal_audit_trail.
type BatchChainDetail struct {
	Outcome     string `json:"outcome"`
	Subject     string `json:"subject"`
	Epoch       string `json:"epoch,omitempty"`
	Seq         uint64 `json:"seq,omitempty"`
	ExpectedSeq uint64 `json:"expected_seq,omitempty"`
	PrevMatches *bool  `json:"prev_matches,omitempty"`
	MissingFrom uint64 `json:"missing_from,omitempty"`
	MissingTo   uint64 `json:"missing_to,omitempty"`
}

// Classification holds the classification verdict and prepared audit detail.
type Classification struct {
	Outcome string
	Detail  BatchChainDetail
}

// parseChainHeaders extracts and validates D10 chain headers from an HTTP request.
// Returns (nil, nil) for unchained requests (all 3 headers absent).
// Returns error if partial headers are provided or any header value is malformed.
func parseChainHeaders(r *http.Request) (*BatchChainHeaders, error) {
	epochVals := r.Header.Values(HeaderBatchEpoch)
	seqVals := r.Header.Values(HeaderBatchSeq)
	prevVals := r.Header.Values(HeaderBatchPrev)

	hasEpoch := len(epochVals) > 0
	hasSeq := len(seqVals) > 0
	hasPrev := len(prevVals) > 0

	// Unchained sender: all three absent
	if !hasEpoch && !hasSeq && !hasPrev {
		return nil, nil
	}

	// Partial headers: one or two present
	if !hasEpoch || !hasSeq || !hasPrev {
		return nil, ErrPartialChainHeaders
	}

	// Exactly one value per header
	if len(epochVals) != 1 || len(seqVals) != 1 || len(prevVals) != 1 {
		return nil, errors.New("multiple values for batch chain header")
	}

	epoch := epochVals[0]
	seqStr := seqVals[0]
	prev := prevVals[0]

	// Validate epoch: 32 lowercase hex characters
	if len(epoch) != 32 || !isLowerHex(epoch) {
		return nil, ErrInvalidEpoch
	}

	// Validate seq: positive integer in range 1..2^63-1
	seq, err := strconv.ParseUint(seqStr, 10, 64)
	if err != nil || seq < 1 || seq > math.MaxInt64 {
		return nil, ErrInvalidSeq
	}

	// Validate prev: empty for seq 1, 64 lowercase hex for seq > 1
	if seq == 1 {
		if prev != "" {
			return nil, ErrPrevNonEmptyAtSeq1
		}
	} else {
		if len(prev) != 64 || !isLowerHex(prev) {
			return nil, ErrInvalidPrev
		}
	}

	return &BatchChainHeaders{
		Epoch: epoch,
		Seq:   seq,
		Prev:  prev,
	}, nil
}

func isLowerHex(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

func getMaxBodyBytes() int64 {
	if v := os.Getenv("SIGNAL_INGEST_MAX_BODY_BYTES"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			return n
		}
	}
	return DefaultMaxBodyBytes
}

func computeBodyDigest(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

type epochEntry struct {
	epoch      string
	lastSeq    uint64
	lastDigest string
	window     map[uint64]string
	windowKeys []uint64
	lastSeen   time.Time
}

type subjectState struct {
	epochs             map[string]*epochEntry
	epochLRU           []string // oldest at 0, newest at end
	lastUnchainedAudit time.Time
}

// BatchChainTracker maintains bounded, thread-safe sequence and hash chain state per sender subject.
type BatchChainTracker struct {
	mu        sync.Mutex
	maxEpochs int
	maxWindow int
	subjects  map[string]*subjectState
	nowFunc   func() time.Time
}

// NewBatchChainTracker creates a new tracker with bounded LRU capacities.
func NewBatchChainTracker(maxEpochs, maxWindow int) *BatchChainTracker {
	if maxEpochs <= 0 {
		maxEpochs = DefaultMaxEpochsPerSubject
	}
	if maxWindow <= 0 {
		maxWindow = DefaultWindowSizePerEpoch
	}
	return &BatchChainTracker{
		maxEpochs: maxEpochs,
		maxWindow: maxWindow,
		subjects:  make(map[string]*subjectState),
		nowFunc:   time.Now,
	}
}

// Classify inspects incoming batch headers and body digest against the recorded chain state for subject.
func (t *BatchChainTracker) Classify(subject string, headers *BatchChainHeaders, digest string) Classification {
	t.mu.Lock()
	defer t.mu.Unlock()

	s, exists := t.subjects[subject]
	if !exists {
		s = &subjectState{epochs: make(map[string]*epochEntry)}
		t.subjects[subject] = s
	}

	ep, found := s.epochs[headers.Epoch]
	if !found {
		if headers.Seq == 1 {
			bTrue := true
			return Classification{
				Outcome: OutcomeEpochStarted,
				Detail: BatchChainDetail{
					Outcome:     OutcomeEpochStarted,
					Subject:     subject,
					Epoch:       headers.Epoch,
					Seq:         headers.Seq,
					ExpectedSeq: 1,
					PrevMatches: &bTrue,
				},
			}
		}
		// Ingest restart or fresh process with unseen epoch at seq > 1: resumed
		bTrue := true
		return Classification{
			Outcome: OutcomeResumed,
			Detail: BatchChainDetail{
				Outcome:     OutcomeResumed,
				Subject:     subject,
				Epoch:       headers.Epoch,
				Seq:         headers.Seq,
				ExpectedSeq: headers.Seq,
				PrevMatches: &bTrue,
			},
		}
	}

	lastSeq := ep.lastSeq
	lastDigest := ep.lastDigest

	if headers.Seq == lastSeq+1 {
		if headers.Prev == lastDigest {
			bTrue := true
			return Classification{
				Outcome: OutcomeContiguous,
				Detail: BatchChainDetail{
					Outcome:     OutcomeContiguous,
					Subject:     subject,
					Epoch:       headers.Epoch,
					Seq:         headers.Seq,
					ExpectedSeq: lastSeq + 1,
					PrevMatches: &bTrue,
				},
			}
		}
		bFalse := false
		return Classification{
			Outcome: OutcomeBroken,
			Detail: BatchChainDetail{
				Outcome:     OutcomeBroken,
				Subject:     subject,
				Epoch:       headers.Epoch,
				Seq:         headers.Seq,
				ExpectedSeq: lastSeq + 1,
				PrevMatches: &bFalse,
			},
		}
	}

	if headers.Seq > lastSeq+1 {
		prevMatches := (headers.Prev == lastDigest)
		return Classification{
			Outcome: OutcomeGap,
			Detail: BatchChainDetail{
				Outcome:     OutcomeGap,
				Subject:     subject,
				Epoch:       headers.Epoch,
				Seq:         headers.Seq,
				ExpectedSeq: lastSeq + 1,
				PrevMatches: &prevMatches,
				MissingFrom: lastSeq + 1,
				MissingTo:   headers.Seq - 1,
			},
		}
	}

	// headers.Seq <= lastSeq
	if recordedDigest, seen := ep.window[headers.Seq]; seen {
		if recordedDigest == digest {
			bTrue := true
			return Classification{
				Outcome: OutcomeReplayed,
				Detail: BatchChainDetail{
					Outcome:     OutcomeReplayed,
					Subject:     subject,
					Epoch:       headers.Epoch,
					Seq:         headers.Seq,
					ExpectedSeq: headers.Seq,
					PrevMatches: &bTrue,
				},
			}
		}
		bFalse := false
		return Classification{
			Outcome: OutcomeConflict,
			Detail: BatchChainDetail{
				Outcome:     OutcomeConflict,
				Subject:     subject,
				Epoch:       headers.Epoch,
				Seq:         headers.Seq,
				ExpectedSeq: headers.Seq,
				PrevMatches: &bFalse,
			},
		}
	}

	// Seq was not seen in window (late/reordered arrival)
	var prevMatches *bool
	if headers.Seq == 1 {
		b := (headers.Prev == "")
		prevMatches = &b
	} else if pDig, ok := ep.window[headers.Seq-1]; ok {
		b := (headers.Prev == pDig)
		prevMatches = &b
	}

	return Classification{
		Outcome: OutcomeReordered,
		Detail: BatchChainDetail{
			Outcome:     OutcomeReordered,
			Subject:     subject,
			Epoch:       headers.Epoch,
			Seq:         headers.Seq,
			ExpectedSeq: lastSeq + 1,
			PrevMatches: prevMatches,
		},
	}
}

// Advance records successful batch storage and updates the sequence and digest chain.
func (t *BatchChainTracker) Advance(subject string, headers *BatchChainHeaders, digest string, outcome string) {
	t.mu.Lock()
	defer t.mu.Unlock()

	s, exists := t.subjects[subject]
	if !exists {
		s = &subjectState{epochs: make(map[string]*epochEntry)}
		t.subjects[subject] = s
	}

	ep, found := s.epochs[headers.Epoch]
	if !found {
		// Evict oldest epoch if capacity exceeded
		for len(s.epochs) >= t.maxEpochs && len(s.epochLRU) > 0 {
			oldest := s.epochLRU[0]
			s.epochLRU = s.epochLRU[1:]
			delete(s.epochs, oldest)
		}

		ep = &epochEntry{
			epoch:      headers.Epoch,
			lastSeq:    headers.Seq,
			lastDigest: digest,
			window:     make(map[uint64]string),
			windowKeys: make([]uint64, 0, t.maxWindow),
			lastSeen:   t.nowFunc(),
		}
		ep.window[headers.Seq] = digest
		ep.windowKeys = append(ep.windowKeys, headers.Seq)
		s.epochs[headers.Epoch] = ep
		s.epochLRU = append(s.epochLRU, headers.Epoch)
		return
	}

	// Move epoch to most-recently-used position in LRU list
	for i, name := range s.epochLRU {
		if name == headers.Epoch {
			s.epochLRU = append(s.epochLRU[:i], s.epochLRU[i+1:]...)
			break
		}
	}
	s.epochLRU = append(s.epochLRU, headers.Epoch)
	ep.lastSeen = t.nowFunc()

	if outcome == OutcomeReordered {
		ep.window[headers.Seq] = digest
		ep.windowKeys = append(ep.windowKeys, headers.Seq)
	} else if outcome != OutcomeReplayed {
		if headers.Seq >= ep.lastSeq {
			ep.lastSeq = headers.Seq
			ep.lastDigest = digest
		}
		ep.window[headers.Seq] = digest
		ep.windowKeys = append(ep.windowKeys, headers.Seq)
	}

	// Enforce window cap
	for len(ep.windowKeys) > t.maxWindow {
		oldestSeq := ep.windowKeys[0]
		ep.windowKeys = ep.windowKeys[1:]
		delete(ep.window, oldestSeq)
	}
}

// ShouldAuditUnchained returns true if an unchained audit event should be emitted (first per subject per hour).
func (t *BatchChainTracker) ShouldAuditUnchained(subject string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()

	s, ok := t.subjects[subject]
	if !ok {
		s = &subjectState{epochs: make(map[string]*epochEntry)}
		t.subjects[subject] = s
	}

	now := t.nowFunc()
	if s.lastUnchainedAudit.IsZero() || now.Sub(s.lastUnchainedAudit) >= time.Hour {
		s.lastUnchainedAudit = now
		return true
	}
	return false
}
