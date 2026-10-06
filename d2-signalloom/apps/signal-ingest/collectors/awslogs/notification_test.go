// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs_test

import (
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
)

// There is one notification parser, in this package, and the live package calls it.
//
// Before this test there were two: awslogs.objectRefsFrom, which read a direct S3
// event and did NOT percent-decode the key, and live.ParseS3Notification, which did.
// The divergence is not cosmetic. S3 URL-encodes the object key in the notification
// and encodes a space as '+', so the undecoded key names an object that does not
// exist — and the failure arrives as a 404 on an object the customer can see in their
// console, which reads as a permissions problem rather than an encoding one. Whether
// a key round-tripped therefore depended on which parser happened to be wired, which
// is exactly the kind of difference between fixture and live that a pilot discovers
// in production.
func TestParseS3Notification_DecodesTheObjectKeyInTheCorePackage(t *testing.T) {
	cases := map[string]struct {
		rawKey  string
		wantKey string
	}{
		// S3 encodes a space as '+' in the notification, not as %20.
		"plus is a space":            {`AWSLogs/my+log.json`, `AWSLogs/my log.json`},
		"percent-20 is also a space": {`AWSLogs/my%20log.json`, `AWSLogs/my log.json`},
		"both forms in one key":      {`AWSLogs/a+b%20c.json`, `AWSLogs/a b c.json`},
		"percent-encoded equals":     {`AWSLogs/my%3Dfile.json`, `AWSLogs/my=file.json`},
		"unencoded key is unchanged": {`AWSLogs/plain.json`, `AWSLogs/plain.json`},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			body := `{"Records":[{"s3":{"bucket":{"name":"kusari-trail"},"object":{"key":"` + tc.rawKey + `"}}}]}`

			refs, err := awslogs.ParseS3Notification([]byte(body))
			if err != nil {
				t.Fatalf("ParseS3Notification: %v", err)
			}
			if len(refs) != 1 {
				t.Fatalf("got %d refs %+v, want 1", len(refs), refs)
			}
			if refs[0].Key != tc.wantKey {
				t.Errorf("key = %q, want %q (the raw notification key was %q)", refs[0].Key, tc.wantKey, tc.rawKey)
			}
			if refs[0].Bucket != "kusari-trail" {
				t.Errorf("bucket = %q, want %q", refs[0].Bucket, "kusari-trail")
			}
		})
	}
}

// The core parser understands the SNS envelope too, because it IS the live parser
// now. A collector running without the live package linked in still has to cope with
// a queue fed through a topic.
func TestParseS3Notification_UnwrapsTheSNSEnvelopeInTheCorePackage(t *testing.T) {
	inner := `{\"Records\":[{\"s3\":{\"bucket\":{\"name\":\"b\"},\"object\":{\"key\":\"one.json\"}}}]}`
	body := `{"Type":"Notification","TopicArn":"arn:aws:sns:us-east-1:123456789012:kusari","Message":"` + inner + `"}`

	refs, err := awslogs.ParseS3Notification([]byte(body))
	if err != nil {
		t.Fatalf("ParseS3Notification on an SNS envelope: %v", err)
	}
	if len(refs) != 1 || refs[0].Bucket != "b" || refs[0].Key != "one.json" {
		t.Fatalf("got %+v, want one ref s3://b/one.json", refs)
	}
}

// The three parser outcomes, which the collector treats differently. Conflating any
// two of them either loses telemetry or drains a queue silently.
func TestParseS3Notification_DistinguishesNothingToDoFromCannotUnderstand(t *testing.T) {
	nothingToDo := map[string]string{
		"s3 test event":       `{"Service":"Amazon S3","Event":"s3:TestEvent","Bucket":"b"}`,
		"empty records":       `{"Records":[]}`,
		"unrelated json":      `{"detail-type":"Scheduled Event","source":"aws.events"}`,
		"record without key":  `{"Records":[{"s3":{"bucket":{"name":"b"},"object":{}}}]}`,
		"record without name": `{"Records":[{"s3":{"bucket":{},"object":{"key":"k"}}}]}`,
	}
	for name, body := range nothingToDo {
		t.Run("nothing to do/"+name, func(t *testing.T) {
			refs, err := awslogs.ParseS3Notification([]byte(body))
			if err != nil {
				t.Fatalf("want no error so the collector can discard and acknowledge, got %v", err)
			}
			if len(refs) != 0 {
				t.Fatalf("want no refs, got %+v", refs)
			}
		})
	}

	cannotUnderstand := map[string]string{
		"not json":        `{`,
		"undecodable key": `{"Records":[{"s3":{"bucket":{"name":"b"},"object":{"key":"bad%zz"}}}]}`,
	}
	for name, body := range cannotUnderstand {
		t.Run("cannot understand/"+name, func(t *testing.T) {
			if refs, err := awslogs.ParseS3Notification([]byte(body)); err == nil {
				t.Fatalf("want an error so the message stays in flight for the redrive policy, got refs %+v", refs)
			}
		})
	}
}

// An SNS envelope is unwrapped exactly once, so a crafted body is not an
// amplification primitive for anything that can post to the queue.
func TestParseS3Notification_RefusesNestedSNSEnvelopesInTheCorePackage(t *testing.T) {
	inner := `{\"Type\":\"Notification\",\"Message\":\"{}\"}`
	body := `{"Type":"Notification","Message":"` + inner + `"}`

	if _, err := awslogs.ParseS3Notification([]byte(body)); err == nil {
		t.Fatal("a doubly-wrapped envelope must be rejected rather than unwrapped recursively")
	}
}
