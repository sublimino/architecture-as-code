package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// ── The selection contract ───────────────────────────────────────────────────
//
// main.go used to read, in full:
//
//	client := FleetClient(&noopFleetClient{})
//
// Unconditional. No flag, no env var, no cluster probe, no log line. Every
// deployment of this service — including in-cluster ones with a working
// ServiceAccount and a Role granting pod access — ran the no-op and reported
// successful containments it had not performed.
//
// The fix is a gate, not an additional branch. Leaving the no-op as a fallback
// "just in case" reproduces the original defect, because the cases that fall
// back are exactly the cases where enforcement is broken. So:
//
//	--fleet-client=noop-test-only   EXACT literal, ON THE COMMAND LINE ONLY
//	--fleet-client=kubernetes       real client; unavailable-client if it fails
//	--fleet-client=auto | <empty>   same as kubernetes (the default)
//	--fleet-client=<anything else>  logged as an error, then treated as auto
//
// Two properties do the work, and both are about the same thing — the only way
// to disarm enforcement should be to say so, deliberately, in a place that is
// hard to reach by accident.
//
//  1. The permissive branch is the EXACT-MATCH branch. A typo (`noop`, `none`,
//     `NOOP-TEST-ONLY`) falls to the real client and then, if that cannot be
//     built, to unavailableFleetClient — which fails closed. A misconfiguration
//     can never silently buy you the no-op.
//
//  2. The value is honoured from argv but REFUSED from FLEET_CLIENT. The env var
//     is still the flag's default (so a Deployment can select the real client
//     that way), but the double specifically requires the command line. Env
//     injection is a much lower bar than argv rewriting: `kubectl set env`, an
//     envFrom ConfigMap merge, or a mutating webhook all reach it, and all are
//     available to anyone holding patch on the Deployment or control of a
//     referenced ConfigMap. See selectFleetClientFrom.

type fleetClientKind string

const (
	// fleetClientKubernetes is the real client-go implementation.
	fleetClientKubernetes fleetClientKind = "kubernetes"
	// fleetClientNoopTestOnly is the test double. The value is verbose on
	// purpose: nobody types "noop-test-only" into a production manifest by
	// accident, and it reads as a warning in `kubectl get deploy -o yaml`.
	fleetClientNoopTestOnly fleetClientKind = "noop-test-only"
	// fleetClientUnavailable is the fail-closed fallback when the real client
	// cannot be built. Not a no-op: every method returns ErrEnforcementUnavailable.
	fleetClientUnavailable fleetClientKind = "unavailable"
)

// fleetClientSelectionValueAuto and ...Kubernetes are the two accepted spellings
// of "give me the real client".
const (
	fleetClientSelectionValueAuto  = "auto"
	fleetClientSelectionValueEmpty = ""
)

// fleetClientSelection is the audited outcome of choosing an implementation. It
// is carried on the server so /health can report which client is installed
// rather than inferring it.
type fleetClientSelection struct {
	Kind      fleetClientKind
	Client    FleetClient
	Reason    string
	Source    string
	Enforcing bool
}

// restConfigLoader is the injectable cluster-config boundary. Production uses
// defaultRestConfigLoader; tests substitute a loader that fails deterministically
// so the fail-closed path can be exercised without a cluster.
type restConfigLoader func() (*rest.Config, string, error)

// clientsetBuilder is the injectable clientset boundary, so tests can return a
// fake clientset or a deterministic error.
type clientsetBuilder func(*rest.Config) (kubernetes.Interface, error)

// apiRequestTimeout bounds every API call the client makes.
//
// Without it, fail-closed becomes fail-HANG: an API server that accepts the TCP
// connection and then stops answering (control-plane overload, a NetworkPolicy
// black-hole, a half-open load balancer) leaves Patch blocking forever. The
// containment request never returns, the target is never marked degraded, and
// /health goes on reporting zero degraded targets and enforcement available. The
// whole degraded registry is premised on calls RETURNING; nothing else
// guarantees they do. http.Server.WriteTimeout does not cancel r.Context().
const apiRequestTimeout = 15 * time.Second

