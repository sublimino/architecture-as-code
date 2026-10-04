// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package live_test

import (
	"encoding/json"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/live"
)

// rawS3Event is the body S3 posts directly to SQS.
const rawS3Event = `{
  "Records": [
    {
      "eventSource": "aws:s3",
      "eventName": "ObjectCreated:Put",
      "s3": {
        "bucket": {"name": "kusari-trail"},
        "object": {"key": "AWSLogs/123456789012/CloudTrail/us-east-1/2026/10/04/trail-1.json.gz"}
      }
    }
  ]
}`

// s3TestEvent is the one-off message S3 posts when a notification configuration is
// first attached to a bucket. It names no object and must never be treated as one.
const s3TestEvent = `{
  "Service": "Amazon S3",
  "Event": "s3:TestEvent",
  "Time": "2026-10-04T12:00:00.000Z",
  "Bucket": "kusari-trail",
  "RequestId": "ABCDEF0123456789",
  "HostId": "abcdef"
}`

// snsEnvelope wraps an arbitrary S3 event body in the SNS notification shape, which
// is what arrives when the bucket fans out through a topic rather than posting to the
// queue directly. Both plumbings are supported by the trust document's §2, so both
// have to parse.
func snsEnvelope(t *testing.T, inner string) string {
	t.Helper()
	body, err := json.Marshal(map[string]any{
		"Type":      "Notification",
		"MessageId": "11111111-2222-3333-4444-555555555555",
		"TopicArn":  "arn:aws:sns:us-east-1:123456789012:kusari-logs",
		"Subject":   "Amazon S3 Notification",
		"Message":   inner,
		"Timestamp": "2026-10-04T12:00:00.000Z",
	})
	if err != nil {
		t.Fatalf("marshalling SNS envelope: %v", err)
	}
	return string(body)
}

func TestParseS3Notification_RawS3Event(t *testing.T) {
	refs, err := live.ParseS3Notification([]byte(rawS3Event))
	if err != nil {
		t.Fatalf("ParseS3Notification: %v", err)
	}
	want := []awslogs.ObjectRef{{
		Bucket: "kusari-trail",
		Key:    "AWSLogs/123456789012/CloudTrail/us-east-1/2026/10/04/trail-1.json.gz",
	}}
	assertRefs(t, refs, want)
}

func TestParseS3Notification_SNSWrappedEvent(t *testing.T) {
	refs, err := live.ParseS3Notification([]byte(snsEnvelope(t, rawS3Event)))
	if err != nil {
		t.Fatalf("ParseS3Notification on an SNS envelope: %v", err)
	}
	want := []awslogs.ObjectRef{{
		Bucket: "kusari-trail",
		Key:    "AWSLogs/123456789012/CloudTrail/us-east-1/2026/10/04/trail-1.json.gz",
	}}
	assertRefs(t, refs, want)
}

// A TestEvent is not an error and is not an object. Returning an error would park it
// in flight as a poison message forever; returning a ref would send the collector
// fetching an object that does not exist.
func TestParseS3Notification_IgnoresTestEvent(t *testing.T) {
	for name, body := range map[string]string{
		"direct":     s3TestEvent,
		"sns-nested": snsEnvelope(t, s3TestEvent),
	} {
		t.Run(name, func(t *testing.T) {
			refs, err := live.ParseS3Notification([]byte(body))
			if err != nil {
				t.Fatalf("a TestEvent must not be an error, got %v", err)
			}
			if len(refs) != 0 {
				t.Fatalf("a TestEvent names no object, got %d refs: %+v", len(refs), refs)
			}
		})
	}
}

// S3 percent-encodes object keys in the notification and encodes spaces as '+'. A
// parser that does not decode fetches a key that does not exist, so the object is
// silently never ingested while the message is acked.
func TestParseS3Notification_DecodesTheObjectKey(t *testing.T) {
	body := `{"Records":[{"s3":{"bucket":{"name":"b"},"object":{"key":"AWSLogs/my+log%3Dfile%20%281%29.json"}}}]}`
	refs, err := live.ParseS3Notification([]byte(body))
	if err != nil {
		t.Fatalf("ParseS3Notification: %v", err)
	}
	assertRefs(t, refs, []awslogs.ObjectRef{{Bucket: "b", Key: "AWSLogs/my log=file (1).json"}})
}

func TestParseS3Notification_MultipleRecords(t *testing.T) {
	body := `{"Records":[
		{"s3":{"bucket":{"name":"b"},"object":{"key":"one.json"}}},
		{"s3":{"bucket":{"name":"b"},"object":{"key":"two.json"}}}
	]}`
	refs, err := live.ParseS3Notification([]byte(body))
	if err != nil {
		t.Fatalf("ParseS3Notification: %v", err)
	}
	assertRefs(t, refs, []awslogs.ObjectRef{
		{Bucket: "b", Key: "one.json"},
		{Bucket: "b", Key: "two.json"},
	})
}

func TestParseS3Notification_RejectsUnparseableAndEmpty(t *testing.T) {
	for name, body := range map[string]string{
		"not json":            `{`,
		"no records":          `{"Records":[]}`,
		"record without key":  `{"Records":[{"s3":{"bucket":{"name":"b"},"object":{}}}]}`,
		"record without name": `{"Records":[{"s3":{"bucket":{},"object":{"key":"k"}}}]}`,
		"undecodable key":     `{"Records":[{"s3":{"bucket":{"name":"b"},"object":{"key":"bad%zz"}}}]}`,
	} {
		t.Run(name, func(t *testing.T) {
			if refs, err := live.ParseS3Notification([]byte(body)); err == nil {
				t.Fatalf("want an error so the message stays in flight for the redrive policy, got refs %+v", refs)
			}
		})
	}
}

// The SNS envelope is unwrapped exactly once. A Message that itself claims to be an
// SNS notification is not followed, so a crafted body cannot drive unbounded nesting.
func TestParseS3Notification_DoesNotRecurseUnbounded(t *testing.T) {
	inner := snsEnvelope(t, rawS3Event)
	if _, err := live.ParseS3Notification([]byte(snsEnvelope(t, inner))); err == nil {
		t.Fatal("a doubly-wrapped envelope must be rejected rather than unwrapped recursively")
	}
}

func assertRefs(t *testing.T, got, want []awslogs.ObjectRef) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("got %d refs %+v, want %d %+v", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("ref %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}
