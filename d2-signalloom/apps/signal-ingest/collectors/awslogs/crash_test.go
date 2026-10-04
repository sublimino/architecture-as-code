// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/awsfake"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// SLAWS §6.3 and P3-2: SIGKILL the process between Store.Append and the SQS delete,
// then assert the record is present exactly once after restart and the message is
// re-delivered and deduplicated.
//
// Mechanism: a child process. The test binary re-executes itself with
// crashEnvPhase set, and the child SIGKILLs ITSELF from inside the sink once the
// final observation of the record has been accepted — which is precisely the window
// the proposal names. Nothing else gives that window deterministically:
//
//   - A barrier file plus a kill from the parent races the child. The window between
//     "sink returned" and "DeleteMessage called" is microseconds, so the parent would
//     have to poll it, and a test that lands the kill in the right window most of the
//     time is a test that goes flaky and then gets deleted.
//   - A crash hook on the ring buffer would prove the ring's own durability, which
//     diskring_test.go already does (TestDiskRing_UncleanExitIsAtLeastOnceNotExactlyOnce).
//     It would not exercise the collector's ordering — durable, then sink, then ack,
//     then release — which is the thing that makes a crash survivable.
//   - An in-process panic is not a crash. Deferred Close calls still run, the WAL is
//     compacted on the way out, and the test proves the clean path.
//
// SIGKILL is uncatchable, so the child leaves exactly the on-disk state a kill -9'd
// pod would: an fsynced WAL record, no Commit, no DeleteMessage.
//
// The SQS fake is file-backed for the same reason. awsfake.SQS holds its queue in
// memory, so it dies with the child and the second process would see an empty queue
// — which would assert nothing about re-delivery. fileSQS persists the queue, the
// in-flight set and the delete journal, so the parent can read what actually
// happened across both processes.

const (
	crashEnvPhase     = "AWSLOGS_CRASH_PHASE"
	crashEnvDir       = "AWSLOGS_CRASH_DIR"
	crashEnvKillAfter = "AWSLOGS_CRASH_KILL_AFTER"

	crashPhaseKill    = "kill"
	crashPhaseRestart = "restart"

	crashBucket    = "kusari-trail"
	crashKey       = "AWSLogs/123456789012/CloudTrail/trail-crash.json"
	crashMessageID = "m-crash-1"

	crashTenant = "kusari"
	crashRegion = "us-east-1"
)

// ---------------------------------------------------------------------------
// A file-backed SQS fake, durable across a SIGKILL.
// ---------------------------------------------------------------------------

type fileSQSState struct {
	Queued   []awslogs.Message          `json:"queued"`
	InFlight map[string]awslogs.Message `json:"in_flight"` // receipt handle -> message
	Handles  map[string]string          `json:"handles"`   // receipt handle -> message ID
	Deleted  []string                   `json:"deleted"`   // message IDs, in delete order
	Receives int                        `json:"receives"`
	// Stale holds the receipt handles this fake has reissued. A delete presented with
	// one of these is the stale-handle rejection a restarted consumer earns, and it
	// has to be distinguishable from a handle the queue has simply never seen.
	Stale []string `json:"stale"`
	// StaleDeletes counts delete attempts made with a reissued handle, so the parent
	// can assert the restart actually took that path rather than passing for some
	// other reason.
	StaleDeletes int `json:"stale_deletes"`
}

// fileSQS is an awslogs.SQSClient whose whole state is a JSON file, fsynced on every
// mutation. Every method reads the file, mutates and writes it back, so two processes
// in sequence see one queue.
type fileSQS struct {
	mu       sync.Mutex
	path     string
	queueURL string
}

func newFileSQS(dir, queueURL string) *fileSQS {
	return &fileSQS{path: filepath.Join(dir, "sqs.json"), queueURL: queueURL}
}

