// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package collectors

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/awsfake"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

const (
	testDLQQueueURL = "https://sqs.us-east-1.amazonaws.com/123456789012/test-dlq"
	testDLQBucket   = "kusari-telemetry"
	testDLQKey      = "AWSLogs/123456789012/CloudTrail/us-east-1/2026/10/02/test.json.gz"
)

func validNotificationBody(bucket, key string) string {
	return `{"Records":[{"s3":{"bucket":{"name":"` + bucket + `"},"object":{"key":"` + key + `"}}}]}`
}

func sampleCloudTrailPayload(t *testing.T) []byte {
	t.Helper()
	p := filepath.Join("awslogs", "testdata", "cloudtrail.json")
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("reading %s: %v", p, err)
	}
	return b
}

func poisonedNotificationBody(t *testing.T) string {
	t.Helper()
	p := filepath.Join("awslogs", "testdata", "poisoned.json")
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("reading %s: %v", p, err)
	}
	return string(b)
}

func TestRedrive_IsRedriveInvocation(t *testing.T) {
	cases := []struct {
		argv []string
		want bool
	}{
		{argv: []string{"signal-ingest", "awslogs", "redrive", "--queue", "q"}, want: true},
		{argv: []string{"signal-ingest", "awslogs", "redrive"}, want: true},
		{argv: []string{"signal-ingest", "replay"}, want: false},
		{argv: []string{"signal-ingest"}, want: false},
		{argv: []string{}, want: false},
	}
	for _, tc := range cases {
		if got := IsRedriveInvocation(tc.argv); got != tc.want {
			t.Errorf("IsRedriveInvocation(%v) = %v, want %v", tc.argv, got, tc.want)
		}
	}
}

func TestRedrive_DedupeReplayedObject(t *testing.T) {
	st := store.NewMemoryStore()
	defer st.Close()

	payload := sampleCloudTrailPayload(t)

	sqs := awsfake.NewSQS(testDLQQueueURL)
	s3 := awsfake.NewS3()
	s3.Put(awslogs.ObjectRef{Bucket: testDLQBucket, Key: testDLQKey}, payload)
	sts := awsfake.NewSTS("arn:aws:iam::123456789012:role/kusari-role", "ext-1")

	// Enqueue notification once
	sqs.Enqueue(awslogs.Message{
		MessageID:     "msg-1",
		ReceiptHandle: "rh-msg-1",
		Body:          validNotificationBody(testDLQBucket, testDLQKey),
	})

	t.Setenv(awslogs.EnvTenantID, "kusari")
	t.Setenv(awslogs.EnvRoleARN, "arn:aws:iam::123456789012:role/kusari-role")
	t.Setenv(awslogs.EnvExternalID, "ext-1")
	t.Setenv(awslogs.EnvQueueURL, testDLQQueueURL)
	t.Setenv(awslogs.EnvRegion, "us-east-1")

	var outBuf, errBuf bytes.Buffer
	code := RunRedriveWithOptions(context.Background(), RedriveOptions{
		Argv:        []string{"signal-ingest", "awslogs", "redrive", "--queue", testDLQQueueURL},
		OpenStore:   func() (store.SignalStore, error) { return st, nil },
		AWSLogsOpts: []awslogs.Option{awslogs.WithAWS(sqs, s3, sts)},
		Out:         &outBuf,
		Err:         &errBuf,
	})
	if code != 0 {
		t.Fatalf("first redrive failed with exit code %d: %s", code, errBuf.String())
	}

	var res1 RedriveResult
	if err := json.Unmarshal(outBuf.Bytes(), &res1); err != nil {
		t.Fatalf("unmarshaling first result: %v, body: %s", err, outBuf.String())
	}
	if res1.Redriven != 1 {
		t.Errorf("first redrive: redriven = %d, want 1", res1.Redriven)
	}
	if res1.Duplicates != 0 {
		t.Errorf("first redrive: duplicates = %d, want 0", res1.Duplicates)
	}

	initialRows, err := st.QueryRange(context.Background(), store.Query{Before: time.Now().Add(24 * time.Hour)})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	if len(initialRows) == 0 {
		t.Fatal("first redrive wrote zero rows to store")
	}

	// Now redrive the SAME object a second time (e.g. replayed from DLQ)
	sqs.Enqueue(awslogs.Message{
		MessageID:     "msg-2",
		ReceiptHandle: "rh-msg-2",
		Body:          validNotificationBody(testDLQBucket, testDLQKey),
	})

	outBuf.Reset()
	errBuf.Reset()
	code = RunRedriveWithOptions(context.Background(), RedriveOptions{
		Argv:        []string{"signal-ingest", "awslogs", "redrive", "--queue", testDLQQueueURL},
		OpenStore:   func() (store.SignalStore, error) { return st, nil },
		AWSLogsOpts: []awslogs.Option{awslogs.WithAWS(sqs, s3, sts)},
		Out:         &outBuf,
		Err:         &errBuf,
	})
	if code != 0 {
		t.Fatalf("second redrive failed with exit code %d: %s", code, errBuf.String())
	}

	var res2 RedriveResult
	if err := json.Unmarshal(outBuf.Bytes(), &res2); err != nil {
		t.Fatalf("unmarshaling second result: %v, body: %s", err, outBuf.String())
	}
	if res2.Redriven != 1 {
		t.Errorf("second redrive: redriven = %d, want 1", res2.Redriven)
	}
	if res2.Duplicates != uint64(len(initialRows)) {
		t.Errorf("second redrive: duplicates = %d, want %d", res2.Duplicates, len(initialRows))
	}

	afterRows, err := st.QueryRange(context.Background(), store.Query{Before: time.Now().Add(24 * time.Hour)})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	if len(afterRows) != len(initialRows) {
		t.Errorf("second redrive wrote %d new rows (total %d, initial %d), want 0 new rows (idempotent dedupe)",
			len(afterRows)-len(initialRows), len(afterRows), len(initialRows))
	}

	if deleted := sqs.Deleted(); len(deleted) != 2 {
		t.Errorf("fake SQS Deleted() has %d entries, want 2 (acknowledged from DLQ)", len(deleted))
	}
}

