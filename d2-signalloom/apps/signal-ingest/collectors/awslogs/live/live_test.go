// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package live_test drives the aws-sdk-go-v2 implementations of the three awslogs
// seams without a network.
//
// Every test here intercepts at aws.Config.HTTPClient, which is the lowest seam the
// SDK offers that still exercises the real request serialisers, signers and response
// deserialisers. Stubbing the service client interface instead would prove only that
// our own wrapper calls our own mock; stubbing the transport proves the request we
// actually put on the wire carries the external ID, the queue URL and the object key
// we think it does. SLAWS P3-1 forbids a test with real credentials, so this is the
// strongest assertion available.
package live_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/live"
)

const (
	testRole   = "arn:aws:iam::123456789012:role/signalloom-reader"
	testExtID  = "kusari-eap-2026q3"
	testQueue  = "https://sqs.us-east-1.amazonaws.com/123456789012/kusari-logs"
	testRegion = "us-east-1"
)

// recorder is an aws.HTTPClient that records every request and replies from a
// handler. A nil handler fails the test: an unexpected call is a defect, not a
// default, which is how "no network in tests" is actually enforced rather than hoped
// for.
type recorder struct {
	mu       sync.Mutex
	requests []*recordedRequest
	handler  func(*recordedRequest) (*http.Response, error)
}

type recordedRequest struct {
	Method string
	URL    *url.URL
	Header http.Header
	Body   []byte
}

// Form parses an AWS query-protocol body (STS) into its parameters.
func (r *recordedRequest) Form(t *testing.T) url.Values {
	t.Helper()
	v, err := url.ParseQuery(string(r.Body))
	if err != nil {
		t.Fatalf("parsing query-protocol body %q: %v", r.Body, err)
	}
	return v
}

func (r *recorder) Do(req *http.Request) (*http.Response, error) {
	var body []byte
	if req.Body != nil {
		b, err := io.ReadAll(req.Body)
		if err != nil {
			return nil, err
		}
		body = b
	}
	rec := &recordedRequest{Method: req.Method, URL: req.URL, Header: req.Header.Clone(), Body: body}

	r.mu.Lock()
	r.requests = append(r.requests, rec)
	handler := r.handler
	r.mu.Unlock()

	if handler == nil {
		return nil, fmt.Errorf("unexpected HTTP call to %s %s", req.Method, req.URL)
	}
	return handler(rec)
}

func (r *recorder) Calls() []*recordedRequest {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*recordedRequest, len(r.requests))
	copy(out, r.requests)
	return out
}

func (r *recorder) Len() int { return len(r.Calls()) }

