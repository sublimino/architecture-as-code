// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs_test

import (
	"context"
	"errors"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/awsfake"
)

// The defect these tests pin: a message that yields no object references was pushed
// nowhere and acknowledged never.
//
// The ack path is driven from the ring — Drain peeks a record, puts it past the sink
// and then deletes the record's message — so a message that produces no record has
// nothing to carry its receipt handle to a delete. It stayed in flight until its
// visibility timeout expired, came back, produced no record again, and repeated for
// as long as the queue existed. Every bucket gets exactly one `s3:TestEvent` the day
// its notification configuration is attached, so every pilot starts with one of
// these, permanently.
//
// The fix is to acknowledge it at the point the parser says there is nothing to do,
// without touching the ring or the sink, and to count it. The counter matters as
// much as the delete: "we deleted some messages without storing anything" has to be
// a number an operator can read, or a misconfigured notification filter that drops
// every real event looks identical to a quiet account.

// discardCollector wires a live-mode collector to the fakes with the given raw
// message bodies queued and NOTHING staged in S3 — any fetch is therefore a failure
// the test will see rather than a silent success.
func discardCollector(t *testing.T, sink awslogs.Sink, bodies ...string) (*awslogs.Collector, *awsfake.SQS, *awsfake.S3) {
	t.Helper()

	sqs := awsfake.NewSQS(testQueue)
	s3 := awsfake.NewS3()
	sts := awsfake.NewSTS(testRole, testExtID)

	for i, body := range bodies {
		sqs.Enqueue(awslogs.Message{
			MessageID:     msgID(i),
			ReceiptHandle: "rh-" + msgID(i),
			Body:          body,
		})
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

func msgID(i int) string { return "m-discard-" + string(rune('1'+i)) }

// errSQSThrottled stands in for a transient SQS failure that is NOT a receipt-handle
// problem: the handle is fine, the call did not land. It must never be mistaken for
// a stale handle, which is why it has no error code and says nothing about handles.
var errSQSThrottled = errors.New("sqs throttled")

// A message that names no object is deleted on the spot, counted as discarded, and
// never reaches the ring or the sink.
func TestCollector_EmptyNotificationIsDiscardedAndAcknowledged(t *testing.T) {
	cases := map[string]string{
		// The one every bucket posts when its notification configuration is attached.
		"s3 test event": `{"Service":"Amazon S3","Event":"s3:TestEvent","Time":"2026-10-04T12:00:00.000Z","Bucket":"kusari-trail","RequestId":"ABCDEF0123456789"}`,
		// A shared queue carries other people's events too.
		"unrelated event": `{"detail-type":"Scheduled Event","source":"aws.events","detail":{}}`,
		// Valid JSON, recognisably an S3 notification, but naming nothing fetchable.
		"s3 record with no key": `{"Records":[{"eventSource":"aws:s3","s3":{"bucket":{"name":"kusari-trail"},"object":{}}}]}`,
		"empty record set":      `{"Records":[]}`,
	}

	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			sink := &orderedSink{}
			c, sqs, s3 := discardCollector(t, sink, body)

			ctx := context.Background()
			if err := c.Start(ctx); err != nil {
				t.Fatalf("Start: %v", err)
			}
			defer c.Stop()

			acked, err := c.PollOnce(ctx)
			if err != nil {
				t.Fatalf("PollOnce on a message that names no object must not fail: %v", err)
			}

			// Acknowledged: the message is gone from the queue entirely, not parked in
			// flight waiting for a visibility timeout that will hand it back.
			if deleted := sqs.Deleted(); len(deleted) != 1 || deleted[0] != msgID(0) {
				t.Errorf("Deleted() = %v, want [%s]: an empty notification redelivers for ever if it is never deleted",
					deleted, msgID(0))
			}
			if n := sqs.InFlight(); n != 0 {
				t.Errorf("%d messages left in flight, want 0", n)
			}
			if n := sqs.Remaining(); n != 0 {
				t.Errorf("%d messages still queued, want 0", n)
			}

			// Counted, so the discard is visible rather than a silent drain.
			stats := c.Stats()
			if stats["discarded_total"] != 1 {
				t.Errorf("discarded_total = %d, want 1", stats["discarded_total"])
			}
			if stats["unparseable_total"] != 0 {
				t.Errorf("unparseable_total = %d, want 0: this body parsed fine, it just named no object",
					stats["unparseable_total"])
			}
			if stats["errors_total"] != 0 {
				t.Errorf("errors_total = %d, want 0: nothing went wrong here", stats["errors_total"])
			}

			// The ring and the sink were never involved. A discard that pushed an empty
			// record would consume a buffer slot and emit an observation describing
			// nothing.
			if ring := c.Ring(); ring == nil || ring.Len() != 0 {
				t.Errorf("the ring holds %d records, want 0: a discard must not touch the buffer", ring.Len())
			}
			if len(sink.obs) != 0 {
				t.Errorf("the sink received %d observations, want 0", len(sink.obs))
			}
			if stats["processed_total"] != 0 {
				t.Errorf("processed_total = %d, want 0", stats["processed_total"])
			}
			if fetched := s3.Fetched(); len(fetched) != 0 {
				t.Errorf("s3:GetObject was called for %+v; a message naming no object names nothing to fetch", fetched)
			}
			// A discard is not a durability claim, so it does not move the ack counter
			// that the ordering tests read as "put past the sink, then acknowledged".
			if stats["acknowledged_total"] != 0 {
				t.Errorf("acknowledged_total = %d, want 0: acknowledged_total means an observation reached the sink",
					stats["acknowledged_total"])
			}
			if acked != 0 {
				t.Errorf("PollOnce returned %d acked records, want 0: no record was drained", acked)
			}
		})
	}
}