func (q *fileSQS) load() (*fileSQSState, error) {
	st := &fileSQSState{
		InFlight: map[string]awslogs.Message{},
		Handles:  map[string]string{},
	}
	raw, err := os.ReadFile(q.path)
	if errors.Is(err, os.ErrNotExist) {
		return st, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(raw, st); err != nil {
		return nil, err
	}
	if st.InFlight == nil {
		st.InFlight = map[string]awslogs.Message{}
	}
	if st.Handles == nil {
		st.Handles = map[string]string{}
	}
	return st, nil
}

// save writes the state through a temp file and fsyncs, so a SIGKILL mid-save cannot
// leave a half-written queue that the next process reads as an empty one.
func (q *fileSQS) save(st *fileSQSState) error {
	raw, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	tmp := q.path + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := f.Write(raw); err != nil {
		f.Close() //nolint:errcheck // the write error is the one that matters
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close() //nolint:errcheck
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, q.path)
}

func (q *fileSQS) seed(msg awslogs.Message) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	st, err := q.load()
	if err != nil {
		return err
	}
	st.Queued = append(st.Queued, msg)
	st.Handles[msg.ReceiptHandle] = msg.MessageID
	return q.save(st)
}

// recoverInFlight returns every in-flight message to the queue, which is what SQS
// does when a visibility timeout expires with no delete — the state a crashed
// consumer leaves behind.
//
// The receipt handle is REISSUED, and the old one is invalidated, because that is
// what SQS does. This fake used to preserve the handle, which made the restart path
// look like it worked: the replayed record presented the handle the dead process had
// been given, the fake accepted it, and the delete succeeded. Against a real queue
// that delete is rejected with ReceiptHandleIsInvalid for ever — the handle can never
// become valid again — so the record was never released, the object was re-projected
// and re-ingested on every drain, and the collector wedged on its own backlog. The
// test could not see any of that, which is the reason it is modelled here now.
//
// The message ID is preserved: it is the same message, redelivered.
func (q *fileSQS) recoverInFlight() error {
	q.mu.Lock()
	defer q.mu.Unlock()
	st, err := q.load()
	if err != nil {
		return err
	}
	for handle, msg := range st.InFlight {
		delete(st.InFlight, handle)
		// Forget the old handle so a delete presented with it is rejected rather than
		// silently honoured, and remember that it WAS ours so the rejection can name
		// the right condition.
		delete(st.Handles, handle)
		st.Stale = append(st.Stale, handle)
		msg.ReceiptHandle = handle + "-reissued"
		st.Handles[msg.ReceiptHandle] = msg.MessageID
		st.Queued = append(st.Queued, msg)
	}
	return q.save(st)
}

func (q *fileSQS) ReceiveMessages(ctx context.Context, queueURL string, maxMessages int32) ([]awslogs.Message, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if queueURL != q.queueURL {
		return nil, fmt.Errorf("fileSQS: bound to %s, refusing %s", q.queueURL, queueURL)
	}

	q.mu.Lock()
	defer q.mu.Unlock()
	st, err := q.load()
	if err != nil {
		return nil, err
	}
	st.Receives++

	n := int(maxMessages)
	if n > len(st.Queued) {
		n = len(st.Queued)
	}
	out := make([]awslogs.Message, 0, n)
	for _, msg := range st.Queued[:n] {
		st.InFlight[msg.ReceiptHandle] = msg
		st.Handles[msg.ReceiptHandle] = msg.MessageID
		out = append(out, msg)
	}
	st.Queued = st.Queued[n:]

	if err := q.save(st); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}

func (q *fileSQS) DeleteMessage(ctx context.Context, queueURL, receiptHandle string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if queueURL != q.queueURL {
		return fmt.Errorf("fileSQS: bound to %s, refusing %s", q.queueURL, queueURL)
	}

	q.mu.Lock()
	defer q.mu.Unlock()
	st, err := q.load()
	if err != nil {
		return err
	}

	// A handle this fake reissued: the stale-handle rejection, recorded so the parent
	// can prove the restart went through that branch. Checked before Handles so a
	// reissued handle is never mistaken for a live one.
	for _, stale := range st.Stale {
		if stale == receiptHandle {
			st.StaleDeletes++
			if err := q.save(st); err != nil {
				return err
			}
			return &awsfake.ReceiptHandleIsInvalidError{
				ReceiptHandle: receiptHandle,
				MessageID:     "", // the fake no longer maps it; the handle is all SQS would echo back
			}
		}
	}

	msgID, known := st.Handles[receiptHandle]
	if !known {
		return fmt.Errorf("fileSQS: DeleteMessage for a receipt handle this queue has never issued: %q", receiptHandle)
	}

	// Already deleted: idempotent, and not journalled twice. SQS behaves this way and
	// it matters here — a second journal entry would make "deleted exactly once"
	// untestable.
	for _, id := range st.Deleted {
		if id == msgID {
			return nil
		}
	}

	delete(st.InFlight, receiptHandle)
	for i, msg := range st.Queued {
		if msg.MessageID == msgID {
			st.Queued = append(st.Queued[:i], st.Queued[i+1:]...)
			break
		}
	}
	st.Deleted = append(st.Deleted, msgID)
	return q.save(st)
}