// reply builds a canned response.
func reply(status int, contentType, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Status:     http.StatusText(status),
		Header:     http.Header{"Content-Type": []string{contentType}},
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

// stubConfig returns an aws.Config wired to rec with static credentials and retries
// disabled, so a stub error surfaces as one call and one error rather than a retry
// storm that makes call counts meaningless.
func stubConfig(rec *recorder) aws.Config {
	return aws.Config{
		Region:           testRegion,
		Credentials:      credentials.NewStaticCredentialsProvider("AKIATEST", "secret", "session"),
		HTTPClient:       rec,
		RetryMaxAttempts: 1,
	}
}

const assumeRoleXML = `<AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
  <AssumeRoleResult>
    <Credentials>
      <AccessKeyId>ASIAASSUMED</AccessKeyId>
      <SecretAccessKey>assumed-secret</SecretAccessKey>
      <SessionToken>assumed-token</SessionToken>
      <Expiration>2036-10-04T13:00:00Z</Expiration>
    </Credentials>
    <AssumedRoleUser>
      <Arn>arn:aws:sts::123456789012:assumed-role/signalloom-reader/signal-loom-awslogs</Arn>
      <AssumedRoleId>AROATEST:signal-loom-awslogs</AssumedRoleId>
    </AssumedRoleUser>
  </AssumeRoleResult>
</AssumeRoleResponse>`

// ---------------------------------------------------------------------------
// ISC-58: the live implementations satisfy the seams the collector depends on.
// ---------------------------------------------------------------------------

func TestLive_ImplementsTheAWSLogsSeams(t *testing.T) {
	rec := &recorder{}
	cfg := stubConfig(rec)

	var (
		_ awslogs.SQSClient  = live.NewSQSClient(cfg)
		_ awslogs.S3Fetcher  = live.NewS3Fetcher(cfg)
		_ awslogs.STSAssumer = live.NewSTSAssumer(cfg)
	)

	if rec.Len() != 0 {
		t.Fatalf("constructing clients made %d HTTP calls, want 0: construction must not touch AWS", rec.Len())
	}
}

// ---------------------------------------------------------------------------
// ISC-59: the external ID is mandatory and is actually on the wire.
// ---------------------------------------------------------------------------

// The guard is before the network call, not after it. An empty external ID is a
// configuration defect; sending the request anyway would leak the role ARN to an
// endpoint and return an opaque AccessDenied that reads like an AWS problem.
func TestSTSAssumer_EmptyExternalIDIsRefusedBeforeAnyNetworkCall(t *testing.T) {
	rec := &recorder{} // nil handler: any call at all fails the test
	assumer := live.NewSTSAssumer(stubConfig(rec))

	_, err := assumer.AssumeRole(context.Background(), testRole, "")
	if !errors.Is(err, awslogs.ErrExternalIDRequired) {
		t.Fatalf("AssumeRole with an empty external ID = %v, want ErrExternalIDRequired", err)
	}
	if rec.Len() != 0 {
		t.Fatalf("made %d HTTP calls before refusing, want 0", rec.Len())
	}
}

func TestNewClients_EmptyExternalIDIsRefusedBeforeAnyNetworkCall(t *testing.T) {
	// Belt and braces: nothing in this test may reach IMDS even if the guard regressed.
	t.Setenv("AWS_EC2_METADATA_DISABLED", "true")

	_, err := live.NewClients(context.Background(), testRegion, testRole, "")
	if !errors.Is(err, awslogs.ErrExternalIDRequired) {
		t.Fatalf("NewClients with an empty external ID = %v, want ErrExternalIDRequired", err)
	}
}

// The external ID must appear in the AssumeRole request parameters. This is the
// assertion that D5's confused-deputy protection is real rather than documented: the
// customer's trust policy conditions on sts:ExternalId, so a request without it is
// denied, and a request with the wrong one is denied too.
func TestSTSAssumer_SendsTheExternalIDInTheAssumeRoleRequest(t *testing.T) {
	rec := &recorder{handler: func(*recordedRequest) (*http.Response, error) {
		return reply(http.StatusOK, "text/xml", assumeRoleXML), nil
	}}
	assumer := live.NewSTSAssumer(stubConfig(rec))

	creds, err := assumer.AssumeRole(context.Background(), testRole, testExtID)
	if err != nil {
		t.Fatalf("AssumeRole: %v", err)
	}

	calls := rec.Calls()
	if len(calls) != 1 {
		t.Fatalf("made %d HTTP calls, want exactly 1", len(calls))
	}
	form := calls[0].Form(t)
	if got := form.Get("Action"); got != "AssumeRole" {
		t.Errorf("Action = %q, want AssumeRole", got)
	}
	if got := form.Get("ExternalId"); got != testExtID {
		t.Errorf("ExternalId = %q, want %q — without it the customer trust policy denies the call", got, testExtID)
	}
	if got := form.Get("RoleArn"); got != testRole {
		t.Errorf("RoleArn = %q, want %q", got, testRole)
	}
	if got := form.Get("RoleSessionName"); got == "" {
		t.Error("RoleSessionName is empty; AssumeRole requires it and it is what names Signal Loom in the customer's CloudTrail")
	}

	if creds.AccessKeyID != "ASIAASSUMED" || creds.SecretAccessKey != "assumed-secret" || creds.SessionToken != "assumed-token" {
		t.Errorf("credentials not mapped from the response: %+v", creds)
	}
	if creds.Expiration.IsZero() {
		t.Error("Expiration is zero; the collector cannot tell when to refresh")
	}
}

func TestSTSAssumer_SurfacesADeniedAssumption(t *testing.T) {
	rec := &recorder{handler: func(*recordedRequest) (*http.Response, error) {
		return reply(http.StatusForbidden, "text/xml",
			`<ErrorResponse><Error><Code>AccessDenied</Code><Message>not authorized</Message></Error></ErrorResponse>`), nil
	}}
	assumer := live.NewSTSAssumer(stubConfig(rec))

	if _, err := assumer.AssumeRole(context.Background(), testRole, testExtID); err == nil {
		t.Fatal("a denied AssumeRole must be an error, not empty credentials")
	}
}

// ---------------------------------------------------------------------------
// ISC-60: the SQS and S3 seams.
// ---------------------------------------------------------------------------

func TestSQSClient_ReceiveMessagesMapsEveryField(t *testing.T) {
	const body = `{"Records":[{"s3":{"bucket":{"name":"b"},"object":{"key":"k.json"}}}]}`
	rec := &recorder{handler: func(*recordedRequest) (*http.Response, error) {
		out := fmt.Sprintf(`{"Messages":[{"MessageId":"m-1","ReceiptHandle":"rh-1","Body":%q}]}`, body)
		return reply(http.StatusOK, "application/x-amz-json-1.0", out), nil
	}}

	msgs, err := live.NewSQSClient(stubConfig(rec)).ReceiveMessages(context.Background(), testQueue, 5)
	if err != nil {
		t.Fatalf("ReceiveMessages: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("got %d messages, want 1", len(msgs))
	}
	want := awslogs.Message{MessageID: "m-1", ReceiptHandle: "rh-1", Body: body}
	if msgs[0] != want {
		t.Errorf("message = %+v, want %+v", msgs[0], want)
	}

	calls := rec.Calls()
	if len(calls) != 1 {
		t.Fatalf("made %d HTTP calls, want 1", len(calls))
	}
	if !bytes.Contains(calls[0].Body, []byte(testQueue)) {
		t.Errorf("request body %q does not name the queue URL %q", calls[0].Body, testQueue)
	}
}

// An empty queue is not an error. Treating it as one would make the poll loop count
// an error per tick on a quiet account and bury the real ones.
func TestSQSClient_EmptyQueueIsNotAnError(t *testing.T) {
	rec := &recorder{handler: func(*recordedRequest) (*http.Response, error) {
		return reply(http.StatusOK, "application/x-amz-json-1.0", `{}`), nil
	}}

	msgs, err := live.NewSQSClient(stubConfig(rec)).ReceiveMessages(context.Background(), testQueue, 10)
	if err != nil {
		t.Fatalf("an empty queue must not be an error: %v", err)
	}
	if len(msgs) != 0 {
		t.Fatalf("got %d messages from an empty queue", len(msgs))
	}
}

// SQS rejects MaxNumberOfMessages outside 1..10 with an InvalidParameterValue, which
// would take the collector down for a configuration value (AWSLOGS_MAX_RECORDS) that
// is otherwise harmless. Clamp rather than fail.
func TestSQSClient_ClampsMaxMessagesToTheAWSLimit(t *testing.T) {
	for _, tc := range []struct{ ask, want string }{
		{"0", "1"},
		{"-3", "1"},
		{"1", "1"},
		{"10", "10"},
		{"500", "10"},
	} {
		t.Run("ask="+tc.ask, func(t *testing.T) {
			var seen []byte
			rec := &recorder{handler: func(r *recordedRequest) (*http.Response, error) {
				seen = r.Body
				return reply(http.StatusOK, "application/x-amz-json-1.0", `{}`), nil
			}}
			var ask int32
			if _, err := fmt.Sscanf(tc.ask, "%d", &ask); err != nil {
				t.Fatalf("bad case: %v", err)
			}
			if _, err := live.NewSQSClient(stubConfig(rec)).ReceiveMessages(context.Background(), testQueue, ask); err != nil {
				t.Fatalf("ReceiveMessages: %v", err)
			}
			want := fmt.Sprintf(`"MaxNumberOfMessages":%s`, tc.want)
			if !bytes.Contains(seen, []byte(want)) {
				t.Errorf("request %s does not contain %s", seen, want)
			}
		})
	}
}

// A client bound to a queue refuses any other queue URL. The collector is configured
// per account; a drained-but-empty collector pointed at the wrong queue is the exact
// failure that looks like "the customer has no activity".
func TestSQSClient_BoundClientRefusesAnotherQueue(t *testing.T) {
	rec := &recorder{} // nil handler: a leaked call fails the test
	client := live.NewSQSClient(stubConfig(rec)).BoundTo(testQueue)

	other := "https://sqs.us-east-1.amazonaws.com/999999999999/someone-elses-queue"
	if _, err := client.ReceiveMessages(context.Background(), other, 1); err == nil {
		t.Error("ReceiveMessages on an unbound queue must fail loudly")
	}
	if err := client.DeleteMessage(context.Background(), other, "rh-1"); err == nil {
		t.Error("DeleteMessage on an unbound queue must fail loudly")
	}
	if rec.Len() != 0 {
		t.Fatalf("made %d HTTP calls for a rejected queue, want 0", rec.Len())
	}
}

func TestSQSClient_DeleteMessageSendsTheReceiptHandle(t *testing.T) {
	var seen []byte
	rec := &recorder{handler: func(r *recordedRequest) (*http.Response, error) {
		seen = r.Body
		return reply(http.StatusOK, "application/x-amz-json-1.0", `{}`), nil
	}}

	if err := live.NewSQSClient(stubConfig(rec)).DeleteMessage(context.Background(), testQueue, "rh-42"); err != nil {
		t.Fatalf("DeleteMessage: %v", err)
	}
	if !bytes.Contains(seen, []byte("rh-42")) {
		t.Errorf("delete request %s does not carry the receipt handle", seen)
	}
	if !bytes.Contains(seen, []byte(testQueue)) {
		t.Errorf("delete request %s does not name the queue", seen)
	}
}

func TestSQSClient_SurfacesADeleteFailure(t *testing.T) {
	rec := &recorder{handler: func(*recordedRequest) (*http.Response, error) {
		return reply(http.StatusBadRequest, "application/x-amz-json-1.0",
			`{"__type":"ReceiptHandleIsInvalid","message":"expired"}`), nil
	}}
	err := live.NewSQSClient(stubConfig(rec)).DeleteMessage(context.Background(), testQueue, "rh-stale")
	if err == nil {
		t.Fatal("a failed delete must be an error: the collector must not release the buffer slot")
	}
}

func TestS3Fetcher_GetObjectReturnsTheWholeBody(t *testing.T) {
	payload := strings.Repeat("cloudtrail-record-", 5000) // > any single TCP read
	var seen *recordedRequest
	rec := &recorder{handler: func(r *recordedRequest) (*http.Response, error) {
		seen = r
		return reply(http.StatusOK, "application/json", payload), nil
	}}

	ref := awslogs.ObjectRef{Bucket: "kusari-trail", Key: "AWSLogs/trail-1.json"}
	got, err := live.NewS3Fetcher(stubConfig(rec)).GetObject(context.Background(), ref)
	if err != nil {
		t.Fatalf("GetObject: %v", err)
	}
	if string(got) != payload {
		t.Errorf("got %d bytes, want %d: a partial body with a nil error would ack the message after emitting fewer observations than the object holds",
			len(got), len(payload))
	}
	if seen == nil {
		t.Fatal("no request recorded")
	}
	if !strings.Contains(seen.URL.String(), "AWSLogs/trail-1.json") {
		t.Errorf("request URL %s does not name the object key", seen.URL)
	}
	if !strings.Contains(seen.URL.Host, ref.Bucket) && !strings.Contains(seen.URL.Path, ref.Bucket) {
		t.Errorf("request URL %s does not name the bucket %q", seen.URL, ref.Bucket)
	}
}

func TestS3Fetcher_SurfacesNoSuchKey(t *testing.T) {
	rec := &recorder{handler: func(*recordedRequest) (*http.Response, error) {
		return reply(http.StatusNotFound, "application/xml",
			`<Error><Code>NoSuchKey</Code><Message>missing</Message></Error>`), nil
	}}
	_, err := live.NewS3Fetcher(stubConfig(rec)).GetObject(context.Background(),
		awslogs.ObjectRef{Bucket: "b", Key: "absent"})
	if err == nil {
		t.Fatal("a missing object must be an error, not an empty body")
	}
}

// An object larger than the cap is refused rather than truncated. Truncation is the
// dangerous outcome: the projection would succeed on a prefix and the message would
// be acked, so the tail of a customer's telemetry would be silently dropped.
func TestS3Fetcher_RefusesAnOversizeObjectRatherThanTruncating(t *testing.T) {
	rec := &recorder{handler: func(*recordedRequest) (*http.Response, error) {
		return reply(http.StatusOK, "application/json", strings.Repeat("x", 4096)), nil
	}}
	f := live.NewS3Fetcher(stubConfig(rec))
	f.MaxObjectBytes = 1024

	if _, err := f.GetObject(context.Background(), awslogs.ObjectRef{Bucket: "b", Key: "huge"}); err == nil {
		t.Fatal("an object over MaxObjectBytes must be an error, never a truncated body")
	}
}

func TestS3Fetcher_RejectsAnEmptyRef(t *testing.T) {
	rec := &recorder{} // nil handler: a leaked call fails the test
	f := live.NewS3Fetcher(stubConfig(rec))
	for name, ref := range map[string]awslogs.ObjectRef{
		"no bucket": {Key: "k"},
		"no key":    {Bucket: "b"},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := f.GetObject(context.Background(), ref); err == nil {
				t.Error("an incomplete ref must fail before the request")
			}
		})
	}
	if rec.Len() != 0 {
		t.Fatalf("made %d HTTP calls for an incomplete ref, want 0", rec.Len())
	}
}

