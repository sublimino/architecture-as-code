// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
)

// ErrLiveClientsNotWired is returned when live mode is started with no AWS client
// set and no live client factory registered.
//
// The aws-sdk-go-v2 implementation of the three seams lives in the `live`
// subpackage, which registers itself through SetLiveClientFactory when it is linked
// in. A binary that does not import it has no live mode, and this error says so
// rather than running as a collector that silently collects nothing.
var ErrLiveClientsNotWired = errors.New("awslogs: no SQS/S3/STS client wired and no live client factory registered (import collectors/awslogs/live to enable live mode)")

// NotificationParser extracts the object references from one SQS message body.
//
// It is injectable because the live and fixture paths see genuinely different
// bodies. The default, objectRefsFrom, reads the direct S3 event notification that
// the fakes produce. A live account may fan out through SNS first and will post a
// one-off `s3:TestEvent` the day the bucket is wired up, neither of which the
// default understands — so the live factory supplies a parser that does.
//
// The three outcomes are distinct and the collector relies on all three: refs to
// fetch, nil/nil for "nothing here and nothing wrong", and an error to leave the
// message in flight for the queue's redrive policy.
type NotificationParser func(body string) ([]ObjectRef, error)

// LiveClientFactory builds the AWS seams for one collector configuration.
//
// This indirection exists because the dependency can only run one way: the `live`
// package imports this one for Message, ObjectRef, Credentials and
// ErrExternalIDRequired, so this one cannot import it back to call live.NewClients
// from Start. Keeping the SDK out of the core package is the point — fixture mode
// and every contract test build without it.
type LiveClientFactory func(ctx context.Context, cfg AWSCollectorConfig) (SQSClient, S3Fetcher, STSAssumer, NotificationParser, error)

var (
	liveFactoryMu sync.RWMutex
	liveFactory   LiveClientFactory
)

// SetLiveClientFactory registers the factory Start uses in live mode when no clients
// were injected with WithAWS. The `live` package calls this from its init.
//
// Explicitly injected clients always win, so a test driving the fakes is never at
// the mercy of whether some other package in the binary linked the SDK in.
func SetLiveClientFactory(f LiveClientFactory) {
	liveFactoryMu.Lock()
	defer liveFactoryMu.Unlock()
	liveFactory = f
}

// LiveClientFactoryRegistered reports whether a live client factory is available. It
// is what lets a test assert that the live wiring is linked in, rather than
// discovering at deployment that it is not.
func LiveClientFactoryRegistered() bool {
	liveFactoryMu.RLock()
	defer liveFactoryMu.RUnlock()
	return liveFactory != nil
}

func currentLiveFactory() LiveClientFactory {
	liveFactoryMu.RLock()
	defer liveFactoryMu.RUnlock()
	return liveFactory
}

// Collector polls an SQS queue for S3 object notifications, fetches each object,
// buffers it durably, projects it to the §2.3 label contract and acknowledges the
// queue only once the sink has accepted every observation.
type Collector struct {
	mu sync.Mutex
	// drainMu serialises Drain. Peek/Commit is deliberately not atomic as a pair, so
	// two concurrent drains would both Peek the same record, both ingest it (a
	// duplicate write) and both try to delete the message (the second failing with an
	// unknown receipt handle). The background poll loop and an explicit caller can
	// race exactly that way, so the drain is single-flighted here rather than making
	// the ring's lock span the sink and the network.
	drainMu sync.Mutex

	cfg  AWSCollectorConfig
	mode Mode
	sink Sink
	ring *DiskRingBuffer

	sqs    SQSClient
	s3     S3Fetcher
	sts    STSAssumer
	parser NotificationParser

	running    bool
	noPollLoop bool
	cancelFn   context.CancelFunc
	wg         sync.WaitGroup

	processed atomic.Uint64
	acked     atomic.Uint64
	errors    atomic.Uint64
	assumed   atomic.Uint64
}

// Option configures a Collector.
type Option func(*Collector)

// WithMode sets the operational mode. The string form keeps collectors.Mode out of
// this package's imports.
func WithMode(mode string) Option {
	return func(c *Collector) { c.mode = Mode(mode) }
}

