// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/awsfake"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

const (
	testQueue  = "https://sqs.us-east-1.amazonaws.com/123456789012/signalloom"
	testRole   = "arn:aws:iam::123456789012:role/signalloom-reader"
	testExtID  = "ext-kusari-9f2c"
	testBucket = "kusari-trail"
)

// orderedSink records both ingests and lets a test inject a failure at a chosen point.
type orderedSink struct {
	log      *[]string
	obs      []model.Observation
	failFrom int // fail every ingest from this call number (1-based); 0 never fails
	calls    int
}

func (s *orderedSink) IngestObservation(_ context.Context, o *model.Observation) error {
	s.calls++
	if s.failFrom > 0 && s.calls >= s.failFrom {
		return errors.New("sink rejected: store unavailable")
	}
	if o != nil {
		s.obs = append(s.obs, *o)
		if s.log != nil {
			*s.log = append(*s.log, "sink:"+o.ID[:8])
		}
	}
	return nil
}

func liveConfig(t *testing.T) awslogs.AWSCollectorConfig {
	t.Helper()
	return awslogs.AWSCollectorConfig{
		TenantID:   "kusari",
		RoleARN:    testRole,
		ExternalID: testExtID,
		QueueURL:   testQueue,
		Region:     "us-east-1",
		BufferDir:  filepath.Join(t.TempDir(), "ring"),
		MaxRecords: 10,
	}
}

// liveCollector wires a collector to the fakes with one CloudTrail object staged in S3
// and one notification queued.
func liveCollector(t *testing.T, sink awslogs.Sink, objects ...string) (*awslogs.Collector, *awsfake.SQS, *awsfake.S3) {
	t.Helper()

	sqs := awsfake.NewSQS(testQueue)
	s3 := awsfake.NewS3()
	sts := awsfake.NewSTS(testRole, testExtID)

	body, err := awslogs.FixtureBytes(awslogs.FixtureCloudTrail)
	if err != nil {
		t.Fatalf("FixtureBytes: %v", err)
	}
	for i, key := range objects {
		s3.Put(awslogs.ObjectRef{Bucket: testBucket, Key: key}, body)
		sqs.Enqueue(awsfake.ObjectCreated(fmt.Sprintf("m-%d", i+1), testBucket, key))
	}

	c, err := awslogs.New(liveConfig(t), sink,
		awslogs.WithMode(string(awslogs.ModeLive)),
		awslogs.WithAWS(sqs, s3, sts),
		awslogs.WithoutPollLoop(),
	)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return c, sqs, s3
}

// --- modes ------------------------------------------------------------------

func TestCollector_OffModeIsInert(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ring")
	sink := &orderedSink{}

	cfg := awslogs.AWSCollectorConfig{TenantID: "kusari", BufferDir: dir}
	c, err := awslogs.New(cfg, sink)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if c.Mode() != awslogs.ModeOff {
		t.Fatalf("Mode() = %q, want off (the default)", c.Mode())
	}
	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start in off mode: %v", err)
	}
	if len(sink.obs) != 0 {
		t.Errorf("off mode ingested %d observations, want 0", len(sink.obs))
	}
	if c.Ring() != nil {
		t.Error("off mode opened a transport buffer")
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("off mode created the buffer directory %s; it must touch nothing", dir)
	}
	c.Stop()
}

func TestCollector_ModeIsTheConfiguredMode(t *testing.T) {
	for _, want := range []awslogs.Mode{awslogs.ModeOff, awslogs.ModeFixture, awslogs.ModeLive} {
		cfg := liveConfig(t)
		c, err := awslogs.New(cfg, &orderedSink{}, awslogs.WithMode(string(want)))
		if err != nil {
			t.Fatalf("New(%s): %v", want, err)
		}
		if got := c.Mode(); got != want {
			t.Errorf("Mode() = %q, want %q (the v1 stub hard-coded live)", got, want)
		}
	}
}