// defaultRestConfigLoader prefers the in-cluster ServiceAccount and falls back
// to KUBECONFIG (or ~/.kube/config) when running outside a cluster. The second
// return value is the human-readable source, which goes straight into the
// startup log line.
func defaultRestConfigLoader() (*rest.Config, string, error) {
	if cfg, err := rest.InClusterConfig(); err == nil {
		cfg.Timeout = apiRequestTimeout
		return cfg, "in-cluster ServiceAccount", nil
	} else if !errIsNoInClusterConfig(err) {
		// An in-cluster environment whose config is present but broken is a
		// different failure from "not in a cluster", and must not be masked by
		// silently trying KUBECONFIG next.
		return nil, "in-cluster ServiceAccount", fmt.Errorf("in-cluster config: %w", err)
	}

	kubeconfig := os.Getenv("KUBECONFIG")
	if kubeconfig == "" {
		if home, err := os.UserHomeDir(); err == nil {
			kubeconfig = filepath.Join(home, ".kube", "config")
		}
	}
	if kubeconfig == "" {
		return nil, "KUBECONFIG", fmt.Errorf("no in-cluster config and KUBECONFIG is unset")
	}

	cfg, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		return nil, "KUBECONFIG", fmt.Errorf("kubeconfig %s: %w", kubeconfig, err)
	}
	cfg.Timeout = apiRequestTimeout
	return cfg, "KUBECONFIG " + kubeconfig, nil
}

// errIsNoInClusterConfig distinguishes "we are not running in a cluster" from
// "we are, and the config is broken".
//
// errors.Is rather than ==: client-go returns the sentinel unwrapped today, but
// a future version that wraps it would make the == form fall through to the
// broken-config arm, which fails closed (safe) with a misleading reason (not).
func errIsNoInClusterConfig(err error) bool {
	return errors.Is(err, rest.ErrNotInCluster)
}

func defaultClientsetBuilder(cfg *rest.Config) (kubernetes.Interface, error) {
	return kubernetes.NewForConfig(cfg)
}

// requestSource says where the requested value came from. It is part of the
// gate, not telemetry: the no-op double is reachable from argv and NOT from the
// environment.
//
// Injecting an env var is a far lower bar than rewriting a container's argv —
// `kubectl set env deploy/fleet-manager FLEET_CLIENT=noop-test-only`, an envFrom
// ConfigMap merge, or a mutating webhook all do it, and all are available to
// anyone holding patch on the Deployment or control of a referenced ConfigMap.
// Disarming enforcement fleet-wide should require editing the command line.
type requestSource string

const (
	requestSourceFlag requestSource = "flag"
	requestSourceEnv  requestSource = "env"
)

// selectFleetClient resolves the requested implementation, treating the value as
// having come from the command line. It never returns a nil Client: the worst
// case is unavailableFleetClient, which fails closed.
func selectFleetClient(
	requested string,
	agentNamespace string,
	loadConfig restConfigLoader,
	buildClientset clientsetBuilder,
) fleetClientSelection {
	return selectFleetClientFrom(requested, requestSourceFlag, agentNamespace, loadConfig, buildClientset)
}