// WithAWS injects the three AWS seams. Tests pass the awsfake implementations; the
// live card will pass aws-sdk-go-v2 ones.
func WithAWS(sqs SQSClient, s3 S3Fetcher, sts STSAssumer) Option {
	return func(c *Collector) {
		c.sqs = sqs
		c.s3 = s3
		c.sts = sts
	}
}

// WithNotificationParser overrides how an SQS message body is turned into object
// references. The default reads a direct S3 event notification; the live factory
// supplies one that also unwraps SNS and ignores s3:TestEvent.
func WithNotificationParser(parse NotificationParser) Option {
	return func(c *Collector) { c.parser = parse }
}

// WithoutPollLoop starts live mode without the background poll goroutine, leaving
// PollOnce and Drain to be called explicitly.
//
// This is a test seam and production never sets it. It exists because a background
// loop that drains on start races any explicit PollOnce, which makes an assertion on
// "how many records did THIS call acknowledge" nondeterministic — the loop may have
// already taken the work. The alternative is sleeping and hoping, which is how
// ordering tests become flaky and then get deleted.
func WithoutPollLoop() Option {
	return func(c *Collector) { c.noPollLoop = true }
}

// New builds a Collector. It does no I/O: the buffer directory is created by Start,
// and only in live mode, so an off-mode collector leaves no trace on the filesystem.
func New(cfg AWSCollectorConfig, sink Sink, opts ...Option) (*Collector, error) {
	c := &Collector{cfg: cfg.WithDefaults(), mode: ModeOff, sink: sink}
	for _, opt := range opts {
		opt(c)
	}
	if err := c.cfg.Validate(c.mode); err != nil {
		return nil, err
	}
	return c, nil
}

// Name returns the collector name used by the registry and the coverage guard.
func (c *Collector) Name() string { return "awslogs" }

// Mode returns the CONFIGURED mode. The v1 stub hard-coded ModeLive (§8), which made
// the mode gate decorative: an unconfigured deployment reported a live cloud
// collector that was in fact replaying fabricated records.
func (c *Collector) Mode() Mode { return c.mode }

// Config returns the effective configuration.
func (c *Collector) Config() AWSCollectorConfig { return c.cfg }

// Ring exposes the transport buffer for assertions. It is nil until live mode starts.
func (c *Collector) Ring() *DiskRingBuffer {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.ring
}

// Start brings the collector up for its configured mode.
//
//   - off: does nothing, touches nothing, spawns nothing.
//   - fixture: replays the embedded testdata objects into the sink synchronously and
//     returns any sink error, so a broken sink cannot be mistaken for an empty source.
//   - live: validates the trust configuration, assumes the role, opens the buffer and
//     starts the poll loop.
func (c *Collector) Start(ctx context.Context) error {
	c.mu.Lock()
	if c.running {
		c.mu.Unlock()
		return nil
	}

	switch c.mode {
	case ModeOff:
		c.mu.Unlock()
		return nil

	case ModeFixture:
		c.mu.Unlock()
		return c.replayFixtures(ctx)

	case ModeLive:
		if err := c.cfg.Validate(ModeLive); err != nil {
			c.mu.Unlock()
			return err
		}
		// Nothing injected: build the seams from the registered live factory. The
		// check is "all three absent" rather than "any absent" so that a test which
		// injects a partial set still gets ErrLiveClientsNotWired instead of having
		// the gaps quietly filled with clients that would dial AWS.
		if c.sqs == nil && c.s3 == nil && c.sts == nil {
			if err := c.buildLiveClients(ctx); err != nil {
				c.mu.Unlock()
				return err
			}
		}
		if c.sqs == nil || c.s3 == nil || c.sts == nil {
			c.mu.Unlock()
			return ErrLiveClientsNotWired
		}
		if _, err := c.assumeRole(ctx); err != nil {
			c.mu.Unlock()
			return err
		}

		ring, err := NewDiskRingBuffer(c.cfg.BufferDir, c.cfg.RingCapacity,
			WithEvictionSink(c.sink),
			WithEvictionTenant(c.cfg.TenantID),
			WithCompactThreshold(c.cfg.CompactThresholdBytes),
		)
		if err != nil {
			c.mu.Unlock()
			return err
		}
		c.ring = ring

		subCtx, cancel := context.WithCancel(ctx)
		c.cancelFn = cancel
		c.running = true
		if c.noPollLoop {
			c.mu.Unlock()
			return nil
		}
		c.wg.Add(1)
		c.mu.Unlock()

		go func() {
			defer c.wg.Done()
			c.pollLoop(subCtx)
		}()
		return nil

	default:
		c.mu.Unlock()
		return fmt.Errorf("awslogs: unknown mode %q", c.mode)
	}
}