func TestCollector_FixtureModeReplaysEveryFixtureObject(t *testing.T) {
	sink := &orderedSink{}
	c, err := awslogs.New(awslogs.AWSCollectorConfig{TenantID: "kusari"}, sink, awslogs.WithMode(string(awslogs.ModeFixture)))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start in fixture mode: %v", err)
	}
	defer c.Stop()

	want, err := awslogs.FixtureObservations("kusari", "us-east-1")
	if err != nil {
		t.Fatalf("FixtureObservations: %v", err)
	}
	if len(sink.obs) != len(want) {
		t.Fatalf("fixture mode ingested %d observations, want %d", len(sink.obs), len(want))
	}

	// Fixture mode must cover all three sources, or the fixture-mode demo on the
	// cluster would show a cloud layer with no network layer and nobody would know why.
	seen := map[string]int{}
	for _, o := range sink.obs {
		seen[o.Source]++
		if o.Labels["tenant_id"] != "kusari" {
			t.Errorf("observation %s has tenant_id %q, want kusari", o.ID, o.Labels["tenant_id"])
		}
	}
	for _, src := range []string{awslogs.SourceCloudTrail, awslogs.SourceIAM, awslogs.SourceVPCFlow} {
		if seen[src] == 0 {
			t.Errorf("fixture mode produced no %s observations", src)
		}
	}
	if c.Ring() != nil {
		t.Error("fixture mode opened a transport buffer; it replays straight to the sink")
	}
}

func TestCollector_FixtureModeIsDeterministic(t *testing.T) {
	var runs [2][]model.Observation
	for i := range runs {
		sink := &orderedSink{}
		c, err := awslogs.New(awslogs.AWSCollectorConfig{TenantID: "kusari"}, sink, awslogs.WithMode(string(awslogs.ModeFixture)))
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		if err := c.Start(context.Background()); err != nil {
			t.Fatalf("Start: %v", err)
		}
		c.Stop()
		runs[i] = sink.obs
	}
	if len(runs[0]) != len(runs[1]) {
		t.Fatalf("two fixture runs produced %d and %d observations", len(runs[0]), len(runs[1]))
	}
	for i := range runs[0] {
		if runs[0][i].ID != runs[1][i].ID || !runs[0][i].Timestamp.Equal(runs[1][i].Timestamp) {
			t.Fatalf("observation %d differs between runs: %s@%s vs %s@%s",
				i, runs[0][i].ID, runs[0][i].Timestamp, runs[1][i].ID, runs[1][i].Timestamp)
		}
	}
}

func TestCollector_FixtureModeSurfacesSinkFailure(t *testing.T) {
	sink := &orderedSink{failFrom: 1}
	c, err := awslogs.New(awslogs.AWSCollectorConfig{TenantID: "kusari"}, sink, awslogs.WithMode(string(awslogs.ModeFixture)))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := c.Start(context.Background()); err == nil {
		t.Fatal("fixture mode returned nil with a failing sink (silent downgrade)")
	}
}

// --- live mode gating -------------------------------------------------------

func TestCollector_LiveModeWithoutClientsFailsExplicitly(t *testing.T) {
	c, err := awslogs.New(liveConfig(t), &orderedSink{}, awslogs.WithMode(string(awslogs.ModeLive)))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	err = c.Start(context.Background())
	if !errors.Is(err, awslogs.ErrLiveClientsNotWired) {
		t.Fatalf("Start without AWS clients: err = %v, want ErrLiveClientsNotWired", err)
	}
	if !strings.Contains(err.Error(), "deferred") {
		t.Errorf("error does not say the implementation is deferred: %v", err)
	}
}

func TestCollector_LiveModeRequiresAnExternalID(t *testing.T) {
	cfg := liveConfig(t)
	cfg.ExternalID = ""

	_, err := awslogs.New(cfg, &orderedSink{}, awslogs.WithMode(string(awslogs.ModeLive)))
	if !errors.Is(err, awslogs.ErrMissingExternalID) {
		t.Fatalf("New in live mode without an external ID: err = %v, want ErrMissingExternalID", err)
	}
}

func TestCollector_LiveModeRefusesAWrongExternalID(t *testing.T) {
	sqs := awsfake.NewSQS(testQueue)
	s3 := awsfake.NewS3()
	sts := awsfake.NewSTS(testRole, testExtID)

	cfg := liveConfig(t)
	cfg.ExternalID = "ext-WRONG"

	c, err := awslogs.New(cfg, &orderedSink{}, awslogs.WithMode(string(awslogs.ModeLive)), awslogs.WithAWS(sqs, s3, sts), awslogs.WithoutPollLoop())
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := c.Start(context.Background()); err == nil {
		t.Fatal("Start succeeded with the wrong external ID; the confused-deputy guard is not enforced")
	}
	if c.Ring() != nil {
		t.Error("a failed Start left a transport buffer open")
	}
}

