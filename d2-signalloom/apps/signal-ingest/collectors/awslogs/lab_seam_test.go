// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs_test

import (
	"context"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/awsfake"
)

const (
	labBucket        = "slaws-lab-logs-kusari"
	labCloudTrailKey = "AWSLogs/123456789012/CloudTrail/us-east-1/2026/10/02/123456789012_CloudTrail_us-east-1_20261002T0915Z_sample.json"
	labIAMKey        = "AWSLogs/123456789012/CloudTrail/us-east-1/2026/10/02/123456789012_CloudTrail_us-east-1_20261002T0915Z_iam.json"
)

// TestCollector_LabObjectIsAckedOnlyAfterTheSinkStoresEveryRecord is the D13 lab seam test:
// It proves with deterministic awsfake seams that the exact objects seeded by Terraform
// (CloudTrail and IAM) have every record projected and ingested into the sink before
// their corresponding SQS messages are acknowledged and deleted.
func TestCollector_LabObjectIsAckedOnlyAfterTheSinkStoresEveryRecord(t *testing.T) {
	t.Run("success: all records ingested before SQS deletion in order", func(t *testing.T) {
		var log []string
		sink := &orderedSink{log: &log}

		sqs := awsfake.NewSQS(testQueue)
		s3 := awsfake.NewS3()
		sts := awsfake.NewSTS(testRole, testExtID)

		ctBody, err := awslogs.FixtureBytes(awslogs.FixtureCloudTrail)
		if err != nil {
			t.Fatalf("FixtureBytes(cloudtrail): %v", err)
		}
		iamBody, err := awslogs.FixtureBytes(awslogs.FixtureIAM)
		if err != nil {
			t.Fatalf("FixtureBytes(iam): %v", err)
		}

		s3.Put(awslogs.ObjectRef{Bucket: labBucket, Key: labCloudTrailKey}, ctBody)
		s3.Put(awslogs.ObjectRef{Bucket: labBucket, Key: labIAMKey}, iamBody)

		sqs.Enqueue(awsfake.ObjectCreated("m-ct", labBucket, labCloudTrailKey))
		sqs.Enqueue(awsfake.ObjectCreated("m-iam", labBucket, labIAMKey))

		recorder := &orderedSQS{inner: sqs, log: &log}

		c, err := awslogs.New(liveConfig(t), sink,
			awslogs.WithMode(string(awslogs.ModeLive)),
			awslogs.WithAWS(recorder, s3, sts),
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

		// PollOnce processes the queued messages (both m-ct and m-iam within MaxRecords=10)
		acked, err := c.PollOnce(ctx)
		if err != nil {
			t.Fatalf("PollOnce: %v", err)
		}
		if acked != 2 {
			t.Errorf("PollOnce acked = %d, want 2", acked)
		}

		// Verify CloudTrail ordering: 4 sink calls, then delete:rh-m-ct
		// Verify IAM ordering: 2 sink calls, then delete:rh-m-iam
		// Total: 8 log entries in exact order
		if len(log) != 8 {
			t.Fatalf("log after PollOnce has %d entries, want 8: %v", len(log), log)
		}
		for i := 0; i < 4; i++ {
			if !strings.HasPrefix(log[i], "sink:") {
				t.Errorf("log[%d] = %q, want CloudTrail sink ingest", i, log[i])
			}
		}
		if log[4] != "delete:rh-m-ct" {
			t.Errorf("log[4] = %q, want delete:rh-m-ct", log[4])
		}
		for i := 5; i < 7; i++ {
			if !strings.HasPrefix(log[i], "sink:") {
				t.Errorf("log[%d] = %q, want IAM sink ingest", i, log[i])
			}
		}
		if log[7] != "delete:rh-m-iam" {
			t.Errorf("log[7] = %q, want delete:rh-m-iam", log[7])
		}

		deleted := sqs.Deleted()
		if len(deleted) != 2 || deleted[0] != "m-ct" || deleted[1] != "m-iam" {
			t.Errorf("sqs.Deleted() = %v, want [m-ct m-iam]", deleted)
		}

		// Verify evidence refs name the real lab bucket and key
		if len(sink.obs) != 6 {
			t.Fatalf("total sink observations = %d, want 6", len(sink.obs))
		}
		wantPrefixCT := "s3://" + labBucket + "/" + labCloudTrailKey + "#"
		for i := 0; i < 4; i++ {
			if !strings.HasPrefix(sink.obs[i].RawEvidenceRef, wantPrefixCT) {
				t.Errorf("obs[%d].RawEvidenceRef = %q, want prefix %q", i, sink.obs[i].RawEvidenceRef, wantPrefixCT)
			}
		}
		wantPrefixIAM := "s3://" + labBucket + "/" + labIAMKey + "#"
		for i := 4; i < 6; i++ {
			if !strings.HasPrefix(sink.obs[i].RawEvidenceRef, wantPrefixIAM) {
				t.Errorf("obs[%d].RawEvidenceRef = %q, want prefix %q", i, sink.obs[i].RawEvidenceRef, wantPrefixIAM)
			}
		}
	})

	t.Run("mutation: sink failure leaves lab SQS message undeleted and buffered", func(t *testing.T) {
		// Fail on the 3rd observation of CloudTrail
		sink := &orderedSink{failFrom: 3}
		sqs := awsfake.NewSQS(testQueue)
		s3 := awsfake.NewS3()
		sts := awsfake.NewSTS(testRole, testExtID)

		ctBody, err := awslogs.FixtureBytes(awslogs.FixtureCloudTrail)
		if err != nil {
			t.Fatalf("FixtureBytes(cloudtrail): %v", err)
		}
		s3.Put(awslogs.ObjectRef{Bucket: labBucket, Key: labCloudTrailKey}, ctBody)
		sqs.Enqueue(awsfake.ObjectCreated("m-ct", labBucket, labCloudTrailKey))

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
		if err == nil {
			t.Fatal("PollOnce returned nil error with a failing sink, want error")
		}
		if acked != 0 {
			t.Errorf("PollOnce acked = %d despite sink failure, want 0", acked)
		}

		if len(sqs.Deleted()) != 0 {
			t.Errorf("sqs.Deleted() = %v, want none on sink failure", sqs.Deleted())
		}
		if sqs.InFlight() != 1 {
			t.Errorf("sqs.InFlight() = %d, want 1", sqs.InFlight())
		}
	})
}