// Stop halts the collector. It returns nothing, which is what satisfies
// collectors.Stopper — the v1 Stop() error did not (§8), so the registry's teardown
// never called it and a live collector leaked its goroutines on shutdown.
func (c *Collector) Stop() {
	c.mu.Lock()
	if !c.running {
		// Still release a buffer opened by a Start that never reached running.
		if c.ring != nil {
			if err := c.ring.Close(); err != nil {
				slog.Error("awslogs buffer close failed", "error", err)
			}
			c.ring = nil
		}
		c.mu.Unlock()
		return
	}
	cancel := c.cancelFn
	c.running = false
	c.cancelFn = nil
	c.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	c.wg.Wait()

	c.mu.Lock()
	ring := c.ring
	c.ring = nil
	c.mu.Unlock()

	if ring != nil {
		// Close compacts, so the unacknowledged records left in the buffer are exactly
		// what a restart will replay.
		if err := ring.Close(); err != nil {
			slog.Error("awslogs buffer close failed", "error", err)
		}
	}
}

// Health reports whether the live source is reachable. Off and fixture mode are
// always healthy; the registry only health-checks live collectors anyway.
func (c *Collector) Health(ctx context.Context) error {
	if c.mode != ModeLive {
		return nil
	}
	if c.sqs == nil || c.s3 == nil || c.sts == nil {
		return ErrLiveClientsNotWired
	}
	if _, err := c.assumeRole(ctx); err != nil {
		return fmt.Errorf("awslogs: cannot assume %s: %w", c.cfg.RoleARN, err)
	}
	return nil
}

// Stats returns ingestion counters.
func (c *Collector) Stats() map[string]uint64 {
	out := map[string]uint64{
		"processed_total":    c.processed.Load(),
		"acknowledged_total": c.acked.Load(),
		"errors_total":       c.errors.Load(),
		"assume_role_total":  c.assumed.Load(),
	}
	if ring := c.Ring(); ring != nil {
		out["dropped_total"] = ring.Dropped()
		out["buffered"] = uint64(ring.Len())
		out["compactions_total"] = ring.Compactions()
	}
	return out
}

// buildLiveClients populates the AWS seams from the registered live factory.
//
// The caller holds c.mu. A nil factory is not an error here: Start's own check turns
// it into ErrLiveClientsNotWired, which names the missing import rather than a
// missing factory variable.
func (c *Collector) buildLiveClients(ctx context.Context) error {
	factory := currentLiveFactory()
	if factory == nil {
		return nil
	}
	sqsClient, s3Client, stsClient, parse, err := factory(ctx, c.cfg)
	if err != nil {
		return fmt.Errorf("awslogs: building live AWS clients: %w", err)
	}
	c.sqs, c.s3, c.sts = sqsClient, s3Client, stsClient
	// An explicit WithNotificationParser still wins: the factory only fills a gap.
	if c.parser == nil {
		c.parser = parse
	}
	return nil
}

// parseNotification turns a message body into object references.
func (c *Collector) parseNotification(body string) ([]ObjectRef, error) {
	if c.parser != nil {
		return c.parser(body)
	}
	return objectRefsFrom(body)
}