func TestRedrive_PoisonedBodyStaysInDLQ(t *testing.T) {
	st := store.NewMemoryStore()
	defer st.Close()

	sqs := awsfake.NewSQS(testDLQQueueURL)
	s3 := awsfake.NewS3()
	sts := awsfake.NewSTS("arn:aws:iam::123456789012:role/kusari-role", "ext-1")

	sqs.Enqueue(awslogs.Message{
		MessageID:     "msg-poison",
		ReceiptHandle: "rh-msg-poison",
		Body:          `{"Records":[{"s3":{"bucket":{"name":"b"},"object":{"key":"bad%zz"}}}]}`,
	})

	t.Setenv(awslogs.EnvTenantID, "kusari")
	t.Setenv(awslogs.EnvRoleARN, "arn:aws:iam::123456789012:role/kusari-role")
	t.Setenv(awslogs.EnvExternalID, "ext-1")
	t.Setenv(awslogs.EnvQueueURL, testDLQQueueURL)
	t.Setenv(awslogs.EnvRegion, "us-east-1")

	var outBuf, errBuf bytes.Buffer
	code := RunRedriveWithOptions(context.Background(), RedriveOptions{
		Argv:        []string{"signal-ingest", "awslogs", "redrive", "--queue", testDLQQueueURL},
		OpenStore:   func() (store.SignalStore, error) { return st, nil },
		AWSLogsOpts: []awslogs.Option{awslogs.WithAWS(sqs, s3, sts)},
		Out:         &outBuf,
		Err:         &errBuf,
	})
	if code != 0 {
		t.Fatalf("redrive returned exit code %d: %s", code, errBuf.String())
	}

	var res RedriveResult
	if err := json.Unmarshal(outBuf.Bytes(), &res); err != nil {
		t.Fatalf("unmarshaling result: %v, body: %s", err, outBuf.String())
	}
	if res.Unparseable != 1 {
		t.Errorf("unparseable = %d, want 1", res.Unparseable)
	}
	if res.Redriven != 0 {
		t.Errorf("redriven = %d, want 0", res.Redriven)
	}

	if deleted := sqs.Deleted(); len(deleted) != 0 {
		t.Errorf("fake SQS Deleted() has %v, want empty (poisoned message must remain in DLQ)", deleted)
	}
	if inFlight := sqs.InFlight(); inFlight != 1 {
		t.Errorf("fake SQS InFlight() = %d, want 1", inFlight)
	}
}