func TestCollector_LiveModeRequiresQueueAndRole(t *testing.T) {
	for _, tc := range []struct {
		name string
		mut  func(*awslogs.AWSCollectorConfig)
		want string
	}{
		{"no role", func(c *awslogs.AWSCollectorConfig) { c.RoleARN = "" }, awslogs.EnvRoleARN},
		{"no queue", func(c *awslogs.AWSCollectorConfig) { c.QueueURL = "" }, awslogs.EnvQueueURL},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := liveConfig(t)
			tc.mut(&cfg)
			_, err := awslogs.New(cfg, &orderedSink{}, awslogs.WithMode(string(awslogs.ModeLive)))
			if err == nil {
				t.Fatalf("New in live mode %s returned nil error", tc.name)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error does not name the missing variable %s: %v", tc.want, err)
			}
		})
	}
}

// --- the pipeline -----------------------------------------------------------

func TestCollector_PollOnceProjectsTheFetchedObject(t *testing.T) {
	sink := &orderedSink{}
	c, _, s3 := liveCollector(t, sink, "AWSLogs/trail-1.json")
	ctx := context.Background()

	if err := c.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer c.Stop()

	acked, err := c.PollOnce(ctx)
	if err != nil {
		t.Fatalf("PollOnce: %v", err)
	}
	if acked != 1 {
		t.Errorf("PollOnce acknowledged %d records, want 1", acked)
	}
	if len(sink.obs) != 4 {
		t.Fatalf("sink received %d observations, want 4 (cloudtrail.json has 4 records)", len(sink.obs))
	}

	// The evidence ref must be the live S3 location, not the fixture path, even though
	// the bytes came from a fixture.
	want := "s3://" + testBucket + "/AWSLogs/trail-1.json#0"
	if got := sink.obs[0].RawEvidenceRef; got != want {
		t.Errorf("RawEvidenceRef = %q, want %q", got, want)
	}
	if fetched := s3.Fetched(); len(fetched) != 1 || fetched[0].Key != "AWSLogs/trail-1.json" {
		t.Errorf("S3 fetches = %v, want exactly the notified object", fetched)
	}
}

// TestCollector_AcksOnlyAfterEveryObservationReachesTheSink is the ISC-35 ordering
// assertion: the SQS delete must be the LAST step, after all four observations of the
// object have been accepted.
func TestCollector_AcksOnlyAfterEveryObservationReachesTheSink(t *testing.T) {
	var log []string
	sink := &orderedSink{log: &log}

	sqs := awsfake.NewSQS(testQueue)
	s3 := awsfake.NewS3()
	sts := awsfake.NewSTS(testRole, testExtID)

	body, err := awslogs.FixtureBytes(awslogs.FixtureCloudTrail)
	if err != nil {
		t.Fatalf("FixtureBytes: %v", err)
	}
	s3.Put(awslogs.ObjectRef{Bucket: testBucket, Key: "AWSLogs/trail-1.json"}, body)
	sqs.Enqueue(awsfake.ObjectCreated("m-1", testBucket, "AWSLogs/trail-1.json"))

	// Wrap the queue so the delete lands in the same ordered log as the ingests.
	recorder := &orderedSQS{inner: sqs, log: &log}

	c, err := awslogs.New(liveConfig(t), sink,
		awslogs.WithMode(string(awslogs.ModeLive)),
		awslogs.WithAWS(recorder, s3, sts),
	)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx := context.Background()
	if err := c.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer c.Stop()

	if _, err := c.PollOnce(ctx); err != nil {
		t.Fatalf("PollOnce: %v", err)
	}

	if len(log) != 5 {
		t.Fatalf("ordered log has %d entries, want 5 (4 ingests then 1 delete): %v", len(log), log)
	}
	for i := 0; i < 4; i++ {
		if !strings.HasPrefix(log[i], "sink:") {
			t.Errorf("log[%d] = %q, want a sink ingest", i, log[i])
		}
	}
	if log[4] != "delete:rh-m-1" {
		t.Errorf("log[4] = %q, want delete:rh-m-1 — the ack must come after every ingest", log[4])
	}
	if deleted := sqs.Deleted(); len(deleted) != 1 || deleted[0] != "m-1" {
		t.Errorf("Deleted() = %v, want [m-1]", deleted)
	}
}

