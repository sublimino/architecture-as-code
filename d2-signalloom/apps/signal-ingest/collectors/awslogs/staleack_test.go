// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs_test

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/awsfake"
)

// The defect these tests pin: a record replayed from the WAL after a restart carried
// the receipt handle the previous process received it under. Real SQS reissues the
// handle when the visibility timeout expires and rejects a delete presented with the
// old one, so ackAndRelease failed, returned an error, and the buffer slot was never
// released. The record was then re-projected and re-ingested on every single drain —
// for ever, because the handle it is waiting to ack with can never become valid
// again. One crash, and the collector wedges on its own backlog while duplicating
// store writes.
//
// The resolution relies on Observation.ID being content-addressed (sha256 of the
// evidence ref): the message is still in the queue, SQS will redeliver it, and
// re-ingesting it writes the same rows. So releasing the record without acking it is
// safe, and it is the only option that makes progress. What is NOT safe is doing that
// for a record this process buffered itself, or for a delete that failed for any
// other reason — both of those are a live message we are about to orphan.

// apiError is a stand-in for an aws-sdk-go-v2 / smithy API error: the only thing the
// predicate needs is an ErrorCode method, which is how the core package recognises
// an SDK error without importing the SDK.
type apiError struct {
	code string
	msg  string
}

func (e *apiError) Error() string     { return fmt.Sprintf("api error %s: %s", e.code, e.msg) }
func (e *apiError) ErrorCode() string { return e.code }

func TestIsStaleReceiptHandle_RecognisesTheSDKErrorCodeAndTheExpiryText(t *testing.T) {
	stale := map[string]error{
		"sdk error code": &apiError{
			code: "ReceiptHandleIsInvalid",
			msg:  "The input receipt handle is invalid.",
		},
		"sdk error code wrapped by the live client": fmt.Errorf("awslogs/live: sqs:DeleteMessage %s: %w", testQueue,
			&apiError{code: "ReceiptHandleIsInvalid", msg: "The input receipt handle is invalid."}),
		"sdk error code wrapped twice": fmt.Errorf("awslogs: acknowledging s3://b/k: %w",
			fmt.Errorf("awslogs/live: sqs:DeleteMessage: %w",
				&apiError{code: "ReceiptHandleIsInvalid", msg: "invalid"})),
		// Some SQS responses report the same condition as InvalidParameterValue with
		// the detail in the message, so the text is matched as well as the code.
		"expiry text only": errors.New(
			"InvalidParameterValue: Value ...AQEB... for parameter ReceiptHandle is invalid. Reason: The receipt handle has expired."),
		"code in the message text only": errors.New("sqs: ReceiptHandleIsInvalid"),
		// The fake must land on the same branch as the real thing, or it is not an
		// oracle for it.
		"the awsfake error": &awsfake.ReceiptHandleIsInvalidError{ReceiptHandle: "rh-1", MessageID: "m-1"},
	}
	for name, err := range stale {
		t.Run("stale/"+name, func(t *testing.T) {
			if !awslogs.IsStaleReceiptHandle(err) {
				t.Errorf("IsStaleReceiptHandle(%v) = false, want true", err)
			}
		})
	}

	notStale := map[string]error{
		"nil":            nil,
		"throttled":      errors.New("sqs throttled"),
		"access denied":  &apiError{code: "AccessDenied", msg: "not authorized to perform sqs:DeleteMessage"},
		"queue missing":  &apiError{code: "AWS.SimpleQueueService.NonExistentQueue", msg: "The specified queue does not exist."},
		"network":        errors.New("dial tcp: lookup sqs.us-east-1.amazonaws.com: no such host"),
		"store expired":  errors.New("awslogs: sink rejected observation: the credential has expired"),
		"unknown handle": errors.New(`awsfake: DeleteMessage for unknown or already-deleted receipt handle "rh-1"`),
	}
	for name, err := range notStale {
		t.Run("not stale/"+name, func(t *testing.T) {
			if awslogs.IsStaleReceiptHandle(err) {
				t.Errorf("IsStaleReceiptHandle(%v) = true, want false", err)
			}
		})
	}
}