// ---------------------------------------------------------------------------
// The factory the collector reaches for in live mode.
// ---------------------------------------------------------------------------

// Registering the live package must make the collector's live mode constructible
// without anyone passing WithAWS. This is the whole of the P3-1 wiring: before it,
// live mode returned ErrLiveClientsNotWired by design.
func TestLive_RegistersItselfAsTheCollectorsLiveFactory(t *testing.T) {
	if !awslogs.LiveClientFactoryRegistered() {
		t.Fatal("importing the live package must register the live client factory; " +
			"without it live mode still fails with ErrLiveClientsNotWired")
	}
}

func TestLive_FactoryRefusesAnEmptyExternalID(t *testing.T) {
	t.Setenv("AWS_EC2_METADATA_DISABLED", "true")

	cfg := awslogs.AWSCollectorConfig{
		TenantID: "kusari",
		RoleARN:  testRole,
		QueueURL: testQueue,
		Region:   testRegion,
	}.WithDefaults()

	_, _, _, _, err := live.Factory(context.Background(), cfg)
	if !errors.Is(err, awslogs.ErrExternalIDRequired) {
		t.Fatalf("the factory with no external ID = %v, want ErrExternalIDRequired", err)
	}
}

// The factory hands the collector the SNS-aware parser, not the core package's
// direct-S3-only one. Without this the first SNS-fanned-out account parks every
// notification as a poison message.
func TestLive_FactorySuppliesTheSNSAwareNotificationParser(t *testing.T) {
	t.Setenv("AWS_EC2_METADATA_DISABLED", "true")

	cfg := awslogs.AWSCollectorConfig{
		TenantID:   "kusari",
		RoleARN:    testRole,
		ExternalID: testExtID,
		QueueURL:   testQueue,
		Region:     testRegion,
	}.WithDefaults()

	sqsClient, s3Client, stsClient, parse, err := live.Factory(context.Background(), cfg)
	if err != nil {
		t.Fatalf("live.Factory: %v", err)
	}
	if sqsClient == nil || s3Client == nil || stsClient == nil {
		t.Fatalf("factory returned a nil client: sqs=%v s3=%v sts=%v", sqsClient == nil, s3Client == nil, stsClient == nil)
	}
	if parse == nil {
		t.Fatal("factory returned a nil notification parser")
	}

	refs, err := parse(snsEnvelope(t, rawS3Event))
	if err != nil {
		t.Fatalf("the factory's parser rejected an SNS envelope: %v", err)
	}
	if len(refs) != 1 || refs[0].Bucket != "kusari-trail" {
		t.Fatalf("parser returned %+v, want one ref in kusari-trail", refs)
	}
}