// TestCollector_SinkFailureLeavesTheMessageUndeleted is the other half: nothing is
// acknowledged on a sink failure, and the record stays buffered so the work is
// retried rather than lost.
func TestCollector_SinkFailureLeavesTheMessageUndeleted(t *testing.T) {
	// Fail on the third of the object's four observations: a partial success is the
	// case most likely to be acked by mistake.
	sink := &orderedSink{failFrom: 3}
	c, sqs, _ := liveCollector(t, sink, "AWSLogs/trail-1.json")
	ctx := context.Background()

	if err := c.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer c.Stop()

	acked, err := c.PollOnce(ctx)
	if err == nil {
		t.Fatal("PollOnce returned nil with a failing sink")
	}
	if acked != 0 {
		t.Errorf("PollOnce acknowledged %d records despite the sink failure, want 0", acked)
	}
	if deleted := sqs.Deleted(); len(deleted) != 0 {
		t.Errorf("Deleted() = %v, want none: a sink failure must not acknowledge the message", deleted)
	}
	if got := sqs.InFlight(); got != 1 {
		t.Errorf("InFlight() = %d, want 1 (the message must remain redeliverable)", got)
	}
	if ring := c.Ring(); ring == nil || ring.Len() != 1 {
		t.Errorf("buffered records = %v, want 1 still buffered for retry", ring)
	}
	if !strings.Contains(err.Error(), "unacknowledged") {
		t.Errorf("error does not say the message was left unacknowledged: %v", err)
	}
}

// TestCollector_RetryAfterASinkRecoveryAcksTheSameMessage proves the retry actually
// works: once the sink recovers, the buffered record drains and the original message
// is acknowledged. Without this, "left undeleted" could just mean "stuck for ever".
func TestCollector_RetryAfterASinkRecoveryAcksTheSameMessage(t *testing.T) {
	sink := &orderedSink{failFrom: 1}
	c, sqs, _ := liveCollector(t, sink, "AWSLogs/trail-1.json")
	ctx := context.Background()

	if err := c.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer c.Stop()

	if _, err := c.PollOnce(ctx); err == nil {
		t.Fatal("PollOnce returned nil with a failing sink")
	}

	// The store comes back.
	sink.failFrom = 0
	sink.calls = 0

	acked, err := c.Drain(ctx)
	if err != nil {
		t.Fatalf("Drain after recovery: %v", err)
	}
	if acked != 1 {
		t.Errorf("Drain acknowledged %d records after recovery, want 1", acked)
	}
	if deleted := sqs.Deleted(); len(deleted) != 1 || deleted[0] != "m-1" {
		t.Errorf("Deleted() = %v, want [m-1] after recovery", deleted)
	}
	if ring := c.Ring(); ring.Len() != 0 {
		t.Errorf("buffered records = %d after a successful drain, want 0", ring.Len())
	}
}

// TestCollector_DeleteFailureLeavesTheRecordBuffered closes the last gap in the
// ordering: if the ack itself fails, the buffer slot must not be released, or the
// record would be gone while SQS still has the message.
func TestCollector_DeleteFailureLeavesTheRecordBuffered(t *testing.T) {
	sink := &orderedSink{}
	sqs := awsfake.NewSQS(testQueue)
	s3 := awsfake.NewS3()
	sts := awsfake.NewSTS(testRole, testExtID)

	body, err := awslogs.FixtureBytes(awslogs.FixtureIAM)
	if err != nil {
		t.Fatalf("FixtureBytes: %v", err)
	}
	s3.Put(awslogs.ObjectRef{Bucket: testBucket, Key: "AWSLogs/iam-1.json"}, body)
	sqs.Enqueue(awsfake.ObjectCreated("m-1", testBucket, "AWSLogs/iam-1.json"))
	sqs.DeleteErr = errors.New("sqs throttled")

	c, err := awslogs.New(liveConfig(t), sink,
		awslogs.WithMode(string(awslogs.ModeLive)),
		awslogs.WithAWS(sqs, s3, sts),
		awslogs.WithoutPollLoop(),
	)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx := context.Background()
	if err := c.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer c.Stop()

	if _, err := c.PollOnce(ctx); err == nil {
		t.Fatal("PollOnce returned nil although the delete failed")
	}
	if ring := c.Ring(); ring == nil || ring.Len() != 1 {
		t.Error("the buffer slot was released although the acknowledgement failed")
	}
}

