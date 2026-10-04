// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package awsfake provides deterministic, network-free fakes for the three AWS
// seams declared in the awslogs package: SQSClient, S3Fetcher and STSAssumer.
//
// The fakes exist so the whole collector pipeline — poll, fetch, project, buffer,
// sink, ack — can be driven in a unit test with no aws-sdk-go-v2 dependency and no
// network (SLAWS P3-1, ISC-58). The live implementation lands in a later card and
// must satisfy the same interfaces; these fakes then become the differential
// oracle for it.
//
// Determinism rules observed here, because tests assert on ordering:
//   - ReceiveMessages returns messages in enqueue order, never map order.
//   - Every call is recorded in order and readable (Deleted, Fetched, Calls).
//   - Nothing uses time.Now() for a value a caller can observe except credential
//     expiry, which is derived from a fixed clock.
package awsfake

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
)

// ErrNoSuchKey mirrors the S3 NoSuchKey error for an object the fake does not hold.
var ErrNoSuchKey = errors.New("awsfake: NoSuchKey")

// ReceiptHandleIsInvalidError mirrors the SQS ReceiptHandleIsInvalid API error.
//
// It carries an ErrorCode method because that is the shape aws-sdk-go-v2 errors
// have (smithy.APIError), and awslogs.IsStaleReceiptHandle duck-types on exactly
// that method rather than importing the SDK into the core package. So the fake
// exercises the same branch of the predicate the real SDK error does, which is the
// only thing that makes the fake an oracle for live behaviour rather than a
// restatement of it.
type ReceiptHandleIsInvalidError struct {
	ReceiptHandle string
	MessageID     string
}

func (e *ReceiptHandleIsInvalidError) Error() string {
	return fmt.Sprintf("awsfake: ReceiptHandleIsInvalid: the receipt handle %q has expired and been reissued (message %s)",
		e.ReceiptHandle, e.MessageID)
}

// ErrorCode is the smithy.APIError accessor. The string is the literal SQS error
// code, not a paraphrase of it.
func (e *ReceiptHandleIsInvalidError) ErrorCode() string { return "ReceiptHandleIsInvalid" }

// ErrorMessage is the other smithy.APIError accessor the predicate may read. The
// fault classifier is deliberately not implemented: it would need the smithy types
// in this package's import graph, and nothing in the collector branches on it.
func (e *ReceiptHandleIsInvalidError) ErrorMessage() string { return e.Error() }

// FixedNow is the clock the fakes derive every observable time value from, so a
// test asserting on credential expiry is reproducible.
var FixedNow = time.Date(2026, 10, 2, 9, 0, 0, 0, time.UTC)

// SQS is a deterministic in-memory SQSClient.
//
// A message moves queued → in-flight on ReceiveMessages and in-flight → deleted on
// DeleteMessage. A message that is received but never deleted stays in flight, which
// is what makes "a sink error leaves the message undeleted" an assertable property
// rather than an absence.
type SQS struct {
	mu       sync.Mutex
	queueURL string
	queued   []awslogs.Message
	inFlight map[string]awslogs.Message // receipt handle → message
	deleted  []string                   // message IDs, in delete order
	// stale maps a receipt handle this fake has reissued to the message ID it used to
	// name. A delete presented with one of these is the stale-handle failure a
	// restarted consumer hits, and it is reported as such rather than as an unknown
	// handle — the two want opposite handling.
	stale        map[string]string
	redeliveries int
	// ReceiveErr, when non-nil, is returned by the next ReceiveMessages call.
	ReceiveErr error
	// DeleteErr, when non-nil, is returned by every DeleteMessage call.
	DeleteErr error
}

// NewSQS returns an empty SQS fake bound to queueURL.
func NewSQS(queueURL string) *SQS {
	return &SQS{
		queueURL: queueURL,
		inFlight: make(map[string]awslogs.Message),
		stale:    make(map[string]string),
	}
}

// Enqueue appends a message to the queue.
func (q *SQS) Enqueue(m awslogs.Message) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.queued = append(q.queued, m)
}

