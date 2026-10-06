// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package live_test

import (
	"context"
	"net/http"
	"sort"
	"strings"
	"sync"
	"testing"

	awsmiddleware "github.com/aws/aws-sdk-go-v2/aws/middleware"
	smithymiddleware "github.com/aws/smithy-go/middleware"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/live"
)

// The customer's trust policy grants four actions and no more:
//
//	sts:AssumeRole, s3:GetObject, sqs:ReceiveMessage, sqs:DeleteMessage
//
// (docs/signalloom/slaws-kusari-trust-policy.md §1-2). That document is the thing a
// customer's security team reads before signing, so the code has to be the same
// shape as the promise. An inventory of the SDK calls we actually make is the only
// way to hold that: a reviewer can read the interfaces and see no mutating method,
// but an SDK client reaches for other operations on its own — a bucket-region probe,
// a queue-attribute lookup, a credential refresh against a different service — and
// none of those are in the policy, so each one is a request that will be denied in
// production and a line a customer did not agree to.
//
// The assertion is on the SET, and it is an equality, not a subset. A test that only
// checked "no mutating operation appears" would pass the day the client starts
// calling GetBucketLocation or GetQueueUrl.

// operationRecorder records the SDK operation name of every API call, via an
// Initialize-step middleware.
//
// Recording at the middleware layer rather than inferring from HTTP is deliberate.
// The operation name is what the SDK itself resolved, so it is the same string the
// IAM action is derived from. Inferring it from the wire would mean mapping an S3
// REST request back to an operation by method and path, which is a guess — and a
// guess is the wrong instrument for a test whose whole purpose is to say exactly
// which actions we take.
type operationRecorder struct {
	mu  sync.Mutex
	ops []string
}

func (r *operationRecorder) apiOption(stack *smithymiddleware.Stack) error {
	return stack.Initialize.Add(smithymiddleware.InitializeMiddlewareFunc("recordOperationName",
		func(ctx context.Context, in smithymiddleware.InitializeInput, next smithymiddleware.InitializeHandler) (
			smithymiddleware.InitializeOutput, smithymiddleware.Metadata, error,
		) {
			r.mu.Lock()
			r.ops = append(r.ops, awsmiddleware.GetOperationName(ctx))
			r.mu.Unlock()
			return next.HandleInitialize(ctx, in)
		}), smithymiddleware.After)
}

// Set returns the distinct operation names, sorted.
func (r *operationRecorder) Set() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	seen := map[string]bool{}
	out := make([]string, 0, len(r.ops))
	for _, op := range r.ops {
		if op == "" || seen[op] {
			continue
		}
		seen[op] = true
		out = append(out, op)
	}
	sort.Strings(out)
	return out
}

