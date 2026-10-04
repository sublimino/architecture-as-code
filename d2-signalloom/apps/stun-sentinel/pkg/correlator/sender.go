// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Sender constants
const (
	DefaultBatchMax            = 100
	DefaultBatchLinger         = 250 * time.Millisecond
	DefaultRetryAfterCap       = 300 * time.Second
	minBackoff                 = 1 * time.Second
	maxBackoff                 = 30 * time.Second
	HeaderSignalLoomBatchEpoch = "X-SignalLoom-Batch-Epoch"
	HeaderSignalLoomBatchSeq   = "X-SignalLoom-Batch-Seq"
	HeaderSignalLoomBatchPrev  = "X-SignalLoom-Batch-Prev"
)

type dispatchResult int

const (
	resultSuccess dispatchResult = iota
	resultAuthRefused
	resultRejected
	resultRateLimited
	resultRetryableError
)

// Sender executes single-goroutine ordered batching, D10 chain stamping, and crash-safe spool replay.
type Sender struct {
	m           *SentinelProbeManager
	epoch       string
	seq         uint64
	lastPrev    string
	spool       *Spool
	batchMax    int
	batchLinger time.Duration
	clock       Clock
	client      *http.Client
	ingestURL   string
	bearerToken string
	// tokenSource, when set, is asked for the bearer at every post; an empty
	// answer means "not yet": spool, do not drop (WithBearerTokenSource).
	tokenSource func() string
	stats       *pipelineStats

	batchBuf []TelemetryObservation
	backoff  time.Duration
	mu       sync.Mutex
}

func newSender(m *SentinelProbeManager, spool *Spool, batchMax int, batchLinger time.Duration, clk Clock) *Sender {
	if batchMax <= 0 {
		batchMax = DefaultBatchMax
	}
	if batchLinger <= 0 {
		batchLinger = DefaultBatchLinger
	}
	if clk == nil {
		clk = realClock{}
	}

	return &Sender{
		m:           m,
		epoch:       generateEpoch(),
		seq:         0,
		lastPrev:    "",
		spool:       spool,
		batchMax:    batchMax,
		batchLinger: batchLinger,
		clock:       clk,
		client:      m.httpClient,
		ingestURL:   m.ingestURL,
		bearerToken: m.bearerToken,
		tokenSource: m.tokenSource,
		stats:       &m.stats,
		backoff:     minBackoff,
	}
}

// token is the bearer to post with now. See SentinelProbeManager.token.
func (s *Sender) token() string {
	if s.bearerToken != "" {
		return s.bearerToken
	}
	if s.tokenSource != nil {
		return strings.TrimSpace(s.tokenSource())
	}
	return ""
}

// awaitingToken reports a token source that has not produced a key yet:
// batches are spooled until it does.
func (s *Sender) awaitingToken() bool {
	return s.bearerToken == "" && s.tokenSource != nil && s.tokenSource() == ""
}

func generateEpoch() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		// fallback using timestamp and pid
		now := time.Now().UnixNano()
		for i := 0; i < 8; i++ {
			b[i] = byte(now >> (i * 8))
		}
	}
	return hex.EncodeToString(b[:])
}

// run executes the single sender loop.
func (s *Sender) run(ctx context.Context) {
	defer s.m.wg.Done()

	var lingerTimerChan <-chan time.Time
	var retryTimerChan <-chan time.Time

	for {
		// If spool has pending batches, drain spool head-first before processing memory queue
		s.drainSpool(ctx)

		// If spool still has pending batches, ensure retry timer is active so we wake up and retry
		if batches, _ := s.spool.ListBatches(); len(batches) > 0 && retryTimerChan == nil {
			retryTimerChan = s.clock.After(s.backoff)
		}

		select {
		case <-ctx.Done():
			s.flushCurrentBatch(ctx, true)
			return

		case <-retryTimerChan:
			retryTimerChan = nil
			s.drainSpool(ctx)

		case obs, ok := <-s.m.queue:
			if !ok {
				s.flushCurrentBatch(ctx, true)
				return
			}

			// 1. logObservation is called FIRST: stdout ebpf_detection is independent of delivery
			logObservation(obs)

			// 2. No bearer and no source that could produce one: count missing
			// and drop (never spool what can never be sent). A source that has
			// not answered yet is different: the batch is spooled below.
			if s.token() == "" && !s.awaitingToken() {
				s.stats.ingestTokenMissing.Add(1)
				continue
			}

			s.batchBuf = append(s.batchBuf, obs)

			if len(s.batchBuf) == 1 {
				lingerTimerChan = s.clock.After(s.batchLinger)
			}

			if len(s.batchBuf) >= s.batchMax {
				s.flushCurrentBatch(ctx, false)
				lingerTimerChan = nil
			}

		case <-lingerTimerChan:
			if len(s.batchBuf) > 0 {
				s.flushCurrentBatch(ctx, false)
			}
			lingerTimerChan = nil
		}
	}
}