// A body that is not JSON at all is the opposite case and must behave the opposite
// way: left in flight for the queue's redrive policy, and counted separately.
//
// Keeping the two counters apart is the point. If an unparseable body were discarded
// alongside an empty one, a parser bug or a change in AWS's notification shape would
// quietly drain a customer's whole queue and the only evidence would be a store with
// no rows in it.
func TestCollector_UnparseableNotificationIsNeitherDeletedNorDiscarded(t *testing.T) {
	cases := map[string]string{
		"not json":          `{"Records":[`,
		"not json at all":   `this is not a notification`,
		"undecodable key":   `{"Records":[{"s3":{"bucket":{"name":"b"},"object":{"key":"bad%zz"}}}]}`,
		"doubly nested sns": `{"Type":"Notification","Message":"{\"Type\":\"Notification\",\"Message\":\"{}\"}"}`,
	}

	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			sink := &orderedSink{}
			c, sqs, _ := discardCollector(t, sink, body)

			ctx := context.Background()
			if err := c.Start(ctx); err != nil {
				t.Fatalf("Start: %v", err)
			}
			defer c.Stop()

			if _, err := c.PollOnce(ctx); err != nil {
				t.Fatalf("PollOnce: a poison message is skipped, not a poll failure: %v", err)
			}

			if deleted := sqs.Deleted(); len(deleted) != 0 {
				t.Errorf("Deleted() = %v, want none: deleting a body we cannot parse discards a customer's telemetry on the strength of our parser being right",
					deleted)
			}
			if n := sqs.InFlight(); n != 1 {
				t.Errorf("%d messages in flight, want 1: the message must stay in flight for the redrive policy", n)
			}

			stats := c.Stats()
			if stats["unparseable_total"] != 1 {
				t.Errorf("unparseable_total = %d, want 1", stats["unparseable_total"])
			}
			if stats["discarded_total"] != 0 {
				t.Errorf("discarded_total = %d, want 0: an unparseable body is not a discard, and conflating the two makes a poisoned queue look like a drained one",
					stats["discarded_total"])
			}
			if stats["errors_total"] != 1 {
				t.Errorf("errors_total = %d, want 1", stats["errors_total"])
			}
			if ring := c.Ring(); ring == nil || ring.Len() != 0 {
				t.Errorf("the ring holds %d records, want 0", ring.Len())
			}
		})
	}
}