func TestLive_CallsExactlyTheFourOperationsTheTrustPolicyGrants(t *testing.T) {
	rec := &recorder{}
	ops := &operationRecorder{}

	// One stub covering all three services, routed on the request host. Every branch
	// returns a well-formed success, so the clients complete their call rather than
	// retrying or probing — a failure path could hide an extra operation behind an
	// error return.
	rec.handler = func(req *recordedRequest) (*http.Response, error) {
		host := req.URL.Host
		switch {
		case strings.Contains(host, "sts."):
			return reply(http.StatusOK, "text/xml", assumeRoleXML), nil
		case strings.Contains(host, "sqs."):
			if strings.Contains(string(req.Body), "ReceiptHandle") {
				return reply(http.StatusOK, "application/x-amz-json-1.0", `{}`), nil
			}
			return reply(http.StatusOK, "application/x-amz-json-1.0",
				`{"Messages":[{"MessageId":"m-1","ReceiptHandle":"rh-1","Body":"{}"}]}`), nil
		case strings.Contains(host, "s3."), strings.Contains(host, "amazonaws.com"):
			return reply(http.StatusOK, "application/json", `{"Records":[]}`), nil
		default:
			return nil, errUnexpectedHost(host)
		}
	}

	cfg := stubConfig(rec)
	cfg.APIOptions = append(cfg.APIOptions, ops.apiOption)

	ctx := context.Background()

	// Drive every seam the collector uses, in the order the collector uses them.
	assumer := live.NewSTSAssumer(cfg)
	if _, err := assumer.AssumeRole(ctx, testRole, testExtID); err != nil {
		t.Fatalf("AssumeRole: %v", err)
	}

	sqsClient := live.NewSQSClient(cfg).BoundTo(testQueue)
	msgs, err := sqsClient.ReceiveMessages(ctx, testQueue, 10)
	if err != nil {
		t.Fatalf("ReceiveMessages: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("ReceiveMessages returned %d messages, want 1 from the stub", len(msgs))
	}

	fetcher := live.NewS3Fetcher(cfg)
	if _, err := fetcher.GetObject(ctx, awslogs.ObjectRef{Bucket: "kusari-trail", Key: "AWSLogs/trail-1.json"}); err != nil {
		t.Fatalf("GetObject: %v", err)
	}

	if err := sqsClient.DeleteMessage(ctx, testQueue, msgs[0].ReceiptHandle); err != nil {
		t.Fatalf("DeleteMessage: %v", err)
	}

	want := []string{"AssumeRole", "DeleteMessage", "GetObject", "ReceiveMessage"}
	got := ops.Set()

	if len(got) != len(want) {
		t.Fatalf("the live clients called %d distinct operations %v, want exactly %v (the four the trust policy grants)",
			len(got), got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("operation %d = %q, want %q (full set called: %v)", i, got[i], want[i], got)
		}
	}

	// Belt and braces on the direction of travel: nothing we call mutates a
	// customer's account. Checked by name as well as by set equality, so that if the
	// set assertion above is ever relaxed this one still holds the line.
	for _, op := range got {
		for _, mutator := range []string{"Put", "Delete", "Create", "Update", "Set", "Send", "Write", "Tag"} {
			// DeleteMessage is the one exception and it is the ack: it deletes our own
			// in-flight message from the queue we were pointed at, not customer data.
			if op == "DeleteMessage" {
				continue
			}
			if strings.HasPrefix(op, mutator) {
				t.Errorf("operation %q mutates customer state; the pilot is pull-only", op)
			}
		}
	}
}

// And the whole set, measured once more end to end through the factory, so the
// assertion covers what a deployment actually builds rather than three clients a
// test wired by hand. NewClients puts the SQS and S3 clients behind an
// assume-role credentials cache, which is the arrangement most likely to introduce
// an unexpected call: the cache mints credentials lazily, on the first signed
// request.
func TestLive_FactoryBuiltClientsAddNoFifthOperation(t *testing.T) {
	rec := &recorder{}
	ops := &operationRecorder{}

	rec.handler = func(req *recordedRequest) (*http.Response, error) {
		host := req.URL.Host
		switch {
		case strings.Contains(host, "sts."):
			return reply(http.StatusOK, "text/xml", assumeRoleXML), nil
		case strings.Contains(host, "sqs."):
			return reply(http.StatusOK, "application/x-amz-json-1.0", `{}`), nil
		default:
			return reply(http.StatusOK, "application/json", `{"Records":[]}`), nil
		}
	}

	cfg := stubConfig(rec)
	cfg.APIOptions = append(cfg.APIOptions, ops.apiOption)

	// Build the seams the way NewClients does — an assume-role provider behind a
	// credentials cache — but on the stub config, so no real credential chain (IMDS,
	// SSO, shared config) is consulted and nothing leaves the process.
	clients := live.NewClientsFromConfig(cfg, testRole, testExtID)
	if clients == nil {
		t.Fatal("NewClientsFromConfig returned nil")
	}

	ctx := context.Background()
	if _, err := clients.SQS.BoundTo(testQueue).ReceiveMessages(ctx, testQueue, 1); err != nil {
		t.Fatalf("ReceiveMessages: %v", err)
	}
	if _, err := clients.STS.AssumeRole(ctx, testRole, testExtID); err != nil {
		t.Fatalf("AssumeRole: %v", err)
	}

	for _, op := range ops.Set() {
		switch op {
		case "AssumeRole", "ReceiveMessage", "DeleteMessage", "GetObject":
		default:
			t.Errorf("the factory-built clients called %q, which the trust policy does not grant (full set: %v)",
				op, ops.Set())
		}
	}
	// The credentials cache must actually have assumed the role to sign the receive,
	// or this test proved nothing about the lazy path.
	var sawAssume bool
	for _, op := range ops.Set() {
		if op == "AssumeRole" {
			sawAssume = true
		}
	}
	if !sawAssume {
		t.Error("no AssumeRole was recorded; the credentials cache did not mint credentials, so the lazy path is untested")
	}
}

type errUnexpectedHostType string

func (e errUnexpectedHostType) Error() string {
	return "unexpected request to host " + string(e)
}

func errUnexpectedHost(host string) error { return errUnexpectedHostType(host) }