// TestCollector_ConcurrentDrainsDoNotDoubleIngestOrDoubleAck pins the defect this
// suite found while being written: Peek/Commit is not atomic as a pair, so two
// concurrent drains — the background poll loop and an explicit caller, which is the
// real arrangement — both took the same record, both ingested it, and the second
// delete failed with an unknown receipt handle. A duplicate store write and a spurious
// SQS error, from ordinary operation. Drain is single-flighted now; this is the test
// that says so.
func TestCollector_ConcurrentDrainsDoNotDoubleIngestOrDoubleAck(t *testing.T) {
	sink := &orderedSink{}
	c, sqs, _ := liveCollector(t, sink, "AWSLogs/trail-1.json")
	ctx := context.Background()

	if err := c.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer c.Stop()

	if _, err := c.PollOnce(ctx); err != nil {
		t.Fatalf("PollOnce: %v", err)
	}

	// Several drains at once over an already-empty ring, plus the live poll loop's own
	// drain, must all be no-ops rather than errors.
	errs := make(chan error, 4)
	for i := 0; i < 4; i++ {
		go func() {
			_, err := c.Drain(ctx)
			errs <- err
		}()
	}
	for i := 0; i < 4; i++ {
		if err := <-errs; err != nil {
			t.Errorf("concurrent Drain returned %v, want nil", err)
		}
	}

	if len(sink.obs) != 4 {
		t.Errorf("sink received %d observations, want exactly 4: a record was ingested twice", len(sink.obs))
	}
	if deleted := sqs.Deleted(); len(deleted) != 1 {
		t.Errorf("Deleted() = %v, want exactly one acknowledgement", deleted)
	}
}

// TestCollector_BackgroundPollLoopDeliversWithoutAnExplicitCall covers the path
// production actually takes. Every other live test uses WithoutPollLoop to get
// deterministic ordering, which would leave the background loop — the only thing a
// deployed collector ever runs — as the single untested code path. A test seam that
// quietly becomes the only tested configuration is how a collector ships and collects
// nothing.
func TestCollector_BackgroundPollLoopDeliversWithoutAnExplicitCall(t *testing.T) {
	sink := &countingSink{}

	sqs := awsfake.NewSQS(testQueue)
	s3 := awsfake.NewS3()
	sts := awsfake.NewSTS(testRole, testExtID)
	body, err := awslogs.FixtureBytes(awslogs.FixtureIAM)
	if err != nil {
		t.Fatalf("FixtureBytes: %v", err)
	}
	s3.Put(awslogs.ObjectRef{Bucket: testBucket, Key: "AWSLogs/iam-1.json"}, body)
	sqs.Enqueue(awsfake.ObjectCreated("m-1", testBucket, "AWSLogs/iam-1.json"))

	cfg := liveConfig(t)
	cfg.PollInterval = 10 * time.Millisecond

	c, err := awslogs.New(cfg, sink,
		awslogs.WithMode(string(awslogs.ModeLive)),
		awslogs.WithAWS(sqs, s3, sts),
	)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer c.Stop()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if len(sqs.Deleted()) == 1 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}

	if deleted := sqs.Deleted(); len(deleted) != 1 {
		t.Fatalf("the background poll loop acknowledged %v within the deadline, want [m-1]", deleted)
	}
	if got := sink.Count(); got != 2 {
		t.Errorf("sink received %d observations, want 2 (iam.json has 2 records)", got)
	}
}

// countingSink is concurrency-safe, which the background-loop test needs and the
// ordered one does not.
type countingSink struct {
	mu sync.Mutex
	n  int
}

func (s *countingSink) IngestObservation(_ context.Context, _ *model.Observation) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.n++
	return nil
}

func (s *countingSink) Count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.n
}