// ---------------------------------------------------------------------------
// A durable sink that can take the process down with it.
// ---------------------------------------------------------------------------

// crashSink appends each accepted observation ID to a file, fsyncs, and — once
// killAfter observations have been accepted — SIGKILLs its own process.
//
// The kill is inside IngestObservation, after the append is durable and before the
// call returns, so the collector has not yet reached ackAndRelease. That is the exact
// window §6.3 asks for: the record is fsynced in the ring, the sink has accepted it,
// and the SQS delete has not happened.
type crashSink struct {
	path      string
	killAfter int
	seen      int
}

func (s *crashSink) IngestObservation(_ context.Context, obs *model.Observation) error {
	f, err := os.OpenFile(s.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintln(f, obs.ID); err != nil {
		f.Close() //nolint:errcheck
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close() //nolint:errcheck
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}

	s.seen++
	if s.killAfter > 0 && s.seen >= s.killAfter {
		// Uncatchable by design: no deferred Close runs, the WAL is not compacted, and
		// no delete is issued. Exactly what a kill -9'd pod leaves behind.
		_ = syscall.Kill(syscall.Getpid(), syscall.SIGKILL)
		// Unreachable.
		return errors.New("awslogs crash test: SIGKILL did not take effect")
	}
	return nil
}

// ---------------------------------------------------------------------------
// The child.
// ---------------------------------------------------------------------------

// TestCollectorCrashChild is the child process body. It is a no-op unless
// crashEnvPhase is set, so a normal `go test ./...` never runs it.
func TestCollectorCrashChild(t *testing.T) {
	phase := os.Getenv(crashEnvPhase)
	if phase == "" {
		t.Skip("not the crash-test child process")
	}

	dir := os.Getenv(crashEnvDir)
	if dir == "" {
		t.Fatalf("%s is required", crashEnvDir)
	}
	killAfter, err := strconv.Atoi(os.Getenv(crashEnvKillAfter))
	if err != nil && phase == crashPhaseKill {
		t.Fatalf("%s: %v", crashEnvKillAfter, err)
	}

	queueURL := "https://sqs.us-east-1.amazonaws.com/123456789012/kusari-logs"
	roleARN := "arn:aws:iam::123456789012:role/signalloom-reader"
	externalID := "kusari-eap-2026q3"

	sqs := newFileSQS(dir, queueURL)

	body, err := awslogs.FixtureBytes(awslogs.FixtureCloudTrail)
	if err != nil {
		t.Fatalf("FixtureBytes: %v", err)
	}
	s3 := awsfake.NewS3()
	s3.Put(awslogs.ObjectRef{Bucket: crashBucket, Key: crashKey}, body)
	sts := awsfake.NewSTS(roleARN, externalID)

	cfg := awslogs.AWSCollectorConfig{
		TenantID:   crashTenant,
		RoleARN:    roleARN,
		ExternalID: externalID,
		QueueURL:   queueURL,
		Region:     crashRegion,
		BufferDir:  filepath.Join(dir, "ring"),
	}.WithDefaults()

	sink := &crashSink{path: filepath.Join(dir, "sink.log")}
	ctx := context.Background()

	switch phase {
	case crashPhaseKill:
		sink.killAfter = killAfter
		if err := sqs.seed(awsfake.ObjectCreated(crashMessageID, crashBucket, crashKey)); err != nil {
			t.Fatalf("seeding the queue: %v", err)
		}

		c, err := awslogs.New(cfg, sink,
			awslogs.WithMode(string(awslogs.ModeLive)),
			awslogs.WithAWS(sqs, s3, sts),
			awslogs.WithoutPollLoop(),
		)
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		if err := c.Start(ctx); err != nil {
			t.Fatalf("Start: %v", err)
		}
		// This must not return: the sink takes the process down mid-Drain.
		acked, err := c.PollOnce(ctx)
		t.Fatalf("PollOnce returned (%d, %v); the sink should have SIGKILLed this process", acked, err)

	case crashPhaseRestart:
		// The crash left the message in flight with no delete, so its visibility
		// timeout expires and SQS returns it to the queue.
		if err := sqs.recoverInFlight(); err != nil {
			t.Fatalf("recovering in-flight messages: %v", err)
		}

		c, err := awslogs.New(cfg, sink,
			awslogs.WithMode(string(awslogs.ModeLive)),
			awslogs.WithAWS(sqs, s3, sts),
			awslogs.WithoutPollLoop(),
		)
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		if err := c.Start(ctx); err != nil {
			t.Fatalf("Start: %v", err)
		}

		// Drain first: the backlog the previous process fsynced but never acked. This
		// is what the poll loop does on start.
		if _, err := c.Drain(ctx); err != nil {
			t.Fatalf("draining the replayed backlog: %v", err)
		}
		// Then a normal poll. The message was acked by the drain above, so this should
		// find nothing — and if the ordering were wrong it would find the message
		// again and re-ingest it.
		if _, err := c.PollOnce(ctx); err != nil {
			t.Fatalf("PollOnce after recovery: %v", err)
		}
		c.Stop()

	default:
		t.Fatalf("unknown phase %q", phase)
	}
}

// ---------------------------------------------------------------------------
// The parent.
// ---------------------------------------------------------------------------

func TestCollector_SIGKILLBetweenTheDurableWriteAndTheSQSDeleteStoresExactlyOnce(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("SIGKILL semantics are POSIX")
	}
	if os.Getenv(crashEnvPhase) != "" {
		t.Skip("child process")
	}

	dir := t.TempDir()

	// What the object must project to. Derived from the fixture and the origin, not
	// hard-coded: Observation.ID is sha256 of the evidence ref, which is the whole
	// reason a replay deduplicates.
	body, err := awslogs.FixtureBytes(awslogs.FixtureCloudTrail)
	if err != nil {
		t.Fatalf("FixtureBytes: %v", err)
	}
	wantObs, err := awslogs.Projector{TenantID: crashTenant, Region: crashRegion}.
		Project(body, awslogs.Origin{Bucket: crashBucket, Key: crashKey})
	if err != nil {
		t.Fatalf("projecting the fixture: %v", err)
	}
	if len(wantObs) == 0 {
		t.Fatal("the CloudTrail fixture projects to no observations; this test would prove nothing")
	}
	wantIDs := map[string]bool{}
	for _, o := range wantObs {
		wantIDs[o.ID] = true
	}
	if len(wantIDs) != len(wantObs) {
		t.Fatalf("the fixture projects %d observations but only %d distinct IDs", len(wantObs), len(wantIDs))
	}

	// --- phase 1: run until the sink kills the process -----------------------

	out, err := runCrashChild(t, dir, crashPhaseKill, len(wantObs))
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("the kill phase exited with %v, want a signal death.\n%s", err, out)
	}
	status, ok := exitErr.Sys().(syscall.WaitStatus)
	if !ok || !status.Signaled() || status.Signal() != syscall.SIGKILL {
		t.Fatalf("the kill phase did not die of SIGKILL (%v).\n%s", exitErr, out)
	}

	// The record reached the sink...
	afterKill := readSinkLog(t, dir)
	if len(afterKill) != len(wantObs) {
		t.Fatalf("after the crash the sink holds %d observations, want %d: the kill landed in the wrong window.\n%s",
			len(afterKill), len(wantObs), out)
	}
	// ...and was NOT acknowledged. This is the ordering the whole design rests on: if
	// the delete had already happened, the message would be gone and the record,
	// buffered but unacked, would be unrecoverable.
	st := readSQSState(t, dir)
	if len(st.Deleted) != 0 {
		t.Fatalf("the message was deleted before the crash (%v); delete must follow the sink, not precede it", st.Deleted)
	}
	if len(st.InFlight) != 1 {
		t.Fatalf("after the crash %d messages are in flight, want 1", len(st.InFlight))
	}

	// --- phase 2: restart ----------------------------------------------------

	out, err = runCrashChild(t, dir, crashPhaseRestart, 0)
	if err != nil {
		t.Fatalf("the restart phase failed: %v\n%s", err, out)
	}

	afterRestart := readSinkLog(t, dir)

	// At-least-once delivery: the record is re-ingested, because the crash happened
	// before the ack. Anything less would be loss.
	if len(afterRestart) <= len(afterKill) {
		t.Fatalf("the restart ingested %d observations in total, no more than the %d before the crash: the buffered record was lost",
			len(afterRestart), len(afterKill))
	}

	// Exactly-once storage: every ID is one the projection expects, and the distinct
	// set is complete. The duplicates are identical IDs, so a content-addressed store
	// writes one row per observation — which is what makes at-least-once delivery
	// safe (§6.3, D4).
	distinct := map[string]int{}
	for _, id := range afterRestart {
		distinct[id]++
	}
	for id := range distinct {
		if !wantIDs[id] {
			t.Errorf("observation ID %s was stored but is not one the projection produces", id)
		}
	}
	for id := range wantIDs {
		if distinct[id] == 0 {
			t.Errorf("observation ID %s was never stored; the record did not survive the crash", id)
		}
	}
	if len(distinct) != len(wantIDs) {
		t.Errorf("stored %d distinct observation IDs, want %d: the IDs are not stable across processes, so a replay would duplicate rows instead of deduplicating",
			len(distinct), len(wantIDs))
	}

	// The message is acknowledged exactly once, and only after the restart put every
	// observation past the sink a second time.
	st = readSQSState(t, dir)
	if len(st.Deleted) != 1 || st.Deleted[0] != crashMessageID {
		t.Errorf("delete journal = %v, want exactly [%s]", st.Deleted, crashMessageID)
	}

	// The restart went through the stale-handle path, which is the point of modelling
	// the reissue: the replayed record presented the dead process's handle, the queue
	// rejected it, the record was released anyway, and the redelivery was then acked
	// under the new handle. Without this assertion the test would still pass if the
	// fake quietly accepted the old handle — which is how the defect hid.
	if st.StaleDeletes != 1 {
		t.Errorf("the queue saw %d delete attempts with a reissued handle, want 1: the replayed record did not take the stale-handle path",
			st.StaleDeletes)
	}
	if len(st.Stale) != 1 {
		t.Errorf("the queue reissued %d handles, want 1", len(st.Stale))
	}
	if len(st.Queued) != 0 || len(st.InFlight) != 0 {
		t.Errorf("after recovery the queue still holds queued=%d in_flight=%d, want 0/0", len(st.Queued), len(st.InFlight))
	}
	if st.Receives < 2 {
		t.Errorf("the queue was polled %d times across both processes, want at least 2 (one per process)", st.Receives)
	}
}

// runCrashChild re-executes this test binary running only the child test.
func runCrashChild(t *testing.T, dir, phase string, killAfter int) (string, error) {
	t.Helper()

	cmd := exec.Command(os.Args[0], "-test.run=^TestCollectorCrashChild$", "-test.v")
	cmd.Env = append(os.Environ(),
		crashEnvPhase+"="+phase,
		crashEnvDir+"="+dir,
		crashEnvKillAfter+"="+strconv.Itoa(killAfter),
	)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func readSinkLog(t *testing.T, dir string) []string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, "sink.log"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatalf("reading the sink log: %v", err)
	}
	var ids []string
	for _, line := range strings.Split(string(raw), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			ids = append(ids, line)
		}
	}
	return ids
}

func readSQSState(t *testing.T, dir string) *fileSQSState {
	t.Helper()
	st, err := newFileSQS(dir, "").load()
	if err != nil {
		t.Fatalf("reading the SQS state: %v", err)
	}
	return st
}

// Compile-time proof that the file-backed fake is a drop-in for the in-memory one.
var _ awslogs.SQSClient = (*fileSQS)(nil)
