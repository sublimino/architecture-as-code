// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package live

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
)

// s3TestEventName is the event S3 posts once, when a notification configuration is
// first attached to a bucket.
const s3TestEventName = "s3:TestEvent"

// snsNotificationType is the Type field of an SNS notification envelope.
const snsNotificationType = "Notification"

// notificationEnvelope is the union of the three body shapes that legitimately
// arrive on a log queue. They are distinguished by which fields are populated
// rather than by configuration, because a single queue can carry all three: the
// TestEvent on the day the bucket is wired up, direct S3 events if the bucket posts
// to the queue, and SNS-wrapped events if it fans out through a topic first.
type notificationEnvelope struct {
	// SNS envelope.
	Type    string `json:"Type"`
	Message string `json:"Message"`

	// S3 TestEvent.
	Service string `json:"Service"`
	Event   string `json:"Event"`

	// Direct S3 event notification.
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

// ParseS3Notification extracts the object references from an SQS message body.
//
// It handles the raw S3 event notification and the SNS-wrapped envelope, and it
// ignores the one-off `s3:TestEvent` by returning no references and no error.
//
// The three outcomes are deliberately distinct, because the collector treats them
// differently and conflating any two of them loses telemetry:
//
//   - refs, nil — fetch these objects.
//   - nil, nil  — nothing to fetch and nothing wrong. A TestEvent returned as an
//     error would sit in the queue being retried until the redrive policy moved it
//     to a dead-letter queue, and would log an error on every poll until then.
//   - nil, err  — the body is not something we understand. The collector leaves the
//     message in flight on purpose: deleting it would discard a customer's telemetry
//     on the strength of our parser being right about an unfamiliar shape.
//
// Keys are percent-decoded. S3 URL-encodes the object key in the notification and
// encodes spaces as '+', so a parser that skips this step asks for a key that does
// not exist. That failure is a 404 on an object the customer can see in the console,
// which reads as a permissions problem rather than an encoding one.
func ParseS3Notification(body []byte) ([]awslogs.ObjectRef, error) {
	refs, err := parseS3Notification(body, true)
	if err != nil {
		return nil, err
	}
	return refs, nil
}

// parseS3Notification does the work. unwrapSNS is false on the recursive call, so an
// envelope nested inside an envelope is rejected rather than followed: the real
// plumbing nests exactly one level, and an unbounded unwrap is a free amplification
// primitive for anything that can post to the queue.
func parseS3Notification(body []byte, unwrapSNS bool) ([]awslogs.ObjectRef, error) {
	var env notificationEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("awslogs/live: decoding S3 notification: %w", err)
	}

	// A TestEvent is not an object and is not a failure.
	if env.Event == s3TestEventName {
		return nil, nil
	}

	if env.Type == snsNotificationType && env.Message != "" {
		if !unwrapSNS {
			return nil, errors.New("awslogs/live: SNS envelope nested inside an SNS envelope; refusing to unwrap further")
		}
		return parseS3Notification([]byte(env.Message), false)
	}

	refs := make([]awslogs.ObjectRef, 0, len(env.Records))
	for i, r := range env.Records {
		bucket := r.S3.Bucket.Name
		rawKey := r.S3.Object.Key
		if bucket == "" || rawKey == "" {
			// Not every record on a shared queue is an object-created event we can act
			// on. Skipping is right; erroring on the whole message would discard the
			// records alongside it that we can.
			continue
		}
		key, err := url.QueryUnescape(rawKey)
		if err != nil {
			return nil, fmt.Errorf("awslogs/live: record %d: decoding object key %q: %w", i, rawKey, err)
		}
		refs = append(refs, awslogs.ObjectRef{Bucket: bucket, Key: key})
	}

	if len(refs) == 0 {
		return nil, errors.New("awslogs/live: S3 notification names no object")
	}
	return refs, nil
}