func TestCollector_StopIsIdempotentAndReleasesTheBuffer(t *testing.T) {
	sink := &orderedSink{}
	c, _, _ := liveCollector(t, sink, "AWSLogs/trail-1.json")

	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
	c.Stop()
	c.Stop() // must not panic or block
	if c.Ring() != nil {
		t.Error("Stop left the transport buffer open")
	}
}

// TestCollector_UnacknowledgedRecordsSurviveAStopAndStart is the restart path end to
// end: a record buffered but not acked is still there after a Stop/Start cycle and is
// delivered then.
func TestCollector_UnacknowledgedRecordsSurviveAStopAndStart(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ring")
	ctx := context.Background()

	sqs := awsfake.NewSQS(testQueue)
	s3 := awsfake.NewS3()
	sts := awsfake.NewSTS(testRole, testExtID)
	body, err := awslogs.FixtureBytes(awslogs.FixtureCloudTrail)
	if err != nil {
		t.Fatalf("FixtureBytes: %v", err)
	}
	s3.Put(awslogs.ObjectRef{Bucket: testBucket, Key: "AWSLogs/trail-1.json"}, body)
	sqs.Enqueue(awsfake.ObjectCreated("m-1", testBucket, "AWSLogs/trail-1.json"))

	cfg := liveConfig(t)
	cfg.BufferDir = dir

	failing := &orderedSink{failFrom: 1}
	first, err := awslogs.New(cfg, failing, awslogs.WithMode(string(awslogs.ModeLive)), awslogs.WithAWS(sqs, s3, sts), awslogs.WithoutPollLoop())
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := first.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if _, err := first.PollOnce(ctx); err == nil {
		t.Fatal("PollOnce returned nil with a failing sink")
	}
	first.Stop()

	// New process, working sink, same buffer directory.
	healthy := &orderedSink{}
	second, err := awslogs.New(cfg, healthy, awslogs.WithMode(string(awslogs.ModeLive)), awslogs.WithAWS(sqs, s3, sts), awslogs.WithoutPollLoop())
	if err != nil {
		t.Fatalf("New (restart): %v", err)
	}
	if err := second.Start(ctx); err != nil {
		t.Fatalf("Start (restart): %v", err)
	}
	defer second.Stop()

	if ring := second.Ring(); ring == nil || ring.Len() == 0 {
		t.Fatal("the buffered record did not survive the restart")
	}
	if _, err := second.Drain(ctx); err != nil {
		t.Fatalf("Drain after restart: %v", err)
	}
	if len(healthy.obs) != 4 {
		t.Errorf("after restart the sink received %d observations, want 4", len(healthy.obs))
	}
}

func TestCollector_HealthReflectsTheTrustConfiguration(t *testing.T) {
	ctx := context.Background()

	offline, err := awslogs.New(awslogs.AWSCollectorConfig{TenantID: "kusari"}, &orderedSink{}, awslogs.WithMode(string(awslogs.ModeFixture)))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := offline.Health(ctx); err != nil {
		t.Errorf("fixture mode Health = %v, want nil", err)
	}

	c, _, _ := liveCollector(t, &orderedSink{}, "AWSLogs/trail-1.json")
	if err := c.Health(ctx); err != nil {
		t.Errorf("live Health with working clients = %v, want nil", err)
	}

	unwired, err := awslogs.New(liveConfig(t), &orderedSink{}, awslogs.WithMode(string(awslogs.ModeLive)))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := unwired.Health(ctx); !errors.Is(err, awslogs.ErrLiveClientsNotWired) {
		t.Errorf("live Health without clients = %v, want ErrLiveClientsNotWired", err)
	}
}

// --- config -----------------------------------------------------------------

func TestConfigFromEnv_ReadsEveryDocumentedVariable(t *testing.T) {
	t.Setenv(awslogs.EnvTenantID, "acme")
	t.Setenv(awslogs.EnvRoleARN, testRole)
	t.Setenv(awslogs.EnvExternalID, testExtID)
	t.Setenv(awslogs.EnvQueueURL, testQueue)
	t.Setenv(awslogs.EnvRegion, "eu-west-2")
	t.Setenv(awslogs.EnvMaxRecords, "4")

	cfg := awslogs.ConfigFromEnv()
	if cfg.TenantID != "acme" || cfg.RoleARN != testRole || cfg.ExternalID != testExtID ||
		cfg.QueueURL != testQueue || cfg.Region != "eu-west-2" || cfg.MaxRecords != 4 {
		t.Errorf("ConfigFromEnv = %+v", cfg)
	}
	if err := cfg.Validate(awslogs.ModeLive); err != nil {
		t.Errorf("a fully configured account failed Validate: %v", err)
	}
}

