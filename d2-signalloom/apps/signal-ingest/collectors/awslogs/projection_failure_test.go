package awslogs_test

import (
	"context"
	"errors"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/awsfake"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// Cato round 2, ISC-32: an object that cannot be projected leaves a durable
// projection_failure record naming the object BEFORE the queue advances, so the
// operator can replay it from the bucket after a projector fix. The S3 object is the
// system of record; the queue message is acknowledged only after the record is stored.
func TestCollector_UnprojectableObjectLeavesADurableRecordThenAcks(t *testing.T) {
	sink := &orderedSink{}
	sqs := awsfake.NewSQS(testQueue)
	s3 := awsfake.NewS3()
	sts := awsfake.NewSTS(testRole, testExtID)
	s3.Put(awslogs.ObjectRef{Bucket: testBucket, Key: "garbage/1"}, []byte("this is not cloudtrail\x00\x01"))
	sqs.Enqueue(awsfake.ObjectCreated("m-garbage", testBucket, "garbage/1"))

	c, err := awslogs.New(liveConfig(t), sink,
		awslogs.WithMode(string(awslogs.ModeLive)),
		awslogs.WithAWS(sqs, s3, sts),
		awslogs.WithoutPollLoop(),
	)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer c.Stop()
	if _, err := c.PollOnce(context.Background()); err != nil {
		t.Fatalf("PollOnce: %v", err)
	}
	if _, err := c.Drain(context.Background()); err != nil {
		t.Fatalf("Drain: %v", err)
	}

	var failures []model.Observation
	for _, o := range sink.obs {
		if o.Source == awslogs.SourceCollector && o.Labels[awslogs.LabelType] == awslogs.TypeProjectionFailure {
			failures = append(failures, o)
		}
	}
	if len(failures) != 1 {
		t.Fatalf("want exactly one projection_failure record, got %d (sink saw %d observations)", len(failures), len(sink.obs))
	}
	f := failures[0]
	if f.RawEvidenceRef == "" || f.Labels[awslogs.LabelTenantID] == "" || f.ID == "" {
		t.Fatalf("projection_failure record must name the object and the tenant and carry a derived id: %+v", f)
	}
	if got := sqs.Deleted(); len(got) != 1 {
		t.Fatalf("message must be acknowledged after the record is stored, deleted=%v", got)
	}
}

type refuseCollectorRecords struct{ inner *orderedSink }

func (r *refuseCollectorRecords) IngestObservation(ctx context.Context, o *model.Observation) error {
	if o.Source == awslogs.SourceCollector {
		return errors.New("store refused the collector record")
	}
	return r.inner.IngestObservation(ctx, o)
}

// If the durable record cannot be stored, nothing is acknowledged: the message stays in
// flight and the buffered object stays in the ring.
func TestCollector_UnprojectableObjectIsNotAckedWhenTheRecordIsRefused(t *testing.T) {
	sink := &refuseCollectorRecords{inner: &orderedSink{}}
	sqs := awsfake.NewSQS(testQueue)
	s3 := awsfake.NewS3()
	sts := awsfake.NewSTS(testRole, testExtID)
	s3.Put(awslogs.ObjectRef{Bucket: testBucket, Key: "garbage/2"}, []byte("still not cloudtrail"))
	sqs.Enqueue(awsfake.ObjectCreated("m-garbage-2", testBucket, "garbage/2"))

	c, err := awslogs.New(liveConfig(t), sink,
		awslogs.WithMode(string(awslogs.ModeLive)),
		awslogs.WithAWS(sqs, s3, sts),
		awslogs.WithoutPollLoop(),
	)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer c.Stop()
	// PollOnce drains inline, so the refusal may surface from either call; one of them
	// must report it, and neither may acknowledge the message.
	_, pollErr := c.PollOnce(context.Background())
	_, drainErr := c.Drain(context.Background())
	if pollErr == nil && drainErr == nil {
		t.Fatal("the refused projection_failure record must surface as an error from PollOnce or Drain")
	}
	if got := sqs.Deleted(); len(got) != 0 {
		t.Fatalf("nothing may be acknowledged when the failure record is refused, deleted=%v", got)
	}
}
