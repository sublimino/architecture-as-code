package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
)

// errUnknownAgent is returned when no resolution branch maps the caller's id
// onto a DAG agent. Handlers answer it with 404 {"error":"unknown agent",...}.
var errUnknownAgent = errors.New("unknown agent")

// AgentPodLookup is an optional FleetClient capability: read one pod by name
// from the agent namespace (AGENT_NAMESPACE) and return its labels. found is
// false, with a nil error, when the API answered that the pod does not exist.
type AgentPodLookup interface {
	LookupAgentPod(ctx context.Context, name string) (labels map[string]string, found bool, err error)
}

// agentResolution records how a caller-supplied id was mapped onto the DAG.
// Tried lists every lookup in order, so a 404 tells the caller what was
// attempted rather than only that it failed.
type agentResolution struct {
	ID        string
	Requested string
	// By names the branch that resolved it: exact, prefixed, label or
	// replicaset-pattern.
	By    string
	Tried []string
}

// Resolution branch names, as reported in freeze-plane details.resolved_by.
const (
	resolvedByExact      = "exact"
	resolvedByPrefixed   = "prefixed"
	resolvedByLabel      = "label"
	resolvedByReplicaSet = "replicaset-pattern"
)

// requestedAgentHeader carries the id the caller sent, before resolution.
const requestedAgentHeader = "X-Requested-Agent-Id"

// requestContextKey carries the resolution into the orchestrator, so the
// freeze PlaneResult records requested_id and resolved_by at creation and the
// signed attestation evidence includes them. PlaneResult.details is already a
// free map on the wire, so this needs no change to the frozen CascadeResult.
type requestContextKey struct{}

func withAgentResolution(ctx context.Context, r agentResolution) context.Context {
	return context.WithValue(ctx, requestContextKey{}, r)
}

func agentResolutionFrom(ctx context.Context) (agentResolution, bool) {
	r, ok := ctx.Value(requestContextKey{}).(agentResolution)
	return r, ok
}

// podLookup returns the client that can read agent pods: the installed
// enforcement client first, then the orchestrator's client.
func (s *server) podLookup() AgentPodLookup {
	if s.enforcement != nil {
		if l, ok := s.enforcement.Client.(AgentPodLookup); ok {
			return l
		}
	}
	if s.orchestrator != nil {
		if l, ok := s.orchestrator.client.(AgentPodLookup); ok {
			return l
		}
	}
	return nil
}

// replicaSetBase strips the two trailing -<hash> segments a Deployment's pods
// carry (<deployment>-<pod-template-hash>-<suffix>). It needs at least one
// segment left over, so "agent-x" and "x-y" yield nothing.
func replicaSetBase(podName string) (string, bool) {
	parts := strings.Split(podName, "-")
	if len(parts) < 3 {
		return "", false
	}
	return strings.Join(parts[:len(parts)-2], "-"), true
}

// resolveAgentID maps what a caller sent (a DAG id, or the pod name the
// dashboard and the integration proxy use) onto a DAG agent id:
//
//	(a) an exact DAG id is used as is, with no API call;
//	(a') else agent-<requested>, when that is a DAG id, also with no API call;
//	(b) else the pod AGENT_NAMESPACE/<requested> is read; if it carries
//	    signalloom.ai/agent-name=<n> and agent-<n> is in the DAG, that;
//	(c) else, if the pod exists, the pod name minus its two trailing -<hash>
//	    segments (the ReplicaSet pod pattern), when that is a DAG id;
//	(d) else errUnknownAgent, with every attempt recorded in Tried.
//
// (c) requires the pod to exist so a made-up name cannot be steered onto a
// real agent by string shape alone.
func (s *server) resolveAgentID(ctx context.Context, requested string) (agentResolution, error) {
	res := agentResolution{Requested: requested}

	res.Tried = append(res.Tried, "dag:"+requested)
	if s.dag != nil && s.dag.GetAgent(requested) != nil {
		res.ID = requested
		res.By = resolvedByExact
		return res, nil
	}
	if s.dag == nil {
		return res, errUnknownAgent
	}

	// (a') A bare agent name (kusari-agent) is the DAG id without its agent-
	// prefix. fe passes ids through unchanged, so this is resolved here and
	// needs no API call.
	if !strings.HasPrefix(requested, "agent-") {
		prefixed := "agent-" + requested
		res.Tried = append(res.Tried, "prefixed:"+prefixed)
		if s.dag.GetAgent(prefixed) != nil {
			res.ID = prefixed
			res.By = resolvedByPrefixed
			return res, nil
		}
	}

	lookup := s.podLookup()
	if lookup == nil {
		res.Tried = append(res.Tried, "pod:"+requested+" (no pod reader configured)")
		return res, errUnknownAgent
	}
	labels, found, err := lookup.LookupAgentPod(ctx, requested)
	switch {
	case err != nil:
		res.Tried = append(res.Tried, fmt.Sprintf("pod:%s (read failed: %v)", requested, err))
		return res, errUnknownAgent
	case !found:
		res.Tried = append(res.Tried, "pod:"+requested+" (not found)")
		return res, errUnknownAgent
	}
	res.Tried = append(res.Tried, "pod:"+requested)

	if n := labels[AgentNameLabel]; n != "" {
		candidate := "agent-" + n
		if s.dag.GetAgent(candidate) != nil {
			res.Tried = append(res.Tried, fmt.Sprintf("label:%s=%s -> %s", AgentNameLabel, n, candidate))
			res.ID = candidate
			res.By = resolvedByLabel
			return res, nil
		}
		res.Tried = append(res.Tried, fmt.Sprintf("label:%s=%s -> %s (not in topology)", AgentNameLabel, n, candidate))
	} else {
		res.Tried = append(res.Tried, "label:"+AgentNameLabel+" (absent)")
	}

	if base, ok := replicaSetBase(requested); ok {
		if s.dag.GetAgent(base) != nil {
			res.Tried = append(res.Tried, "replicaset:"+base)
			res.ID = base
			res.By = resolvedByReplicaSet
			return res, nil
		}
		res.Tried = append(res.Tried, "replicaset:"+base+" (not in topology)")
	} else {
		res.Tried = append(res.Tried, "replicaset: (pod name has fewer than three segments)")
	}
	return res, errUnknownAgent
}

// writeUnknownAgent answers an unresolvable id with 404 and the attempts made.
func writeUnknownAgent(w http.ResponseWriter, res agentResolution) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusNotFound)
	json.NewEncoder(w).Encode(map[string]any{"error": errUnknownAgent.Error(), "tried": res.Tried})
}