func (s *Sender) flushCurrentBatch(ctx context.Context, shutdown bool) {
	if len(s.batchBuf) == 0 {
		return
	}

	obsList := make([]ingestObservation, len(s.batchBuf))
	for i, obs := range s.batchBuf {
		obsList[i] = obs.toIngest()
	}
	s.batchBuf = nil

	bodyBytes, err := json.Marshal(obsList)
	if err != nil {
		return
	}

	s.seq++
	env := SpoolEnvelope{
		V:       1,
		Epoch:   s.epoch,
		Seq:     s.seq,
		Prev:    s.lastPrev,
		Created: s.clock.Now().UTC().Format(time.RFC3339Nano),
		Body:    json.RawMessage(bodyBytes),
	}

	// Update lastPrev to hex sha256 of the exact wire body bytes
	sum := sha256.Sum256(bodyBytes)
	s.lastPrev = hex.EncodeToString(sum[:])

	// Check if on-disk spool is non-empty. A key that has not arrived yet
	// also spools: the batch waits on disk, in order, for the key.
	spoolBatches, _ := s.spool.ListBatches()
	if len(spoolBatches) > 0 || shutdown || s.awaitingToken() {
		// Non-empty spool or shutdown: append to spool tail to preserve strict FIFO order
		_, _ = s.spool.WriteBatch(env)
		return
	}

	// Spool is empty: attempt live direct dispatch
	res, waitDur, err := s.sendEnvelope(ctx, env)
	switch res {
	case resultSuccess:
		s.stats.dispatchOK.Add(1)
		s.backoff = minBackoff

	case resultAuthRefused:
		s.stats.dispatchAuthRefused.Add(1)
		logAuthRefused(env.Epoch, env.Seq, s.token(), err)
		s.backoff = minBackoff

	case resultRejected:
		s.stats.dispatchRejected.Add(1)
		logDispatchRejected(env.Epoch, env.Seq, err)
		s.backoff = minBackoff

	case resultRateLimited:
		// Write to spool and enter rate-limited pause
		_, _ = s.spool.WriteBatch(env)
		s.stats.retryAfterWaits.Add(1)
		s.clock.Sleep(waitDur)

	case resultRetryableError:
		// Network error / timeout / 5xx: write to spool and enter backoff
		_, _ = s.spool.WriteBatch(env)
		s.stats.dispatchErrors.Add(1)
		s.m.recordDispatch(err)
		s.applyBackoff(ctx)
	}
}

func (s *Sender) drainSpool(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		if s.awaitingToken() {
			return // the spool waits for the key; the retry timer re-checks
		}

		batches, err := s.spool.ListBatches()
		if err != nil || len(batches) == 0 {
			return
		}

		head := batches[0]
		res, waitDur, err := s.sendEnvelope(ctx, head.Envelope)
		switch res {
		case resultSuccess:
			_ = s.spool.DeleteBatch(head.Path)
			s.stats.spoolReplayed.Add(1)
			s.stats.dispatchOK.Add(1)
			s.backoff = minBackoff

		case resultAuthRefused:
			// Bad auth: delete spooled batch, do not retry
			_ = s.spool.DeleteBatch(head.Path)
			s.stats.dispatchAuthRefused.Add(1)
			logAuthRefused(head.Envelope.Epoch, head.Envelope.Seq, s.token(), err)
			s.backoff = minBackoff

		case resultRejected:
			// Poison / client 4xx: delete spooled batch, do not retry
			_ = s.spool.DeleteBatch(head.Path)
			s.stats.dispatchRejected.Add(1)
			logDispatchRejected(head.Envelope.Epoch, head.Envelope.Seq, err)
			s.backoff = minBackoff

		case resultRateLimited:
			s.stats.retryAfterWaits.Add(1)
			s.clock.Sleep(waitDur)
			return

		case resultRetryableError:
			s.stats.dispatchErrors.Add(1)
			s.m.recordDispatch(err)
			s.applyBackoff(ctx)
			return
		}
	}
}