func (c *Collector) assumeRole(ctx context.Context) (Credentials, error) {
	if c.cfg.ExternalID == "" {
		return Credentials{}, ErrMissingExternalID
	}
	creds, err := c.sts.AssumeRole(ctx, c.cfg.RoleARN, c.cfg.ExternalID)
	c.assumed.Add(1)
	if err != nil {
		return Credentials{}, fmt.Errorf("awslogs: assuming %s: %w", c.cfg.RoleARN, err)
	}
	return creds, nil
}

// projector returns the configured projector.
func (c *Collector) projector() Projector {
	return Projector{TenantID: c.cfg.TenantID, Region: c.cfg.Region}
}

// replayFixtures is the whole of fixture mode: project the embedded objects and
// ingest them. A sink error is returned rather than counted, matching every other
// collector's fixture path, so TestModeMatrix_NoSilentDowngrade holds here too.
func (c *Collector) replayFixtures(ctx context.Context) error {
	if c.sink == nil {
		return nil
	}
	obs, err := FixtureObservations(c.cfg.TenantID, c.cfg.Region)
	if err != nil {
		return err
	}
	for i := range obs {
		if err := c.sink.IngestObservation(ctx, &obs[i]); err != nil {
			return fmt.Errorf("awslogs fixture ingestion failed at observation %d: %w", i, err)
		}
		c.processed.Add(1)
	}
	return nil
}

func (c *Collector) pollLoop(ctx context.Context) {
	ticker := time.NewTicker(c.cfg.PollInterval)
	defer ticker.Stop()

	// Drain anything a previous process left buffered before taking new work, so a
	// restart clears its backlog rather than growing it.
	if _, err := c.Drain(ctx); err != nil && ctx.Err() == nil {
		c.errors.Add(1)
		slog.Error("awslogs backlog drain failed", "error", err)
	}

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if _, err := c.PollOnce(ctx); err != nil {
				if ctx.Err() != nil {
					return
				}
				c.errors.Add(1)
				slog.Error("awslogs poll failed", "error", err)
			}
		}
	}
}

// PollOnce performs one receive-fetch-buffer-drain cycle and returns the number of
// records acknowledged. It is exported so the ordering can be driven deterministically
// by a test instead of being inferred from a background loop.
func (c *Collector) PollOnce(ctx context.Context) (int, error) {
	ring := c.Ring()
	if ring == nil {
		return 0, errors.New("awslogs: PollOnce before Start opened the buffer")
	}

	msgs, err := c.sqs.ReceiveMessages(ctx, c.cfg.QueueURL, int32(c.cfg.MaxRecords))
	if err != nil {
		return 0, fmt.Errorf("awslogs: receiving from %s: %w", c.cfg.QueueURL, err)
	}

	for _, msg := range msgs {
		refs, err := c.parseNotification(msg.Body)
		if err != nil {
			// A message we cannot parse is left in flight deliberately: deleting it
			// would discard telemetry on the strength of our own parser being right,
			// and the queue's redrive policy is the correct place for a poison message.
			c.errors.Add(1)
			slog.Error("awslogs cannot parse notification; leaving it in flight", "message_id", msg.MessageID, "error", err)
			continue
		}
		for _, ref := range refs {
			body, err := c.s3.GetObject(ctx, ref)
			if err != nil {
				return 0, fmt.Errorf("awslogs: fetching s3://%s/%s: %w", ref.Bucket, ref.Key, err)
			}
			rec := &LogRecord{
				Timestamp:     time.Now().UTC(),
				TenantID:      c.cfg.TenantID,
				Bucket:        ref.Bucket,
				Key:           ref.Key,
				ReceiptHandle: msg.ReceiptHandle,
				Payload:       body,
			}
			// Durable before anything downstream sees it: the ack ordering below is
			// only safe because Push has already fsynced.
			if err := ring.Push(ctx, rec); err != nil {
				return 0, err
			}
		}
	}

	return c.Drain(ctx)
}

