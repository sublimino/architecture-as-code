// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package awslogs_test holds the tests that drive the AWS seam through the
// deterministic fakes. It is an external test package because awsfake imports
// awslogs for the shared value types, so a same-package test importing awsfake
// would be an import cycle.
package awslogs_test

import (
	"context"
	"errors"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/awsfake"
)

// TestFakesSatisfyTheSeamInterfaces is the compile-time proof that the fakes a
// later card reuses implement exactly the three interfaces the live aws-sdk-go-v2
// implementation will have to implement (SLAWS ISC-58).
func TestFakesSatisfyTheSeamInterfaces(t *testing.T) {
	var (
		_ awslogs.SQSClient  = (*awsfake.SQS)(nil)
		_ awslogs.S3Fetcher  = (*awsfake.S3)(nil)
		_ awslogs.STSAssumer = (*awsfake.STS)(nil)
	)
}

func TestFakeSTS_RejectsEmptyExternalID(t *testing.T) {
	ctx := context.Background()
	sts := awsfake.NewSTS("arn:aws:iam::123456789012:role/signalloom-reader", "ext-abc")

	if _, err := sts.AssumeRole(ctx, "arn:aws:iam::123456789012:role/signalloom-reader", ""); !errors.Is(err, awslogs.ErrExternalIDRequired) {
		t.Fatalf("AssumeRole with empty external ID: err = %v, want ErrExternalIDRequired", err)
	}
}

func TestFakeSTS_RejectsWrongExternalID(t *testing.T) {
	ctx := context.Background()
	sts := awsfake.NewSTS("arn:aws:iam::123456789012:role/signalloom-reader", "ext-abc")

	if _, err := sts.AssumeRole(ctx, "arn:aws:iam::123456789012:role/signalloom-reader", "ext-WRONG"); err == nil {
		t.Fatal("AssumeRole with a mismatched external ID returned nil error; the confused-deputy guard is vacuous")
	}
}

func TestFakeSTS_GrantsOnMatchingExternalID(t *testing.T) {
	ctx := context.Background()
	const role = "arn:aws:iam::123456789012:role/signalloom-reader"
	sts := awsfake.NewSTS(role, "ext-abc")

	creds, err := sts.AssumeRole(ctx, role, "ext-abc")
	if err != nil {
		t.Fatalf("AssumeRole: %v", err)
	}
	if creds.AccessKeyID == "" || creds.SessionToken == "" {
		t.Fatalf("AssumeRole returned empty credentials: %+v", creds)
	}
	if sts.Calls() != 1 {
		t.Errorf("Calls() = %d, want 1", sts.Calls())
	}
}

func TestFakeSQS_ReceiveIsBoundedAndDeleteIsRecorded(t *testing.T) {
	ctx := context.Background()
	const queue = "https://sqs.us-east-1.amazonaws.com/123456789012/signalloom"

	sqs := awsfake.NewSQS(queue)
	sqs.Enqueue(awsfake.ObjectCreated("m-1", "kusari-trail", "AWSLogs/cloudtrail-1.json"))
	sqs.Enqueue(awsfake.ObjectCreated("m-2", "kusari-trail", "AWSLogs/cloudtrail-2.json"))
	sqs.Enqueue(awsfake.ObjectCreated("m-3", "kusari-trail", "AWSLogs/cloudtrail-3.json"))

	got, err := sqs.ReceiveMessages(ctx, queue, 2)
	if err != nil {
		t.Fatalf("ReceiveMessages: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ReceiveMessages returned %d messages, want 2 (maxMessages must bound the batch)", len(got))
	}
	if got[0].MessageID != "m-1" || got[1].MessageID != "m-2" {
		t.Errorf("ReceiveMessages out of order: %q, %q", got[0].MessageID, got[1].MessageID)
	}

	if err := sqs.DeleteMessage(ctx, queue, got[0].ReceiptHandle); err != nil {
		t.Fatalf("DeleteMessage: %v", err)
	}
	if deleted := sqs.Deleted(); len(deleted) != 1 || deleted[0] != "m-1" {
		t.Errorf("Deleted() = %v, want [m-1]", deleted)
	}
	if remaining := sqs.Remaining(); remaining != 1 {
		t.Errorf("Remaining() = %d, want 1 (two received, one still in flight)", remaining)
	}
}

func TestFakeSQS_RejectsWrongQueueURL(t *testing.T) {
	ctx := context.Background()
	sqs := awsfake.NewSQS("https://sqs.us-east-1.amazonaws.com/123456789012/signalloom")

	if _, err := sqs.ReceiveMessages(ctx, "https://sqs.us-east-1.amazonaws.com/999/other", 10); err == nil {
		t.Fatal("ReceiveMessages against the wrong queue URL returned nil error")
	}
}

func TestFakeS3_GetObjectAndMissingKey(t *testing.T) {
	ctx := context.Background()
	ref := awslogs.ObjectRef{Bucket: "kusari-trail", Key: "AWSLogs/cloudtrail-1.json"}

	s3 := awsfake.NewS3()
	s3.Put(ref, []byte(`{"Records":[]}`))

	body, err := s3.GetObject(ctx, ref)
	if err != nil {
		t.Fatalf("GetObject: %v", err)
	}
	if string(body) != `{"Records":[]}` {
		t.Errorf("GetObject body = %q", body)
	}
	if got := s3.Fetched(); len(got) != 1 || got[0] != ref {
		t.Errorf("Fetched() = %v, want [%v]", got, ref)
	}

	if _, err := s3.GetObject(ctx, awslogs.ObjectRef{Bucket: "kusari-trail", Key: "absent"}); !errors.Is(err, awsfake.ErrNoSuchKey) {
		t.Errorf("GetObject on an absent key: err = %v, want ErrNoSuchKey", err)
	}
}
