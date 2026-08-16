package correlation

import (
	"context"
	"fmt"
	"log/slog"
	"math"
	"time"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// Engine evaluates correlation rules against a signal store.
type Engine struct {
	store    store.SignalStore
	rules    []compiledRule
	actors   map[string]*model.ProvisionalActor
}

type compiledRule struct {
	Rule
	program cel.Program
}

// NewEngine creates a correlation engine with the default rule set.
func NewEngine(s store.SignalStore) (*Engine, error) {
	return NewEngineWithRules(s, DefaultRules())
}

// NewEngineWithRules creates a correlation engine with custom rules.
func NewEngineWithRules(s store.SignalStore, rules []Rule) (*Engine, error) {
	compiled := make([]compiledRule, 0, len(rules))

	for _, r := range rules {
		prg, err := compileRule(r.CEL)
		if err != nil {
			return nil, fmt.Errorf("compile rule %q: %w", r.Name, err)
		}
		compiled = append(compiled, compiledRule{Rule: r, program: prg})
	}

	return &Engine{
		store:  s,
		rules:  compiled,
		actors: make(map[string]*model.ProvisionalActor),
	}, nil
}

func compileRule(expr string) (cel.Program, error) {
	env, err := cel.NewEnv(
		cel.Variable("a", cel.MapType(cel.StringType, cel.DynType)),
		cel.Variable("b", cel.MapType(cel.StringType, cel.DynType)),
		cel.Function("abs",
			cel.Overload("abs_int", []*cel.Type{cel.IntType}, cel.IntType,
				cel.UnaryBinding(func(val ref.Val) ref.Val {
					v := val.Value().(int64)
					if v < 0 {
						return types.Int(-v)
					}
					return types.Int(v)
				}),
			),
		),
	)
	if err != nil {
		return nil, err
	}

	ast, issues := env.Compile(expr)
	if issues != nil && issues.Err() != nil {
		return nil, issues.Err()
	}

	return env.Program(ast)
}

func obsToMap(o model.Observation) map[string]any {
	return map[string]any{
		"id":         o.ID,
		"timestamp":  o.Timestamp.Unix(),
		"layer":      string(o.Layer),
		"fidelity":   string(o.Fidelity),
		"source":     o.Source,
		"confidence": o.Confidence,
		"actor_hint": o.ActorHint,
	}
}

// Correlate runs all rules against current observations and returns actors.
func (e *Engine) Correlate(ctx context.Context) ([]*model.ProvisionalActor, error) {
	observations, err := e.store.QueryRange(ctx, store.Query{})
	if err != nil {
		return nil, fmt.Errorf("query observations: %w", err)
	}

	slog.Info("correlation run", "observations", len(observations))

	// Check negative (exclusion) rules first. Mark excluded observation IDs.
	excluded := make(map[string]bool)
	for _, r := range e.rules {
		if !r.Negative {
			continue
		}
		for _, o := range observations {
			aMap := obsToMap(o)
			// For single-observation rules, evaluate with a=b=same.
			out, _, err := r.program.Eval(map[string]any{"a": aMap, "b": aMap})
			if err != nil {
				continue
			}
			if out.Value() == true {
				excluded[o.ID] = true
				slog.Info("excluded by negative rule", "observation", o.ID, "rule", r.Name)
			}
		}
	}

	// Pairwise correlation for positive rules.
	for i := range len(observations) {
		if excluded[observations[i].ID] {
			continue
		}
		for j := i + 1; j < len(observations); j++ {
			if excluded[observations[j].ID] {
				continue
			}
			a := observations[i]
			b := observations[j]
			aMap := obsToMap(a)
			bMap := obsToMap(b)

			for _, r := range e.rules {
				if r.Negative {
					continue
				}
				out, _, err := r.program.Eval(map[string]any{"a": aMap, "b": bMap})
				if err != nil {
					continue
				}
				if out.Value() == true {
					e.mergeIntoActor(a, b, r.Rule)
				}
			}
		}
	}

	result := make([]*model.ProvisionalActor, 0, len(e.actors))
	for _, actor := range e.actors {
		result = append(result, actor)
	}
	return result, nil
}

func (e *Engine) mergeIntoActor(a, b model.Observation, rule Rule) {
	// Determine the correlation key.
	key := correlationKey(a, b)

	actor, exists := e.actors[key]
	now := time.Now().UTC()

	if !exists {
		actor = &model.ProvisionalActor{
			ID:              fmt.Sprintf("actor-%s", key),
			Status:          model.ActorProvisional,
			CorrelationKeys: []string{key},
			CreatedAt:       now,
			UpdatedAt:       now,
		}
		e.actors[key] = actor
	}

	// Add evidence links if not already present.
	addEvidence := func(o model.Observation) {
		for _, e := range actor.EvidenceChain {
			if e.ObservationID == o.ID {
				return
			}
		}
		actor.EvidenceChain = append(actor.EvidenceChain, model.EvidenceLink{
			ObservationID: o.ID,
			Layer:         o.Layer,
			Fidelity:      o.Fidelity,
			Contribution:  fmt.Sprintf("matched rule %q", rule.Name),
			Timestamp:     o.Timestamp,
		})
	}
	addEvidence(a)
	addEvidence(b)

	// Recompute confidence from evidence chain.
	result := model.DeriveConfidence(actor.EvidenceChain)
	actor.Confidence = result.Score
	actor.UpdatedAt = now

	if actor.Confidence >= 0.5 {
		actor.Status = model.ActorActionable
	}
}

func correlationKey(a, b model.Observation) string {
	// Prefer actor_hint as the key if both share one.
	if a.ActorHint != "" && a.ActorHint == b.ActorHint {
		return a.ActorHint
	}
	// Fall back to source-based key.
	if a.Source == b.Source {
		return fmt.Sprintf("src-%s", a.Source)
	}
	// Last resort: sorted pair of IDs.
	if a.ID < b.ID {
		return fmt.Sprintf("pair-%s-%s", a.ID, b.ID)
	}
	return fmt.Sprintf("pair-%s-%s", b.ID, a.ID)
}

// GetActors returns all discovered actors.
func (e *Engine) GetActors() []*model.ProvisionalActor {
	result := make([]*model.ProvisionalActor, 0, len(e.actors))
	for _, a := range e.actors {
		result = append(result, a)
	}
	return result
}

// GetActor returns a single actor by ID.
func (e *Engine) GetActor(id string) *model.ProvisionalActor {
	for _, a := range e.actors {
		if a.ID == id {
			return a
		}
	}
	return nil
}

// PromoteActor marks an actor as promoted.
func (e *Engine) PromoteActor(id string) (*model.ProvisionalActor, error) {
	actor := e.GetActor(id)
	if actor == nil {
		return nil, fmt.Errorf("actor %q not found", id)
	}
	now := time.Now().UTC()
	actor.Status = model.ActorPromoted
	actor.PromotedAt = &now
	actor.UpdatedAt = now
	return actor, nil
}

// absInt64 returns the absolute value of an int64.
func absInt64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

// Ensure math import is used (for future use).
var _ = math.Abs
