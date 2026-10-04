// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package live implements the three awslogs AWS seams on aws-sdk-go-v2.
//
// It is a separate package from awslogs on purpose. The core collector, its
// projection and its disk ring buffer must build and test without the AWS SDK in the
// import graph: fixture mode is the local EAP path (proposal §2.1) and the contract
// tests that enforce the §2.3 label contract are the project's main guard rail. If
// the SDK were imported by the core package, every one of those would carry ~40
// transitive modules, and a build tag would be the only way to get them back —
// which is how a fixture build ends up untested.
//
// Importing this package has one side effect by design: it registers itself as the
// collector's live client factory (see register.go), so a deployment that wants live
// mode links this package in and a deployment that does not, does not.
package live

import (
	"context"
	"errors"
	"fmt"
	"io"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
)

// RoleSessionName names Signal Loom in the customer's own CloudTrail. It is a
// constant rather than a generated value so that a customer auditing who touched
// their account sees one stable principal instead of a different session per pod
// restart.
const RoleSessionName = "signal-loom-awslogs"

// DefaultMaxObjectBytes caps a single S3 object at 256 MiB.
//
// The cap exists because the whole object is held in memory and then written into
// the ring buffer's WAL; an unbounded fetch turns one unusually large log object
// into an OOM kill, which looks exactly like the crash the durability test is for.
// Exceeding it is an error, never a truncated read — see S3Fetcher.GetObject.
const DefaultMaxObjectBytes = 256 << 20

// maxSQSBatch is the hard AWS limit on ReceiveMessage.MaxNumberOfMessages.
const maxSQSBatch int32 = 10

// receiveWaitSeconds enables SQS long polling.
//
// Long polling is not an optimisation here, it is correctness-adjacent: with short
// polling a receive returns immediately and often empty even when the queue has
// messages, because it samples a subset of the queue's servers. A collector that
// sees an empty queue when it is not empty looks like a customer with no activity.
const receiveWaitSeconds int32 = 20

// ---------------------------------------------------------------------------
// STS
// ---------------------------------------------------------------------------

// stsAPI is the slice of the STS client this package uses.
type stsAPI interface {
	AssumeRole(ctx context.Context, params *sts.AssumeRoleInput, optFns ...func(*sts.Options)) (*sts.AssumeRoleOutput, error)
}

// STSAssumer implements awslogs.STSAssumer on aws-sdk-go-v2.
type STSAssumer struct {
	api stsAPI
}

// NewSTSAssumer returns an STSAssumer built on cfg. It performs no I/O.
func NewSTSAssumer(cfg aws.Config) *STSAssumer {
	return &STSAssumer{api: sts.NewFromConfig(cfg)}
}

// AssumeRole assumes roleARN presenting externalID.
//
// The empty-external-ID check is before the call and not a server-side concern on
// purpose. A customer's trust policy conditions on sts:ExternalId, so AWS would
// reject the request anyway — but it would reject it as AccessDenied, which is
// indistinguishable from a wrong role ARN, a revoked trust or a typo'd account, and
// it would have put the role ARN on the wire first. Refusing locally names the
// actual defect: our configuration is missing a value that is never optional
// (proposal §2.1, ISC-59).
func (a *STSAssumer) AssumeRole(ctx context.Context, roleARN, externalID string) (awslogs.Credentials, error) {
	if externalID == "" {
		return awslogs.Credentials{}, awslogs.ErrExternalIDRequired
	}
	if roleARN == "" {
		return awslogs.Credentials{}, errors.New("awslogs/live: role ARN is required for sts:AssumeRole")
	}

	out, err := a.api.AssumeRole(ctx, &sts.AssumeRoleInput{
		RoleArn:         aws.String(roleARN),
		ExternalId:      aws.String(externalID),
		RoleSessionName: aws.String(RoleSessionName),
	})
	if err != nil {
		return awslogs.Credentials{}, fmt.Errorf("awslogs/live: sts:AssumeRole %s: %w", roleARN, err)
	}
	if out == nil || out.Credentials == nil {
		return awslogs.Credentials{}, fmt.Errorf("awslogs/live: sts:AssumeRole %s returned no credentials", roleARN)
	}

	creds := awslogs.Credentials{
		AccessKeyID:     aws.ToString(out.Credentials.AccessKeyId),
		SecretAccessKey: aws.ToString(out.Credentials.SecretAccessKey),
		SessionToken:    aws.ToString(out.Credentials.SessionToken),
	}
	if out.Credentials.Expiration != nil {
		creds.Expiration = *out.Credentials.Expiration
	}
	return creds, nil
}

// ---------------------------------------------------------------------------
// SQS
// ---------------------------------------------------------------------------