// ReceiveMessages returns up to maxMessages messages in enqueue order.
func (q *SQS) ReceiveMessages(ctx context.Context, queueURL string, maxMessages int32) ([]awslogs.Message, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	q.mu.Lock()
	defer q.mu.Unlock()

	if queueURL != q.queueURL {
		return nil, fmt.Errorf("awsfake: ReceiveMessages on unexpected queue %q, bound to %q", queueURL, q.queueURL)
	}
	if q.ReceiveErr != nil {
		err := q.ReceiveErr
		q.ReceiveErr = nil
		return nil, err
	}
	if maxMessages <= 0 {
		return nil, fmt.Errorf("awsfake: maxMessages must be positive, got %d", maxMessages)
	}

	n := int(maxMessages)
	if n > len(q.queued) {
		n = len(q.queued)
	}
	out := make([]awslogs.Message, n)
	copy(out, q.queued[:n])
	q.queued = q.queued[n:]
	for _, m := range out {
		q.inFlight[m.ReceiptHandle] = m
	}
	return out, nil
}

// DeleteMessage acknowledges an in-flight message.
func (q *SQS) DeleteMessage(ctx context.Context, queueURL, receiptHandle string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	q.mu.Lock()
	defer q.mu.Unlock()

	if queueURL != q.queueURL {
		return fmt.Errorf("awsfake: DeleteMessage on unexpected queue %q, bound to %q", queueURL, q.queueURL)
	}
	if q.DeleteErr != nil {
		return q.DeleteErr
	}
	if msgID, reissued := q.stale[receiptHandle]; reissued {
		// The handle named a real message once, and the message is still in the queue
		// under a new handle. This is exactly what a restarted consumer presents.
		return &ReceiptHandleIsInvalidError{ReceiptHandle: receiptHandle, MessageID: msgID}
	}
	m, ok := q.inFlight[receiptHandle]
	if !ok {
		return fmt.Errorf("awsfake: DeleteMessage for unknown or already-deleted receipt handle %q", receiptHandle)
	}
	delete(q.inFlight, receiptHandle)
	q.deleted = append(q.deleted, m.MessageID)
	return nil
}

// Deleted returns the message IDs that were acknowledged, in delete order.
func (q *SQS) Deleted() []string {
	q.mu.Lock()
	defer q.mu.Unlock()
	out := make([]string, len(q.deleted))
	copy(out, q.deleted)
	return out
}

// InFlight returns the number of messages received but not deleted.
func (q *SQS) InFlight() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.inFlight)
}

// Remaining returns the number of messages still queued for delivery.
func (q *SQS) Remaining() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.queued)
}

// Redeliver returns every in-flight message to the queue with a NEW receipt handle
// and invalidates the old one, which is what SQS does when a visibility timeout
// expires without a delete.
//
// The reissue is the part that matters and the part the fakes used to get wrong by
// omission. A consumer that crashed after fsyncing a record but before deleting the
// message holds the OLD handle in its buffer; on restart it replays that record and
// tries to delete with the handle it saved. Real SQS rejects that with
// ReceiptHandleIsInvalid. A fake that preserved the handle made the delete succeed,
// so the whole stale-handle failure mode was invisible to every test — and the
// consequence in production is a record the ring can never release, because
// ackAndRelease fails for ever on a handle that will never become valid again.
//
// The message ID is preserved: it is the same message, redelivered.
func (q *SQS) Redeliver() error {
	q.mu.Lock()
	defer q.mu.Unlock()

	if len(q.inFlight) == 0 {
		return nil
	}

	// Deterministic order: tests assert on receive order, and map iteration is not an
	// order. Sort by the handle the message was last delivered under, which tracks
	// enqueue order because handles are derived from message IDs.
	handles := make([]string, 0, len(q.inFlight))
	for handle := range q.inFlight {
		handles = append(handles, handle)
	}
	sort.Strings(handles)

	for _, handle := range handles {
		msg := q.inFlight[handle]
		delete(q.inFlight, handle)
		q.redeliveries++
		// The old handle is now dead. Recording it rather than simply forgetting it is
		// what lets DeleteMessage distinguish "a handle I reissued" — a stale handle,
		// the error a restarted consumer deserves — from "a handle I have never heard
		// of", which is a defect in the caller.
		q.stale[handle] = msg.MessageID
		msg.ReceiptHandle = fmt.Sprintf("%s-redelivery-%d", msg.ReceiptHandle, q.redeliveries)
		q.queued = append(q.queued, msg)
	}
	return nil
}