// A real notification alongside a TestEvent in the same receive batch: the object is
// ingested and acked through the durable path, the TestEvent is discarded, and
// neither interferes with the other.
func TestCollector_DiscardsTheTestEventWithoutDisturbingARealNotification(t *testing.T) {
	sink := &orderedSink{}

	sqs := awsfake.NewSQS(testQueue)
	s3 := awsfake.NewS3()
	sts := awsfake.NewSTS(testRole, testExtID)

	body, err := awslogs.FixtureBytes(awslogs.FixtureCloudTrail)
	if err != nil {
		t.Fatalf("FixtureBytes: %v", err)
	}
	s3.Put(awslogs.ObjectRef{Bucket: testBucket, Key: "AWSLogs/trail-1.json"}, body)

	sqs.Enqueue(awslogs.Message{
		MessageID:     "m-test-event",
		ReceiptHandle: "rh-m-test-event",
		Body:          `{"Service":"Amazon S3","Event":"s3:TestEvent","Bucket":"kusari-trail"}`,
	})
	sqs.Enqueue(awsfake.ObjectCreated("m-real", testBucket, "AWSLogs/trail-1.json"))

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

	acked, err := c.PollOnce(ctx)
	if err != nil {
		t.Fatalf("PollOnce: %v", err)
	}
	if acked != 1 {
		t.Errorf("PollOnce drained %d records, want 1 (the real object; the TestEvent is not a record)", acked)
	}

	// Both messages are off the queue, by the two different routes.
	deleted := sqs.Deleted()
	if len(deleted) != 2 {
		t.Fatalf("Deleted() = %v, want both messages acknowledged", deleted)
	}
	seen := map[string]bool{}
	for _, id := range deleted {
		seen[id] = true
	}
	if !seen["m-test-event"] || !seen["m-real"] {
		t.Errorf("Deleted() = %v, want m-test-event (discarded) and m-real (drained)", deleted)
	}

	stats := c.Stats()
	if stats["discarded_total"] != 1 {
		t.Errorf("discarded_total = %d, want 1", stats["discarded_total"])
	}
	if stats["acknowledged_total"] != 1 {
		t.Errorf("acknowledged_total = %d, want 1 (the real object only)", stats["acknowledged_total"])
	}
	if len(sink.obs) == 0 {
		t.Error("the sink received nothing; the real notification was lost alongside the discarded one")
	}
	if fetched := s3.Fetched(); len(fetched) != 1 {
		t.Errorf("s3:GetObject called %d times %+v, want once for the real object only", len(fetched), fetched)
	}
}

// A discard whose delete fails does not take the poll down and does not count as a
// discard: the message is still in flight, SQS will redeliver it, and the next poll
// discards it again. Idempotent by construction, because the discard touches no
// durable state.
func TestCollector_DiscardSurvivesADeleteFailureAndRetriesOnTheNextPoll(t *testing.T) {
	sink := &orderedSink{}
	c, sqs, _ := discardCollector(t, sink,
		`{"Service":"Amazon S3","Event":"s3:TestEvent","Bucket":"kusari-trail"}`)

	sqs.DeleteErr = errSQSThrottled

	ctx := context.Background()
	if err := c.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer c.Stop()

	if _, err := c.PollOnce(ctx); err != nil {
		t.Fatalf("a failed discard-delete must not fail the poll; the message simply redelivers: %v", err)
	}
	if stats := c.Stats(); stats["discarded_total"] != 0 {
		t.Errorf("discarded_total = %d, want 0: the delete did not land, so nothing was discarded", stats["discarded_total"])
	}
	if stats := c.Stats(); stats["errors_total"] != 1 {
		t.Errorf("errors_total = %d, want 1: a failed delete is an error even when it is recoverable", stats["errors_total"])
	}
	if n := sqs.InFlight(); n != 1 {
		t.Errorf("%d messages in flight, want 1", n)
	}

	// SQS hands the message back when the visibility timeout expires. The second
	// attempt succeeds, so the discard is eventually consistent rather than lost.
	sqs.DeleteErr = nil
	if err := sqs.Redeliver(); err != nil {
		t.Fatalf("Redeliver: %v", err)
	}
	if _, err := c.PollOnce(ctx); err != nil {
		t.Fatalf("PollOnce after redelivery: %v", err)
	}
	if stats := c.Stats(); stats["discarded_total"] != 1 {
		t.Errorf("discarded_total = %d, want 1 after the redelivery was discarded successfully", stats["discarded_total"])
	}
	if len(sqs.Deleted()) != 1 {
		t.Errorf("Deleted() = %v, want exactly one delete", sqs.Deleted())
	}
}