// staleConfig returns a live config on a caller-owned buffer directory, so two
// collectors in sequence share one ring the way two processes do.
func staleConfig(bufferDir string) awslogs.AWSCollectorConfig {
	return awslogs.AWSCollectorConfig{
		TenantID:   "kusari",
		RoleARN:    testRole,
		ExternalID: testExtID,
		QueueURL:   testQueue,
		Region:     "us-east-1",
		BufferDir:  bufferDir,
		MaxRecords: 10,
	}
}

// bufferARecordThenAbandonIt leaves exactly the on-disk state a crash between the
// durable write and the SQS delete leaves: one fsynced record in the WAL, its message
// in flight, no delete. The sink rejects, so Drain stops before ackAndRelease.
func bufferARecordThenAbandonIt(t *testing.T, cfg awslogs.AWSCollectorConfig, sqs *awsfake.SQS, s3 *awsfake.S3) {
	t.Helper()

	sts := awsfake.NewSTS(testRole, testExtID)
	c, err := awslogs.New(cfg, &orderedSink{failFrom: 1},
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
	if _, err := c.PollOnce(ctx); err == nil {
		t.Fatal("PollOnce succeeded although the sink rejects every observation")
	}
	if ring := c.Ring(); ring == nil || ring.Len() != 1 {
		t.Fatalf("want exactly one record buffered and unacked before the restart, got %d", ring.Len())
	}
	if len(sqs.Deleted()) != 0 {
		t.Fatalf("the message was deleted before the sink accepted it: %v", sqs.Deleted())
	}
	// Close compacts, so the WAL left behind is exactly what a restart replays.
	c.Stop()
}

// A replayed record whose handle SQS has reissued is released from the ring without
// an ack, counted, and left to redelivery.
func TestCollector_ReplayedRecordWithAStaleHandleIsReleasedWithoutAnAck(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ring")
	cfg := staleConfig(dir)

	sqs := awsfake.NewSQS(testQueue)
	s3 := awsfake.NewS3()
	body, err := awslogs.FixtureBytes(awslogs.FixtureCloudTrail)
	if err != nil {
		t.Fatalf("FixtureBytes: %v", err)
	}
	s3.Put(awslogs.ObjectRef{Bucket: testBucket, Key: "AWSLogs/trail-1.json"}, body)
	sqs.Enqueue(awsfake.ObjectCreated("m-1", testBucket, "AWSLogs/trail-1.json"))

	bufferARecordThenAbandonIt(t, cfg, sqs, s3)

	// SQS hands the message back when the visibility timeout expires, under a NEW
	// receipt handle. The handle the buffered record carries is now dead.
	if err := sqs.Redeliver(); err != nil {
		t.Fatalf("Redeliver: %v", err)
	}

	// --- the restart ---------------------------------------------------------

	sink := &orderedSink{}
	c, err := awslogs.New(cfg, sink,
		awslogs.WithMode(string(awslogs.ModeLive)),
		awslogs.WithAWS(sqs, s3, awsfake.NewSTS(testRole, testExtID)),
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

	if ring := c.Ring(); ring == nil || ring.Len() != 1 {
		t.Fatalf("the restart replayed %d records, want the 1 the previous process left", ring.Len())
	}

	// Drain the replayed backlog. The delete fails with a stale handle, which is not
	// a failure of this drain: the record is released and the message stays queued.
	if _, err := c.Drain(ctx); err != nil {
		t.Fatalf("draining a replayed record whose handle has expired must not fail the drain: %v", err)
	}

	if ring := c.Ring(); ring.Len() != 0 {
		t.Errorf("the ring still holds %d records: a record waiting to ack with a handle that can never be valid again wedges the collector for ever",
			ring.Len())
	}
	stats := c.Stats()
	if stats["stale_ack_total"] != 1 {
		t.Errorf("stale_ack_total = %d, want 1: releasing a record without acking it must be visible", stats["stale_ack_total"])
	}
	if stats["acknowledged_total"] != 0 {
		t.Errorf("acknowledged_total = %d, want 0: nothing was acknowledged, the delete was rejected", stats["acknowledged_total"])
	}
	if deleted := sqs.Deleted(); len(deleted) != 0 {
		t.Errorf("Deleted() = %v, want none yet", deleted)
	}

	// The message is still there, so the work is not lost. Processing the redelivery
	// re-ingests the same content-addressed observations and acks with the new handle.
	if n := sqs.Remaining(); n != 1 {
		t.Fatalf("%d messages queued, want the 1 redelivery still waiting", n)
	}
	if _, err := c.PollOnce(ctx); err != nil {
		t.Fatalf("PollOnce on the redelivered message: %v", err)
	}
	if deleted := sqs.Deleted(); len(deleted) != 1 || deleted[0] != "m-1" {
		t.Errorf("Deleted() = %v, want [m-1] exactly once, under the reissued handle", deleted)
	}
	if ring := c.Ring(); ring.Len() != 0 {
		t.Errorf("the ring holds %d records after the redelivery was drained, want 0", ring.Len())
	}
	if len(sink.obs) == 0 {
		t.Error("the sink received nothing; the record was released AND never redelivered, which is loss")
	}
}

// The release-without-ack is scoped to replayed records. A record this process
// buffered itself holds a handle this process was just given, so a stale-handle
// rejection on it is not an expiry — it is a defect (a double drain, a wrong queue, a
// bug in our own handle plumbing) and releasing the slot would orphan a live message.
func TestCollector_StaleHandleOnARecordThisProcessBufferedStaysBuffered(t *testing.T) {
	sink := &orderedSink{}
	sqs := awsfake.NewSQS(testQueue)
	s3 := awsfake.NewS3()

	body, err := awslogs.FixtureBytes(awslogs.FixtureIAM)
	if err != nil {
		t.Fatalf("FixtureBytes: %v", err)
	}
	s3.Put(awslogs.ObjectRef{Bucket: testBucket, Key: "AWSLogs/iam-1.json"}, body)
	sqs.Enqueue(awsfake.ObjectCreated("m-1", testBucket, "AWSLogs/iam-1.json"))
	// A stale-handle rejection, injected rather than earned, on a record that was
	// never replayed.
	sqs.DeleteErr = &awsfake.ReceiptHandleIsInvalidError{ReceiptHandle: "rh-m-1", MessageID: "m-1"}

	c, err := awslogs.New(liveConfig(t), sink,
		awslogs.WithMode(string(awslogs.ModeLive)),
		awslogs.WithAWS(sqs, s3, awsfake.NewSTS(testRole, testExtID)),
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
		t.Fatal("PollOnce returned nil although the delete was rejected for a record this process buffered")
	}
	if ring := c.Ring(); ring == nil || ring.Len() != 1 {
		t.Errorf("the buffer holds %d records, want 1: the slot must not be released for a handle this process was just issued",
			ring.Len())
	}
	if stats := c.Stats(); stats["stale_ack_total"] != 0 {
		t.Errorf("stale_ack_total = %d, want 0: the exemption is for replayed records only", stats["stale_ack_total"])
	}
}

// And a replayed record whose delete fails for a reason that is NOT a stale handle
// keeps today's behaviour too: still buffered, still unacked, error returned. The
// exemption is narrow by construction — it is a predicate on the error, not on the
// fact of having restarted.
func TestCollector_ReplayedRecordWithANonStaleDeleteFailureStaysBuffered(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ring")
	cfg := staleConfig(dir)

	sqs := awsfake.NewSQS(testQueue)
	s3 := awsfake.NewS3()
	body, err := awslogs.FixtureBytes(awslogs.FixtureCloudTrail)
	if err != nil {
		t.Fatalf("FixtureBytes: %v", err)
	}
	s3.Put(awslogs.ObjectRef{Bucket: testBucket, Key: "AWSLogs/trail-1.json"}, body)
	sqs.Enqueue(awsfake.ObjectCreated("m-1", testBucket, "AWSLogs/trail-1.json"))

	bufferARecordThenAbandonIt(t, cfg, sqs, s3)

	sqs.DeleteErr = errSQSThrottled

	c, err := awslogs.New(cfg, &orderedSink{},
		awslogs.WithMode(string(awslogs.ModeLive)),
		awslogs.WithAWS(sqs, s3, awsfake.NewSTS(testRole, testExtID)),
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

	if _, err := c.Drain(ctx); err == nil {
		t.Fatal("Drain returned nil although the delete failed for a reason that is not an expired handle")
	}
	if ring := c.Ring(); ring == nil || ring.Len() != 1 {
		t.Errorf("the buffer holds %d records, want 1: a throttled delete is retryable, so the record must stay", ring.Len())
	}
	if stats := c.Stats(); stats["stale_ack_total"] != 0 {
		t.Errorf("stale_ack_total = %d, want 0", stats["stale_ack_total"])
	}
}
