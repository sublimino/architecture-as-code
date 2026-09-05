package correlation

import (
	"context"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// ProducerVerifier is the trust boundary between transport authentication and
// correlation. Observation fields are attacker-controlled data; implementations
// must establish producer authenticity outside those fields.
type ProducerVerifier interface {
	VerifyProducer(context.Context, model.Observation) (bool, error)
}

// DenyUnverifiedProducer is the safe default for constructors that cannot know
// whether their SignalStore was populated through an authenticated channel.
type DenyUnverifiedProducer struct{}

func (DenyUnverifiedProducer) VerifyProducer(context.Context, model.Observation) (bool, error) {
	return false, nil
}

// TrustedCollectorAdapter validates known collector field shapes after an
// embedding application has authenticated the producer channel. Installing it
// is an explicit assertion about that channel; Source never authenticates an
// observation by itself.
type TrustedCollectorAdapter struct{}

func (TrustedCollectorAdapter) VerifyProducer(_ context.Context, observation model.Observation) (bool, error) {
	return len(contractIdentifiers(observation)) > 0, nil
}