// S3 is a deterministic in-memory S3Fetcher.
type S3 struct {
	mu      sync.Mutex
	objects map[awslogs.ObjectRef][]byte
	fetched []awslogs.ObjectRef
	// GetErr, when non-nil, is returned by every GetObject call.
	GetErr error
}

// NewS3 returns an empty S3 fake.
func NewS3() *S3 {
	return &S3{objects: make(map[awslogs.ObjectRef][]byte)}
}

// Put stores an object body under ref.
func (s *S3) Put(ref awslogs.ObjectRef, body []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cp := make([]byte, len(body))
	copy(cp, body)
	s.objects[ref] = cp
}

// GetObject returns the complete stored body for ref.
func (s *S3) GetObject(ctx context.Context, ref awslogs.ObjectRef) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	s.fetched = append(s.fetched, ref)
	if s.GetErr != nil {
		return nil, s.GetErr
	}
	body, ok := s.objects[ref]
	if !ok {
		return nil, fmt.Errorf("awsfake: s3://%s/%s: %w", ref.Bucket, ref.Key, ErrNoSuchKey)
	}
	out := make([]byte, len(body))
	copy(out, body)
	return out, nil
}

// Fetched returns the object refs that were requested, in request order.
func (s *S3) Fetched() []awslogs.ObjectRef {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]awslogs.ObjectRef, len(s.fetched))
	copy(out, s.fetched)
	return out
}

// STS is a deterministic STSAssumer that enforces the external ID exactly as a
// customer trust policy would.
type STS struct {
	mu             sync.Mutex
	wantRoleARN    string
	wantExternalID string
	calls          int
}

// NewSTS returns an STS fake that grants credentials only for wantRoleARN presented
// with wantExternalID.
func NewSTS(wantRoleARN, wantExternalID string) *STS {
	return &STS{wantRoleARN: wantRoleARN, wantExternalID: wantExternalID}
}

// AssumeRole returns credentials when roleARN and externalID both match.
func (s *STS) AssumeRole(ctx context.Context, roleARN, externalID string) (awslogs.Credentials, error) {
	if err := ctx.Err(); err != nil {
		return awslogs.Credentials{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++

	if externalID == "" {
		return awslogs.Credentials{}, awslogs.ErrExternalIDRequired
	}
	if roleARN != s.wantRoleARN {
		return awslogs.Credentials{}, fmt.Errorf("awsfake: AccessDenied: role %q is not assumable (expected %q)", roleARN, s.wantRoleARN)
	}
	if externalID != s.wantExternalID {
		return awslogs.Credentials{}, fmt.Errorf("awsfake: AccessDenied: external ID mismatch for role %q", roleARN)
	}
	return awslogs.Credentials{
		AccessKeyID:     "ASIAFAKEACCESSKEYID",
		SecretAccessKey: "fake-secret-access-key",
		SessionToken:    "fake-session-token",
		Expiration:      FixedNow.Add(time.Hour),
	}, nil
}

// Calls returns the number of AssumeRole invocations, successful or not.
func (s *STS) Calls() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls
}

// ObjectCreated builds an SQS message carrying a minimal S3 object-created
// notification for bucket/key, with a receipt handle derived from the message ID so
// ack assertions read clearly.
func ObjectCreated(messageID, bucket, key string) awslogs.Message {
	body, err := json.Marshal(map[string]any{
		"Records": []map[string]any{{
			"eventSource": "aws:s3",
			"eventName":   "ObjectCreated:Put",
			"s3": map[string]any{
				"bucket": map[string]any{"name": bucket},
				"object": map[string]any{"key": key},
			},
		}},
	})
	if err != nil {
		// Unreachable: the literal above is always marshalable.
		panic(fmt.Sprintf("awsfake: marshalling notification: %v", err))
	}
	return awslogs.Message{
		MessageID:     messageID,
		ReceiptHandle: "rh-" + messageID,
		Body:          string(body),
	}
}