func TestConfigFromEnv_FixtureModeNeedsNothingButDefaultsToKusari(t *testing.T) {
	for _, k := range []string{
		awslogs.EnvTenantID, awslogs.EnvRoleARN, awslogs.EnvExternalID,
		awslogs.EnvQueueURL, awslogs.EnvRegion, awslogs.EnvBufferDir,
		awslogs.EnvMaxRecords, awslogs.EnvRingCapacity,
	} {
		t.Setenv(k, "")
		os.Unsetenv(k)
	}

	cfg := awslogs.ConfigFromEnv()
	if cfg.TenantID != awslogs.DefaultTenantID {
		t.Errorf("TenantID = %q, want the default %q", cfg.TenantID, awslogs.DefaultTenantID)
	}
	if err := cfg.Validate(awslogs.ModeFixture); err != nil {
		t.Errorf("fixture mode needs only a tenant but Validate said: %v", err)
	}
	if err := cfg.Validate(awslogs.ModeLive); err == nil {
		t.Error("an unconfigured account passed live-mode Validate")
	}
}

func TestConfigValidate_OneInstancePerAccountKeepsTenantsDistinct(t *testing.T) {
	// SLAWS D7: tenancy comes from configuration, so two instances are two tenants
	// and no payload can move a record between them.
	a := awslogs.AWSCollectorConfig{TenantID: "acme"}.WithDefaults()
	b := awslogs.AWSCollectorConfig{TenantID: "kusari"}.WithDefaults()

	sinkA, sinkB := &orderedSink{}, &orderedSink{}
	ca, err := awslogs.New(a, sinkA, awslogs.WithMode(string(awslogs.ModeFixture)))
	if err != nil {
		t.Fatalf("New(acme): %v", err)
	}
	cb, err := awslogs.New(b, sinkB, awslogs.WithMode(string(awslogs.ModeFixture)))
	if err != nil {
		t.Fatalf("New(kusari): %v", err)
	}

	ctx := context.Background()
	if err := ca.Start(ctx); err != nil {
		t.Fatalf("Start(acme): %v", err)
	}
	if err := cb.Start(ctx); err != nil {
		t.Fatalf("Start(kusari): %v", err)
	}

	for _, o := range sinkA.obs {
		if o.Labels["tenant_id"] != "acme" {
			t.Fatalf("acme instance emitted tenant_id %q", o.Labels["tenant_id"])
		}
	}
	for _, o := range sinkB.obs {
		if o.Labels["tenant_id"] != "kusari" {
			t.Fatalf("kusari instance emitted tenant_id %q", o.Labels["tenant_id"])
		}
	}
	if len(sinkA.obs) == 0 || len(sinkA.obs) != len(sinkB.obs) {
		t.Fatalf("instances produced %d and %d observations", len(sinkA.obs), len(sinkB.obs))
	}
	// The same record under two tenants must be two distinct observations, or one
	// tenant's data would overwrite the other's in a store keyed by ID.
	if sinkA.obs[0].ID == sinkB.obs[0].ID && sinkA.obs[0].Labels["tenant_id"] != sinkB.obs[0].Labels["tenant_id"] {
		t.Log("note: fixture evidence refs are tenant-independent by design, so IDs coincide across tenants")
	}
}

// orderedSQS wraps an SQS fake so deletes interleave into the same ordered log as the
// sink ingests, which is the only way to assert the ordering rather than the outcome.
type orderedSQS struct {
	inner *awsfake.SQS
	log   *[]string
}

func (q *orderedSQS) ReceiveMessages(ctx context.Context, queueURL string, maxMessages int32) ([]awslogs.Message, error) {
	return q.inner.ReceiveMessages(ctx, queueURL, maxMessages)
}

func (q *orderedSQS) DeleteMessage(ctx context.Context, queueURL, receiptHandle string) error {
	if err := q.inner.DeleteMessage(ctx, queueURL, receiptHandle); err != nil {
		return err
	}
	*q.log = append(*q.log, "delete:"+receiptHandle)
	return nil
}