func TestRedrive_DryRunReceivesAndDoesNotDelete(t *testing.T) {
	st := store.NewMemoryStore()
	defer st.Close()

	payload := sampleCloudTrailPayload(t)

	sqs := awsfake.NewSQS(testDLQQueueURL)
	s3 := awsfake.NewS3()
	s3.Put(awslogs.ObjectRef{Bucket: testDLQBucket, Key: testDLQKey}, payload)
	sts := awsfake.NewSTS("arn:aws:iam::123456789012:role/kusari-role", "ext-1")

	sqs.Enqueue(awslogs.Message{
		MessageID:     "msg-dryrun",
		ReceiptHandle: "rh-msg-dryrun",
		Body:          validNotificationBody(testDLQBucket, testDLQKey),
	})

	t.Setenv(awslogs.EnvTenantID, "kusari")
	t.Setenv(awslogs.EnvRoleARN, "arn:aws:iam::123456789012:role/kusari-role")
	t.Setenv(awslogs.EnvExternalID, "ext-1")
	t.Setenv(awslogs.EnvQueueURL, testDLQQueueURL)
	t.Setenv(awslogs.EnvRegion, "us-east-1")

	var outBuf, errBuf bytes.Buffer
	code := RunRedriveWithOptions(context.Background(), RedriveOptions{
		Argv:        []string{"signal-ingest", "awslogs", "redrive", "--queue", testDLQQueueURL, "--dry-run"},
		OpenStore:   func() (store.SignalStore, error) { return st, nil },
		AWSLogsOpts: []awslogs.Option{awslogs.WithAWS(sqs, s3, sts)},
		Out:         &outBuf,
		Err:         &errBuf,
	})
	if code != 0 {
		t.Fatalf("dry-run redrive failed with exit code %d: %s", code, errBuf.String())
	}

	var res RedriveResult
	if err := json.Unmarshal(outBuf.Bytes(), &res); err != nil {
		t.Fatalf("unmarshaling result: %v", err)
	}
	if res.Redriven != 1 {
		t.Errorf("redriven = %d, want 1", res.Redriven)
	}

	if deleted := sqs.Deleted(); len(deleted) != 0 {
		t.Errorf("fake SQS Deleted() has %v in dry-run, want empty (must not delete)", deleted)
	}
}

func TestRedrive_MissingQueueRefuses(t *testing.T) {
	var outBuf, errBuf bytes.Buffer
	code := RunRedriveWithOptions(context.Background(), RedriveOptions{
		Argv: []string{"signal-ingest", "awslogs", "redrive"},
		OpenStore: func() (store.SignalStore, error) {
			return store.NewMemoryStore(), nil
		},
		Out: &outBuf,
		Err: &errBuf,
	})
	if code != 2 {
		t.Errorf("exit code = %d, want 2 (bad arguments for missing queue)", code)
	}
}

func TestRedrive_MaxZeroRefuses(t *testing.T) {
	var outBuf, errBuf bytes.Buffer
	code := RunRedriveWithOptions(context.Background(), RedriveOptions{
		Argv: []string{"signal-ingest", "awslogs", "redrive", "--queue", testDLQQueueURL, "--max", "0"},
		OpenStore: func() (store.SignalStore, error) {
			return store.NewMemoryStore(), nil
		},
		Out: &outBuf,
		Err: &errBuf,
	})
	if code != 2 {
		t.Errorf("exit code = %d, want 2 (--max 0 must be rejected)", code)
	}
}