func selectFleetClientFrom(
	requested string,
	from requestSource,
	agentNamespace string,
	loadConfig restConfigLoader,
	buildClientset clientsetBuilder,
) fleetClientSelection {
	if agentNamespace == "" {
		agentNamespace = DefaultAgentNamespace
	}

	// The environment may not disarm enforcement. Refused loudly, then treated as
	// auto — so the process still comes up with the REAL client rather than
	// failing to start, and the refusal is visible in the first log lines.
	if requested == string(fleetClientNoopTestOnly) && from == requestSourceEnv {
		slog.Error("fleet client: REFUSING to install the no-op test double from the environment; "+
			"it is reachable only from the command line. Falling through to the real client.",
			"requested", requested,
			"source", string(from),
			"remedy", "pass --fleet-client=noop-test-only on the command line if this was intended")
		requested = fleetClientSelectionValueAuto
	}

	// Exact match, and only exact match, reaches the test double.
	if requested == string(fleetClientNoopTestOnly) {
		slog.Warn("fleet client: NO-OP TEST DOUBLE SELECTED — this process enforces NOTHING; every containment will report success without acting",
			"implementation", string(fleetClientNoopTestOnly),
			"requested", requested,
			"enforcing", false)
		return fleetClientSelection{
			Kind:      fleetClientNoopTestOnly,
			Client:    &noopFleetClient{},
			Reason:    "explicitly requested via the literal value " + string(fleetClientNoopTestOnly),
			Source:    "flag/env",
			Enforcing: false,
		}
	}

	source := "default (auto)"
	switch requested {
	case fleetClientSelectionValueEmpty, fleetClientSelectionValueAuto:
		// default path
	case string(fleetClientKubernetes):
		source = "explicitly requested"
	default:
		slog.Error("fleet client: unrecognised --fleet-client value; falling through to the real client — the no-op double requires the exact literal value",
			"requested", requested,
			"accepted", []string{fleetClientSelectionValueAuto, string(fleetClientKubernetes), string(fleetClientNoopTestOnly)})
		source = "unrecognised value, defaulted to auto"
	}

	cfg, configSource, err := loadConfig()
	if err != nil {
		slog.Error("fleet client: no usable cluster configuration; installing the FAIL-CLOSED client — every enforcement call will return ErrEnforcementUnavailable",
			"implementation", string(fleetClientUnavailable),
			"config_source", configSource,
			"error", err,
			"enforcing", false)
		return fleetClientSelection{
			Kind:      fleetClientUnavailable,
			Client:    newUnavailableFleetClient(err, agentNamespace),
			Reason:    fmt.Sprintf("cluster configuration unavailable (%s): %v", configSource, err),
			Source:    source,
			Enforcing: false,
		}
	}

	clientset, err := buildClientset(cfg)
	if err != nil {
		slog.Error("fleet client: clientset construction failed; installing the FAIL-CLOSED client",
			"implementation", string(fleetClientUnavailable),
			"config_source", configSource,
			"error", err,
			"enforcing", false)
		return fleetClientSelection{
			Kind:      fleetClientUnavailable,
			Client:    newUnavailableFleetClient(err, agentNamespace),
			Reason:    fmt.Sprintf("clientset construction failed (%s): %v", configSource, err),
			Source:    source,
			Enforcing: false,
		}
	}

	spireAddr := ResolveSpireAddress()
	spireClient, spireErr := NewGRPCSpireClient(spireAddr)
	if spireErr != nil {
		slog.Warn("fleet client: spire gRPC client initialization deferred / connection failed; will fail closed on spire operations",
			"spire_addr", spireAddr,
			"error", spireErr)
	}

	slog.Info("fleet client selected",
		"implementation", string(fleetClientKubernetes),
		"config_source", configSource,
		"agent_namespace", agentNamespace,
		"spire_addr", spireAddr,
		"selection_source", source,
		"enforcing", true)

	return fleetClientSelection{
		Kind:      fleetClientKubernetes,
		Client:    newK8sFleetClientWithSpire(clientset, agentNamespace, spireClient),
		Reason:    "client-go clientset built from " + configSource,
		Source:    source,
		Enforcing: true,
	}
}

// ── The test double ──────────────────────────────────────────────────────────
//
// noopFleetClient reports success for every operation without performing any.
// It exists ONLY so the fleet demo and the dashboard contract tests can drive
// the HTTP surface with no cluster present. It is unreachable unless the
// operator passes the exact literal --fleet-client=noop-test-only, and choosing
// it emits a WARN naming what it does.
//
// Do not reintroduce it as a fallback. Its return values (StateRunning, nil) are
// precisely the values a healthy real client returns on success, which is what
// made a failed containment indistinguishable from a successful one for the
// whole life of this service before SLER-P1-1. When the real client cannot be
// built, the fallback is unavailableFleetClient, which fails closed.
type noopFleetClient struct{}

var _ FleetClient = (*noopFleetClient)(nil)

func (n *noopFleetClient) GetPodState(_ context.Context, _, _ string) (string, error) {
	return StateRunning, nil
}
func (n *noopFleetClient) SetPodState(_ context.Context, _, _, _ string) error  { return nil }
func (n *noopFleetClient) RevokeCredentials(_ context.Context, _ string) error  { return nil }
func (n *noopFleetClient) RestoreCredentials(_ context.Context, _ string) error { return nil }
func (n *noopFleetClient) Health(_ context.Context) error                       { return nil }
