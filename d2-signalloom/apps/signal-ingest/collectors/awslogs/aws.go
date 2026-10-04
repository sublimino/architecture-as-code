// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"context"
	"errors"
	"time"
)

// ErrExternalIDRequired is returned when a role assumption is attempted without an
// external ID. SLAWS §2.1 makes the external ID mandatory, not optional: it is the
// only thing standing between a customer's read-only trust policy and the classic
// confused-deputy, so an empty value is a configuration defect and never a default.
var ErrExternalIDRequired = errors.New("awslogs: external ID is required for sts:AssumeRole")

// Credentials is the time-bounded, read-only credential set returned by an STSAssumer.
//
// Nothing here is ever projected onto an Observation. The negative label contract
// (see contract_doc.go) forbids a session token or access key ID reaching the store
// in any column, and that applies to our own credentials as much as to a customer's
// CloudTrail payload.
type Credentials struct {
	AccessKeyID     string
	SecretAccessKey string
	SessionToken    string
	Expiration      time.Time
}

// Message is one SQS message. For the awslogs collector the body is an S3
// object-created notification naming the object to fetch.
//
// ReceiptHandle is the ack token: it is passed to SQSClient.DeleteMessage and only
// after every observation derived from this message has been accepted by the sink
// (SLAWS §2.1, ISC-35).
type Message struct {
	MessageID     string
	ReceiptHandle string
	Body          string
}

// ObjectRef names a single object in a customer S3 bucket. The bucket remains the
// system of record for raw events; Signal Loom stores only a reference to it
// (Observation.RawEvidenceRef, `s3://<bucket>/<key>#<record-index>`).
type ObjectRef struct {
	Bucket string `json:"bucket"`
	Key    string `json:"key"`
}

// SQSClient is the queue seam. The assumed role grants sqs:ReceiveMessage and
// sqs:DeleteMessage and nothing else.
//
// Contract:
//   - ReceiveMessages returns at most maxMessages messages and never blocks forever;
//     an empty slice with a nil error means "nothing queued", which is not an error.
//   - DeleteMessage is the acknowledgement. Calling it is a durability claim: the
//     caller is asserting that every observation from the message is past the sink.
//   - Both reject a queueURL other than the one the client is bound to, so a
//     misconfigured collector fails loudly instead of silently draining nothing.
type SQSClient interface {
	ReceiveMessages(ctx context.Context, queueURL string, maxMessages int32) ([]Message, error)
	DeleteMessage(ctx context.Context, queueURL, receiptHandle string) error
}

// S3Fetcher is the object seam. The assumed role grants s3:GetObject and nothing else.
//
// Contract: GetObject returns the complete object body, or an error. A partial body
// with a nil error is a defect — the projection would silently emit fewer
// observations than the object contains and the message would still be acked.
type S3Fetcher interface {
	GetObject(ctx context.Context, ref ObjectRef) ([]byte, error)
}

// STSAssumer is the trust seam.
//
// Contract: AssumeRole must return ErrExternalIDRequired (or an error wrapping it)
// when externalID is empty, and must fail when the external ID does not match the
// one in the customer's trust policy. Implementations never widen the requested
// role's permissions and never retain the credentials beyond their expiry.
type STSAssumer interface {
	AssumeRole(ctx context.Context, roleARN, externalID string) (Credentials, error)
}