// sqsAPI is the slice of the SQS client this package uses.
type sqsAPI interface {
	ReceiveMessage(ctx context.Context, params *sqs.ReceiveMessageInput, optFns ...func(*sqs.Options)) (*sqs.ReceiveMessageOutput, error)
	DeleteMessage(ctx context.Context, params *sqs.DeleteMessageInput, optFns ...func(*sqs.Options)) (*sqs.DeleteMessageOutput, error)
}

// SQSClient implements awslogs.SQSClient on aws-sdk-go-v2.
type SQSClient struct {
	api   sqsAPI
	bound string
}

// NewSQSClient returns an unbound SQSClient built on cfg. It performs no I/O.
func NewSQSClient(cfg aws.Config) *SQSClient {
	return &SQSClient{api: sqs.NewFromConfig(cfg)}
}

// BoundTo binds the client to one queue URL and returns it, so NewClients can bind
// in a single expression. A bound client rejects any other queue, which is the
// contract awslogs.SQSClient documents and the awsfake implements.
func (c *SQSClient) BoundTo(queueURL string) *SQSClient {
	c.bound = queueURL
	return c
}

// checkQueue rejects a queue URL other than the bound one.
//
// Worth the four lines: a collector pointed at the wrong queue drains nothing and
// reports no error, which is the single hardest failure in this design to tell apart
// from a customer who genuinely has no activity.
func (c *SQSClient) checkQueue(queueURL string) error {
	if queueURL == "" {
		return errors.New("awslogs/live: queue URL is required")
	}
	if c.bound != "" && queueURL != c.bound {
		return fmt.Errorf("awslogs/live: client is bound to queue %s, refusing %s", c.bound, queueURL)
	}
	return nil
}

// ReceiveMessages long-polls the queue for at most maxMessages messages.
//
// An empty slice with a nil error means "nothing queued" and is not an error.
// maxMessages is clamped to SQS's 1..10 range rather than passed through: an
// out-of-range AWSLOGS_MAX_RECORDS is a harmless configuration value and should not
// take the collector down with InvalidParameterValue on every poll.
func (c *SQSClient) ReceiveMessages(ctx context.Context, queueURL string, maxMessages int32) ([]awslogs.Message, error) {
	if err := c.checkQueue(queueURL); err != nil {
		return nil, err
	}

	switch {
	case maxMessages < 1:
		maxMessages = 1
	case maxMessages > maxSQSBatch:
		maxMessages = maxSQSBatch
	}

	out, err := c.api.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
		QueueUrl:            aws.String(queueURL),
		MaxNumberOfMessages: maxMessages,
		WaitTimeSeconds:     receiveWaitSeconds,
	})
	if err != nil {
		return nil, fmt.Errorf("awslogs/live: sqs:ReceiveMessage %s: %w", queueURL, err)
	}
	if out == nil || len(out.Messages) == 0 {
		return nil, nil
	}

	msgs := make([]awslogs.Message, 0, len(out.Messages))
	for _, m := range out.Messages {
		msgs = append(msgs, awslogs.Message{
			MessageID:     aws.ToString(m.MessageId),
			ReceiptHandle: aws.ToString(m.ReceiptHandle),
			Body:          aws.ToString(m.Body),
		})
	}
	return msgs, nil
}

