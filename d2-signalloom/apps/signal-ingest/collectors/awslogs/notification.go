// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
)

// s3TestEventName is the event S3 posts once, when a notification configuration is
// first attached to a bucket.
const s3TestEventName = "s3:TestEvent"

// snsNotificationType is the Type field of an SNS notification envelope.
const snsNotificationType = "Notification"

// notificationEnvelope is the union of the body shapes that legitimately arrive on a
// log queue. They are distinguished by which fields are populated rather than by
// configuration, because a single queue can carry all of them: the TestEvent on the
// day the bucket is wired up, direct S3 events if the bucket posts to the queue, and
// SNS-wrapped events if it fans out through a topic first.
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

// ParseS3Notification extracts the object references from one SQS message body.
//
// This is THE notification parser. It lives in the core package, with no AWS SDK in
// its import graph, and the `live` package calls it rather than carrying its own —
// see live.ParseS3Notification. There were two implementations before, and the one
// wired into the fixture path did not percent-decode the object key, so whether a key
// with a space in it round-tripped depended on which package happened to supply the
// parser. A divergence between the two paths that only shows up on a customer's
// bucket is the worst place to keep a second copy of anything.
//
// The two non-error outcomes are deliberately distinct, because the collector treats
// them differently and conflating them either loses telemetry or drains a queue:
//
//   - refs, nil — fetch these objects.
//   - nil, nil  — nothing to fetch and nothing wrong. A TestEvent, an unrelated
//     event on a shared queue, or an S3 record with no bucket or key. The collector
//     discards and acknowledges these (PollOnce), because the alternative is a
//     message redelivered for ever: it never reaches the ring, so nothing ever acks
//     it, and it reappears on every poll until the redrive policy moves it.
//   - nil, err  — the body is not JSON at all, or names a key we cannot decode. The
//     collector leaves the message in flight on purpose and counts it: deleting it
//     would discard a customer's telemetry on the strength of our parser being right
//     about an unfamiliar shape, and the queue's redrive policy is the correct place
//     for a poison message.
//
// Keys are percent-decoded. S3 URL-encodes the object key in the notification and
// encodes spaces as '+', so a parser that skips this step asks for a key that does
// not exist. That failure is a 404 on an object the customer can see in the console,
// which reads as a permissions problem rather than an encoding one.
func ParseS3Notification(body []byte) ([]ObjectRef, error) {
	return parseS3Notification(body, true)
}

// parseS3Notification does the work. unwrapSNS is false on the recursive call, so an
// envelope nested inside an envelope is rejected rather than followed: the real
// plumbing nests exactly one level, and an unbounded unwrap is a free amplification
// primitive for anything that can post to the queue.
func parseS3Notification(body []byte, unwrapSNS bool) ([]ObjectRef, error) {
	var env notificationEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("awslogs: decoding S3 notification: %w", err)
	}

	// A TestEvent is not an object and is not a failure.
	if env.Event == s3TestEventName {
		return nil, nil
	}

	if env.Type == snsNotificationType && env.Message != "" {
		if !unwrapSNS {
			return nil, errors.New("awslogs: SNS envelope nested inside an SNS envelope; refusing to unwrap further")
		}
		return parseS3Notification([]byte(env.Message), false)
	}

	refs := make([]ObjectRef, 0, len(env.Records))
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
			return nil, fmt.Errorf("awslogs: record %d: decoding object key %q: %w", i, rawKey, err)
		}
		refs = append(refs, ObjectRef{Bucket: bucket, Key: key})
	}

	if len(refs) == 0 {
		// Nothing to do, and nothing wrong: see the outcome contract on
		// ParseS3Notification. This used to be an error, which made every TestEvent a
		// permanent poison message.
		return nil, nil
	}
	return refs, nil
}

// objectRefsFrom is the default NotificationParser: it adapts ParseS3Notification to
// the string body that awslogs.Message carries.
func objectRefsFrom(body string) ([]ObjectRef, error) {
	return ParseS3Notification([]byte(body))
}