func (s *Sender) sendEnvelope(ctx context.Context, env SpoolEnvelope) (dispatchResult, time.Duration, error) {
	token := s.token()
	if token == "" {
		return resultAuthRefused, 0, ErrIngestTokenMissing
	}

	url := strings.TrimRight(s.ingestURL, "/") + "/api/v1/observations"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(env.Body))
	if err != nil {
		return resultRetryableError, 0, err
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set(HeaderSignalLoomBatchEpoch, env.Epoch)
	req.Header.Set(HeaderSignalLoomBatchSeq, strconv.FormatUint(env.Seq, 10))
	req.Header.Set(HeaderSignalLoomBatchPrev, env.Prev)

	resp, err := s.client.Do(req)
	if err != nil {
		return resultRetryableError, 0, err
	}
	defer resp.Body.Close()

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return resultSuccess, 0, nil

	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return resultAuthRefused, 0, fmt.Errorf("signal-ingest auth refused: HTTP status %d", resp.StatusCode)

	case resp.StatusCode == http.StatusTooManyRequests:
		retryAfter := parseRetryAfter(resp.Header.Get("Retry-After"), s.clock)
		if retryAfter <= 0 {
			retryAfter = s.backoff
		}
		return resultRateLimited, retryAfter, fmt.Errorf("signal-ingest rate limited: HTTP status 429")

	case resp.StatusCode >= 400 && resp.StatusCode < 500:
		return resultRejected, 0, fmt.Errorf("signal-ingest client error: HTTP status %d", resp.StatusCode)

	default:
		return resultRetryableError, 0, fmt.Errorf("signal-ingest server error: HTTP status %d", resp.StatusCode)
	}
}

func parseRetryAfter(header string, clk Clock) time.Duration {
	header = strings.TrimSpace(header)
	if header == "" {
		return 0
	}

	// 1. Try parsing as integer seconds
	if sec, err := strconv.Atoi(header); err == nil {
		d := time.Duration(sec) * time.Second
		if d > DefaultRetryAfterCap {
			d = DefaultRetryAfterCap
		}
		return d
	}

	// 2. Try parsing as HTTP Date (RFC 1123 / RFC 850 / ANSIC)
	if t, err := http.ParseTime(header); err == nil {
		d := t.Sub(clk.Now())
		if d < 0 {
			return 0
		}
		if d > DefaultRetryAfterCap {
			d = DefaultRetryAfterCap
		}
		return d
	}

	return 0
}

func (s *Sender) applyBackoff(ctx context.Context) {
	d := s.backoff
	s.backoff *= 2
	if s.backoff > maxBackoff {
		s.backoff = maxBackoff
	}
	s.clock.Sleep(d)
}

func logAuthRefused(epoch string, seq uint64, token string, err error) {
	keyName := "configured-bearer"
	if len(token) > 8 {
		keyName = token[:8] + "..."
	}
	writeCorrelatorEvent(correlatorEvent{
		Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
		Event:     "dispatch_auth_refused",
		Error:     fmt.Sprintf("auth refused for key %s (epoch=%s seq=%d): %v", keyName, epoch, seq, err),
	})
}

func logDispatchRejected(epoch string, seq uint64, err error) {
	writeCorrelatorEvent(correlatorEvent{
		Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
		Event:     "dispatch_rejected",
		Error:     fmt.Sprintf("dispatch rejected (epoch=%s seq=%d): %v", epoch, seq, err),
	})
}