// DeleteMessage acknowledges one message.
//
// Calling this is a durability claim (awslogs.Message): the collector only reaches
// here once the sink has accepted every observation derived from the message. An
// error must therefore propagate — the caller leaves the record buffered rather than
// releasing the slot.
func (c *SQSClient) DeleteMessage(ctx context.Context, queueURL, receiptHandle string) error {
	if err := c.checkQueue(queueURL); err != nil {
		return err
	}
	if receiptHandle == "" {
		return errors.New("awslogs/live: receipt handle is required to acknowledge a message")
	}

	if _, err := c.api.DeleteMessage(ctx, &sqs.DeleteMessageInput{
		QueueUrl:      aws.String(queueURL),
		ReceiptHandle: aws.String(receiptHandle),
	}); err != nil {
		return fmt.Errorf("awslogs/live: sqs:DeleteMessage %s: %w", queueURL, err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// S3
// ---------------------------------------------------------------------------

// s3API is the slice of the S3 client this package uses.
type s3API interface {
	GetObject(ctx context.Context, params *s3.GetObjectInput, optFns ...func(*s3.Options)) (*s3.GetObjectOutput, error)
}

// S3Fetcher implements awslogs.S3Fetcher on aws-sdk-go-v2.
type S3Fetcher struct {
	api s3API

	// MaxObjectBytes caps one object. Zero means DefaultMaxObjectBytes.
	MaxObjectBytes int64
}

// NewS3Fetcher returns an S3Fetcher built on cfg. It performs no I/O.
func NewS3Fetcher(cfg aws.Config) *S3Fetcher {
	return &S3Fetcher{api: s3.NewFromConfig(cfg)}
}

// GetObject returns the complete object body.
//
// A partial body with a nil error is the defect awslogs.S3Fetcher names: the
// projection would succeed on the prefix, emit fewer observations than the object
// holds, and the message would still be acked — so the tail of a customer's
// telemetry would be dropped with no error anywhere. The read is therefore bounded
// by MaxObjectBytes+1 and an object that reaches the cap is an error, not a
// truncation.
func (f *S3Fetcher) GetObject(ctx context.Context, ref awslogs.ObjectRef) ([]byte, error) {
	if ref.Bucket == "" || ref.Key == "" {
		return nil, fmt.Errorf("awslogs/live: incomplete object ref {bucket:%q key:%q}", ref.Bucket, ref.Key)
	}

	out, err := f.api.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(ref.Bucket),
		Key:    aws.String(ref.Key),
	})
	if err != nil {
		return nil, fmt.Errorf("awslogs/live: s3:GetObject s3://%s/%s: %w", ref.Bucket, ref.Key, err)
	}
	if out == nil || out.Body == nil {
		return nil, fmt.Errorf("awslogs/live: s3:GetObject s3://%s/%s returned no body", ref.Bucket, ref.Key)
	}
	defer out.Body.Close() //nolint:errcheck // read-only body; a close error cannot invalidate bytes already read

	cap64 := f.MaxObjectBytes
	if cap64 <= 0 {
		cap64 = DefaultMaxObjectBytes
	}

	body, err := io.ReadAll(io.LimitReader(out.Body, cap64+1))
	if err != nil {
		return nil, fmt.Errorf("awslogs/live: reading s3://%s/%s: %w", ref.Bucket, ref.Key, err)
	}
	if int64(len(body)) > cap64 {
		return nil, fmt.Errorf("awslogs/live: s3://%s/%s exceeds the %d byte object cap; refusing a truncated read",
			ref.Bucket, ref.Key, cap64)
	}
	return body, nil
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

// Clients is the set of live seams built on one assumed role.
type Clients struct {
	SQS *SQSClient
	S3  *S3Fetcher
	STS *STSAssumer
}

// NewClients builds the three seams on credentials obtained by assuming roleARN with
// externalID, refreshed automatically as they expire.
//
// The empty-external-ID refusal is first, before aws config loading, so it cannot
// reach a credential-chain probe (IMDS, SSO) on the way to failing.
//
// The role is assumed lazily, by the credentials cache, on the first signed request.
// That is deliberate rather than an omission: Collector.Start calls the STSAssumer
// seam explicitly before it opens the buffer, so a broken trust relationship is
// still a loud failure at boot — and doing it here as well would assume the role
// twice on every start, which shows up twice in the customer's CloudTrail.
func NewClients(ctx context.Context, region, roleARN, externalID string) (*Clients, error) {
	if externalID == "" {
		return nil, awslogs.ErrExternalIDRequired
	}
	if roleARN == "" {
		return nil, errors.New("awslogs/live: role ARN is required")
	}
	if region == "" {
		return nil, errors.New("awslogs/live: region is required")
	}

	base, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(region))
	if err != nil {
		return nil, fmt.Errorf("awslogs/live: loading AWS configuration for %s: %w", region, err)
	}

	// The provider holds the external ID, so every refresh presents it too. A refresh
	// that dropped it would work until the first expiry and then fail with
	// AccessDenied an hour into a pilot.
	provider := stscreds.NewAssumeRoleProvider(sts.NewFromConfig(base), roleARN,
		func(o *stscreds.AssumeRoleOptions) {
			o.ExternalID = aws.String(externalID)
			o.RoleSessionName = RoleSessionName
		})

	assumed := base.Copy()
	assumed.Credentials = aws.NewCredentialsCache(provider)

	return &Clients{
		SQS: NewSQSClient(assumed),
		S3:  NewS3Fetcher(assumed),
		// The explicit assumer stays on the BASE config: its job is to prove the trust
		// relationship works, and proving that with credentials already minted by the
		// same assumption would prove only that the cache has an entry.
		STS: NewSTSAssumer(base),
	}, nil
}

// Compile-time proof that the live implementations satisfy the seams. Without these
// a signature drift in awslogs would only surface wherever the factory is linked in,
// which is exactly the deployment that cannot afford a surprise.
var (
	_ awslogs.SQSClient  = (*SQSClient)(nil)
	_ awslogs.S3Fetcher  = (*S3Fetcher)(nil)
	_ awslogs.STSAssumer = (*STSAssumer)(nil)
)