// Drain projects and ingests every buffered record, acknowledging each one's SQS
// message only after the sink has accepted ALL of its observations, and releasing the
// buffer slot only after that acknowledgement.
//
// The order is durable → sink → ack → release, and each step is a precondition of the
// next. A sink failure therefore leaves the message undeleted AND the record buffered,
// so the work is retried rather than lost; §2.1 requires that a buffer loss always be
// replayable from S3, and silently dropping a record the sink rejected would break it.
func (c *Collector) Drain(ctx context.Context) (int, error) {
	c.drainMu.Lock()
	defer c.drainMu.Unlock()

	ring := c.Ring()
	if ring == nil {
		return 0, nil
	}

	acked := 0
	for {
		if err := ctx.Err(); err != nil {
			return acked, err
		}

		rec, ok, err := ring.Peek()
		if err != nil {
			return acked, err
		}
		if !ok {
			return acked, nil
		}

		obs, err := c.projector().Project(rec.Payload, rec.Origin())
		if err != nil {
			// An object we cannot project will never project. Releasing it is the only
			// way to make progress, and the raw object is still in the customer bucket,
			// which §2.1 names as the system of record precisely for this case.
			c.errors.Add(1)
			slog.Error("awslogs cannot project buffered object; releasing it (the object remains in S3)",
				"object", rec.Object(), "error", err)
			if err := c.ackAndRelease(ctx, ring, rec); err != nil {
				return acked, err
			}
			continue
		}

		for i := range obs {
			if err := c.sink.IngestObservation(ctx, &obs[i]); err != nil {
				// No delete, no release. Both are correct: the record is still durable
				// and the message is still in flight.
				return acked, fmt.Errorf("awslogs: sink rejected observation %s from %s, leaving the message unacknowledged: %w",
					obs[i].ID, rec.Object(), err)
			}
			c.processed.Add(1)
		}

		if err := c.ackAndRelease(ctx, ring, rec); err != nil {
			return acked, err
		}
		acked++
	}
}

// ackAndRelease deletes the SQS message and only then releases the buffer slot.
func (c *Collector) ackAndRelease(ctx context.Context, ring *DiskRingBuffer, rec *LogRecord) error {
	// A record with no receipt handle came from a replay of a buffer written by a
	// previous process, whose handles have long expired. There is nothing to ack.
	if rec.ReceiptHandle != "" && c.sqs != nil {
		if err := c.sqs.DeleteMessage(ctx, c.cfg.QueueURL, rec.ReceiptHandle); err != nil {
			return fmt.Errorf("awslogs: acknowledging %s: %w", rec.Object(), err)
		}
		c.acked.Add(1)
	}
	return ring.Commit()
}

// s3Notification is the subset of an S3 event notification the collector reads.
type s3Notification struct {
	Records []struct {
		S3 struct {
			Bucket struct {
				Name string `json:"name"`
			} `json:"bucket"`
			Object struct {
				Key string `json:"key"`
			} `json:"object"`
		} `json:"s3"`
	} `json:"Records"`
}

// objectRefsFrom extracts the object references from an S3 event notification body.
func objectRefsFrom(body string) ([]ObjectRef, error) {
	var note s3Notification
	if err := json.Unmarshal([]byte(body), &note); err != nil {
		return nil, fmt.Errorf("awslogs: decoding S3 notification: %w", err)
	}

	var refs []ObjectRef
	for _, r := range note.Records {
		if r.S3.Bucket.Name == "" || r.S3.Object.Key == "" {
			continue
		}
		refs = append(refs, ObjectRef{Bucket: r.S3.Bucket.Name, Key: r.S3.Object.Key})
	}
	if len(refs) == 0 {
		return nil, errors.New("awslogs: S3 notification names no object")
	}
	return refs, nil
}

// Compile-time proof of the shapes the registry needs. Stop() with NO return value is
// the one that regressed in v1 (§8): `Stop() error` does not satisfy
// collectors.Stopper, so the registry's teardown never called it and a live collector
// leaked its goroutines on every shutdown — silently, because a missing optional
// interface is not a compile error at the registration site. This assertion is here so
// that the next person to change the signature breaks the build instead.
var (
	_ interface {
		Name() string
		Start(context.Context) error
	} = (*Collector)(nil)
	_ interface{ Stop() }                        = (*Collector)(nil)
	_ interface{ Health(context.Context) error } = (*Collector)(nil)
)
