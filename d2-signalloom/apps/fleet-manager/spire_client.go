package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	entryv1 "github.com/spiffe/spire-api-sdk/proto/spire/api/server/entry/v1"
	spiretypes "github.com/spiffe/spire-api-sdk/proto/spire/api/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

// DefaultSpireServerAddr is the standard in-cluster service address for SPIRE server.
const DefaultSpireServerAddr = "spire-server.inf-bao.svc.cluster.local:8081"

// DefaultSpireDialTimeout bounds the initial connection dial to SPIRE server.
const DefaultSpireDialTimeout = 5 * time.Second

// DefaultSpireRequestTimeout bounds a single SPIRE server gRPC request.
const DefaultSpireRequestTimeout = 10 * time.Second

// ErrSpireInvalidEntry indicates the entry ID or SPIFFE ID passed to SPIRE was malformed.
var ErrSpireInvalidEntry = fmt.Errorf("invalid spire entry parameter: %w", ErrEnforcementUnavailable)

// SpireEntryDeleteResult carries the structured outcome of a single entry deletion.
type SpireEntryDeleteResult struct {
	EntryID    string       `json:"entry_id"`
	Outcome    PlaneOutcome `json:"outcome"`
	StatusCode int32        `json:"status_code"`
	StatusMsg  string       `json:"status_msg,omitempty"`
	Idempotent bool         `json:"idempotent"`
	Error      string       `json:"error,omitempty"`
	LatencyMs  int64        `json:"latency_ms"`
}

// SpireClient defines the interface for SPIRE Server entry lifecycle and eviction operations.
type SpireClient interface {
	// DeleteEntry deletes a registration entry by its Entry ID.
	DeleteEntry(ctx context.Context, entryID string) (*SpireEntryDeleteResult, error)

	// BatchDeleteEntries deletes multiple registration entries by Entry ID in a single batch.
	BatchDeleteEntries(ctx context.Context, entryIDs []string) ([]SpireEntryDeleteResult, error)

	// ListEntriesBySPIFFEID queries SPIRE server for all entries matching a given SPIFFE ID.
	ListEntriesBySPIFFEID(ctx context.Context, spiffeID string) ([]*spiretypes.Entry, error)

	// EvictAgent executes end-to-end SPIRE eviction for a target agent.
	EvictAgent(ctx context.Context, req SpireEvictionRequest) (*SpireEvictionResponse, error)

	// ReenterAgent re-establishes registration entries for a resumed agent so fresh SVIDs can be issued.
	ReenterAgent(ctx context.Context, req SpireReentryRequest) (*SpireReentryResponse, error)

	// Health probes SPIRE server connectivity and availability.
	Health(ctx context.Context) error

	// Close terminates the gRPC connection.
	Close() error
}

// SpireReentryRequest defines the wire request for SPIRE registration re-entry on resume.
type SpireReentryRequest struct {
	SchemaVersion  string   `json:"schema_version"`
	IdempotencyKey string   `json:"idempotency_key"`
	AgentID        string   `json:"agent_id"`
	SPIFFEID       string   `json:"spiffe_id"`
	Namespace      string   `json:"namespace,omitempty"`
	ParentID       string   `json:"parent_id,omitempty"`
	Selectors      []string `json:"selectors,omitempty"`
	Reason         string   `json:"reason"`
	Timestamp      string   `json:"timestamp"`
}

// SpireReentryResponse defines the wire response from SPIRE registration re-entry on resume.
type SpireReentryResponse struct {
	SchemaVersion  string           `json:"schema_version"`
	IdempotencyKey string           `json:"idempotency_key"`
	AgentID        string           `json:"agent_id"`
	Plane          EnforcementPlane `json:"plane"`
	Outcome        PlaneOutcome     `json:"outcome"`
	EntryCreated   bool             `json:"entry_created"`
	EntryID        string           `json:"entry_id,omitempty"`
	LatencyMs      int64            `json:"latency_ms"`
	Error          string           `json:"error,omitempty"`
	Timestamp      string           `json:"timestamp"`
}

// grpcSpireClient implements SpireClient using SPIRE Server's Entry v1 gRPC API.
type grpcSpireClient struct {
	addr        string
	conn        *grpc.ClientConn
	entryClient entryv1.EntryClient
	dialOpts    []grpc.DialOption
	mu          sync.RWMutex
	now         func() time.Time
}

// Compile-time assertion that grpcSpireClient implements SpireClient.
var _ SpireClient = (*grpcSpireClient)(nil)

// ResolveSpireAddress inspects environment variables following the BAO_ADDR convention,
// returning the configured address or DefaultSpireServerAddr.
func ResolveSpireAddress() string {
	for _, envVar := range []string{"SPIRE_SERVER_ADDR", "SPIRE_ADDR", "SPIRE_SERVER_SOCKET", "SPIRE_SOCKET"} {
		if val := strings.TrimSpace(os.Getenv(envVar)); val != "" {
			return val
		}
	}
	return DefaultSpireServerAddr
}

// NewGRPCSpireClient creates a new SpireClient connected to the specified SPIRE server address.
func NewGRPCSpireClient(addr string, dialOpts ...grpc.DialOption) (*grpcSpireClient, error) {
	if addr == "" {
		addr = ResolveSpireAddress()
	}

	client := &grpcSpireClient{
		addr:     addr,
		dialOpts: dialOpts,
		now:      time.Now,
	}

	if err := client.connect(); err != nil {
		return nil, fmt.Errorf("connect to spire server at %s: %w", addr, err)
	}

	return client, nil
}

// formatDialTarget parses the address string and returns the target and dial options.
func formatDialTarget(rawAddr string) (string, []grpc.DialOption) {
	var opts []grpc.DialOption

	if strings.HasPrefix(rawAddr, "unix://") {
		return rawAddr, opts
	}

	if strings.HasPrefix(rawAddr, "/") {
		return "unix://" + rawAddr, opts
	}

	if strings.HasPrefix(rawAddr, "tcp://") {
		rawAddr = strings.TrimPrefix(rawAddr, "tcp://")
	}

	// For host:port, use standard resolver
	return rawAddr, opts
}

func (c *grpcSpireClient) connect() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn != nil {
		_ = c.conn.Close()
	}

	target, extraOpts := formatDialTarget(c.addr)

	opts := []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	}
	opts = append(opts, extraOpts...)
	opts = append(opts, c.dialOpts...)

	ctx, cancel := context.WithTimeout(context.Background(), DefaultSpireDialTimeout)
	defer cancel()

	conn, err := grpc.DialContext(ctx, target, opts...)
	if err != nil {
		return fmt.Errorf("%w: grpc dial failed: %v", ErrEnforcementUnavailable, err)
	}

	c.conn = conn
	c.entryClient = entryv1.NewEntryClient(conn)
	return nil
}

// getEntryClient returns the active EntryClient with thread safety.
func (c *grpcSpireClient) getEntryClient() (entryv1.EntryClient, error) {
	c.mu.RLock()
	client := c.entryClient
	c.mu.RUnlock()

	if client != nil {
		return client, nil
	}

	if err := c.connect(); err != nil {
		return nil, err
	}

	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.entryClient, nil
}

// MapGRPCStatusToOutcome translates a gRPC status code / error into a PlaneOutcome
// and typed Go error, explicitly distinguishing 'already deleted' (idempotent success)
// from backend failures.
func MapGRPCStatusToOutcome(code codes.Code, msg string, err error) (PlaneOutcome, error, bool) {
	switch code {
	case codes.OK:
		return OutcomeContained, nil, false

	case codes.NotFound:
		// Entry already deleted or does not exist. This is the definition of idempotent success.
		// Tolerated without erroring under retry.
		return OutcomeContained, nil, true

	case codes.InvalidArgument:
		wrapped := fmt.Errorf("%w: invalid entry argument: %s", ErrSpireInvalidEntry, msg)
		return OutcomeUnavailable, wrapped, false

	case codes.PermissionDenied, codes.Unauthenticated:
		wrapped := fmt.Errorf("%w: spire entry authorization failure: %s", ErrEnforcementDenied, msg)
		return OutcomeUnavailable, wrapped, false

	case codes.Unavailable:
		wrapped := fmt.Errorf("%w: spire server unreachable: %s", ErrEnforcementUnavailable, msg)
		return OutcomeUnavailable, wrapped, false

	case codes.DeadlineExceeded:
		wrapped := fmt.Errorf("%w: spire request deadline exceeded: %s", ErrEnforcementUnavailable, msg)
		return OutcomeUnavailable, wrapped, false

	case codes.Internal:
		wrapped := fmt.Errorf("%w: spire server internal error: %s", ErrEnforcementUnavailable, msg)
		return OutcomeUnavailable, wrapped, false

	default:
		wrapped := fmt.Errorf("%w: spire server returned code %v: %s", ErrEnforcementUnavailable, code, msg)
		return OutcomeUnavailable, wrapped, false
	}
}

// DeleteEntry deletes a single entry by entry ID.
func (c *grpcSpireClient) DeleteEntry(ctx context.Context, entryID string) (*SpireEntryDeleteResult, error) {
	results, err := c.BatchDeleteEntries(ctx, []string{entryID})
	if err != nil {
		return nil, err
	}
	if len(results) == 0 {
		return &SpireEntryDeleteResult{
			EntryID:   entryID,
			Outcome:   OutcomeUnavailable,
			Error:     "no result returned from spire server",
			LatencyMs: 0,
		}, ErrEnforcementUnavailable
	}
	return &results[0], nil
}

// BatchDeleteEntries deletes a batch of entry IDs via SPIRE's BatchDeleteEntry RPC.
func (c *grpcSpireClient) BatchDeleteEntries(ctx context.Context, entryIDs []string) ([]SpireEntryDeleteResult, error) {
	if len(entryIDs) == 0 {
		return nil, nil
	}

	client, err := c.getEntryClient()
	if err != nil {
		return nil, fmt.Errorf("spire client unavailable: %w", err)
	}

	start := c.now()

	req := &entryv1.BatchDeleteEntryRequest{
		Ids: entryIDs,
	}

	// Propagate context and deadline
	resp, rpcErr := client.BatchDeleteEntry(ctx, req)
	elapsedMs := c.now().Sub(start).Milliseconds()

	if rpcErr != nil {
		st, _ := status.FromError(rpcErr)
		outcome, typedErr, _ := MapGRPCStatusToOutcome(st.Code(), st.Message(), rpcErr)

		// Log structured failure event
		slog.Error("spire batch entry delete failed",
			"count", len(entryIDs),
			"error", rpcErr.Error(),
			"grpc_code", int32(st.Code()),
			"grpc_code_name", st.Code().String(),
			"outcome", string(outcome),
			"latency_ms", elapsedMs)

		results := make([]SpireEntryDeleteResult, len(entryIDs))
		for i, id := range entryIDs {
			results[i] = SpireEntryDeleteResult{
				EntryID:    id,
				Outcome:    outcome,
				StatusCode: int32(st.Code()),
				StatusMsg:  st.Message(),
				Error:      rpcErr.Error(),
				LatencyMs:  elapsedMs,
			}
		}
		return results, typedErr
	}

	results := make([]SpireEntryDeleteResult, len(entryIDs))
	var overallErr error

	for i, id := range entryIDs {
		var res *entryv1.BatchDeleteEntryResponse_Result
		if resp != nil && i < len(resp.Results) {
			res = resp.Results[i]
		}

		if res == nil {
			results[i] = SpireEntryDeleteResult{
				EntryID:    id,
				Outcome:    OutcomeUnavailable,
				StatusCode: int32(codes.Internal),
				StatusMsg:  "missing result from batch response",
				Error:      "missing result in response",
				LatencyMs:  elapsedMs,
			}
			overallErr = ErrEnforcementUnavailable
			continue
		}

		var statusCode codes.Code
		var statusMsg string
		if res.Status != nil {
			statusCode = codes.Code(res.Status.Code)
			statusMsg = res.Status.Message
		}

		outcome, itemErr, isIdempotent := MapGRPCStatusToOutcome(statusCode, statusMsg, nil)

		result := SpireEntryDeleteResult{
			EntryID:    id,
			Outcome:    outcome,
			StatusCode: int32(statusCode),
			StatusMsg:  statusMsg,
			Idempotent: isIdempotent,
			LatencyMs:  elapsedMs,
		}
		if itemErr != nil {
			result.Error = itemErr.Error()
			if overallErr == nil {
				overallErr = itemErr
			}
		}

		results[i] = result

		// Structured machine-readable audit logging for every entry deletion.
		//
		// The "event" and "worst_case_residual_ms" keys are the shared contract
		// with the OpenBao client's bao_revoke_attempt record. SLER-P5-1 consumes
		// both planes' events into one attestation pipeline and was not scoped to
		// reconcile two shapes; keying on "msg" here and "event" there would have
		// forced exactly that. See SharedAttestationEventKeys.
		slog.Info("spire entry deletion",
			"event", SpireRevokeEventName,
			"entry_id", id,
			"grpc_code", int32(statusCode),
			"grpc_code_name", statusCode.String(),
			"outcome", string(outcome),
			"idempotent", isIdempotent,
			"latency_ms", elapsedMs,
			"worst_case_residual_ms", SpireX509SVIDResidualMs,
			"error", result.Error)
	}

	return results, overallErr
}

// ParseSPIFFEID parses a raw SPIFFE URI into trust domain and path components.
func ParseSPIFFEID(raw string) (*spiretypes.SPIFFEID, error) {
	if !strings.HasPrefix(raw, "spiffe://") {
		return nil, fmt.Errorf("spiffe id must start with spiffe://, got %q", raw)
	}
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("parse spiffe id %q: %w", raw, err)
	}
	if u.Host == "" {
		return nil, fmt.Errorf("spiffe id %q missing trust domain", raw)
	}
	path := u.Path
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	return &spiretypes.SPIFFEID{
		TrustDomain: u.Host,
		Path:        path,
	}, nil
}

// ListEntriesBySPIFFEID lists entries matching the specified SPIFFE ID string.
func (c *grpcSpireClient) ListEntriesBySPIFFEID(ctx context.Context, rawSPIFFEID string) ([]*spiretypes.Entry, error) {
	client, err := c.getEntryClient()
	if err != nil {
		return nil, fmt.Errorf("spire client unavailable: %w", err)
	}

	spiffeID, parseErr := ParseSPIFFEID(rawSPIFFEID)
	if parseErr != nil {
		return nil, fmt.Errorf("%w: %v", ErrSpireInvalidEntry, parseErr)
	}

	req := &entryv1.ListEntriesRequest{
		Filter: &entryv1.ListEntriesRequest_Filter{
			BySpiffeId: spiffeID,
		},
	}

	resp, rpcErr := client.ListEntries(ctx, req)
	if rpcErr != nil {
		st, _ := status.FromError(rpcErr)
		_, typedErr, _ := MapGRPCStatusToOutcome(st.Code(), st.Message(), rpcErr)
		return nil, typedErr
	}

	if resp == nil {
		return nil, nil
	}
	return resp.Entries, nil
}

// EvictAgent executes complete SPIRE eviction for an agent, resolving entries by SPIFFE ID if entry IDs
// are not explicitly provided.
func (c *grpcSpireClient) EvictAgent(ctx context.Context, req SpireEvictionRequest) (*SpireEvictionResponse, error) {
	// SLER-P2-GOV nil-receiver guard. NewGRPCSpireClient returns the CONCRETE
	// *grpcSpireClient, so a failed construction boxed into a SpireClient interface
	// is a TYPED nil: the interface compares non-nil while the pointer is nil, and
	// `c.spireClient != nil` at the call site is satisfied. The selector is now
	// staged to avoid producing one, but a guard at the CONSTRUCTION site alone
	// inherits the very blind spot that caused this defect — any other construction
	// path reintroduces it. Fail closed here, at the dereference, where it cannot
	// be routed around.
	if c == nil {
		return nil, fmt.Errorf("spire client not initialised: %w", ErrEnforcementUnavailable)
	}
	start := c.now()

	response := &SpireEvictionResponse{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: req.IdempotencyKey,
		AgentID:        req.AgentID,
		Plane:          PlaneSpire,
		Timestamp:      start.UTC().Format(time.RFC3339),
	}

	entryIDs := req.EntryIDs

	// If entry IDs were not supplied, look them up by SPIFFE ID
	if len(entryIDs) == 0 && req.SPIFFEID != "" {
		entries, err := c.ListEntriesBySPIFFEID(ctx, req.SPIFFEID)
		if err != nil {
			response.Outcome = OutcomeUnavailable
			response.Error = err.Error()
			response.LatencyMs = c.now().Sub(start).Milliseconds()
			return response, err
		}

		for _, e := range entries {
			if e != nil && e.Id != "" {
				entryIDs = append(entryIDs, e.Id)
			}
		}

		// If no entries exist for this SPIFFE ID, it is already deleted / unissued.
		if len(entryIDs) == 0 {
			response.Outcome = OutcomeContained
			response.EntriesEvicted = 0
			response.SVIDsInvalidated = 0
			response.LatencyMs = c.now().Sub(start).Milliseconds()

			slog.Info("spire eviction: zero entries found for spiffe id (idempotent success)",
				"agent_id", req.AgentID,
				"spiffe_id", req.SPIFFEID,
				"idempotency_key", req.IdempotencyKey,
				"latency_ms", response.LatencyMs)

			return response, nil
		}
	}

	if len(entryIDs) == 0 {
		response.Outcome = OutcomeContained
		response.LatencyMs = c.now().Sub(start).Milliseconds()
		return response, nil
	}

	// Delete entries
	results, deleteErr := c.BatchDeleteEntries(ctx, entryIDs)
	response.LatencyMs = c.now().Sub(start).Milliseconds()

	evictedCount := 0
	for _, r := range results {
		if r.Outcome == OutcomeContained {
			evictedCount++
		}
	}
	response.EntriesEvicted = evictedCount
	response.SVIDsInvalidated = evictedCount // SVIDs are invalidated for re-issuance upon entry eviction

	if deleteErr != nil {
		response.Outcome = OutcomeUnavailable
		response.Error = deleteErr.Error()
		return response, deleteErr
	}

	response.Outcome = OutcomeContained
	slog.Info("spire eviction completed",
		"event", SpireEvictEventName,
		"agent_id", req.AgentID,
		"spiffe_id", req.SPIFFEID,
		"entries_evicted", evictedCount,
		"outcome", string(response.Outcome),
		"latency_ms", response.LatencyMs,
		"worst_case_residual_ms", SpireX509SVIDResidualMs,
		"idempotency_key", req.IdempotencyKey)

	return response, nil
}

// ReenterAgent re-registers an agent in SPIRE server to issue fresh SVIDs upon governance resume.
func (c *grpcSpireClient) ReenterAgent(ctx context.Context, req SpireReentryRequest) (*SpireReentryResponse, error) {
	if c == nil {
		return nil, fmt.Errorf("spire client not initialised: %w", ErrEnforcementUnavailable)
	}
	start := c.now()

	response := &SpireReentryResponse{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: req.IdempotencyKey,
		AgentID:        req.AgentID,
		Plane:          PlaneSpire,
		Timestamp:      start.UTC().Format(time.RFC3339),
	}

	client, err := c.getEntryClient()
	if err != nil {
		response.Outcome = OutcomeUnavailable
		response.Error = err.Error()
		response.LatencyMs = c.now().Sub(start).Milliseconds()
		return response, fmt.Errorf("spire client unavailable: %w", err)
	}

	spiffeID, parseErr := ParseSPIFFEID(req.SPIFFEID)
	if parseErr != nil {
		response.Outcome = OutcomeUnavailable
		response.Error = parseErr.Error()
		response.LatencyMs = c.now().Sub(start).Milliseconds()
		return response, fmt.Errorf("%w: %v", ErrSpireInvalidEntry, parseErr)
	}

	parentID := req.ParentID
	if parentID == "" {
		parentID = fmt.Sprintf("spiffe://%s/spire/server", spiffeID.TrustDomain)
	}
	parsedParent, parseParentErr := ParseSPIFFEID(parentID)
	if parseParentErr != nil {
		response.Outcome = OutcomeUnavailable
		response.Error = parseParentErr.Error()
		response.LatencyMs = c.now().Sub(start).Milliseconds()
		return response, fmt.Errorf("%w: %v", ErrSpireInvalidEntry, parseParentErr)
	}

	selectors := make([]*spiretypes.Selector, 0, len(req.Selectors))
	for _, s := range req.Selectors {
		parts := strings.SplitN(s, ":", 2)
		if len(parts) == 2 {
			selectors = append(selectors, &spiretypes.Selector{
				Type:  parts[0],
				Value: parts[1],
			})
		}
	}
	if len(selectors) == 0 {
		ns := req.Namespace
		if ns == "" {
			ns = "fe-signalloom-agents"
		}
		selectors = append(selectors,
			&spiretypes.Selector{Type: "k8s", Value: fmt.Sprintf("ns:%s", ns)},
			&spiretypes.Selector{Type: "k8s", Value: fmt.Sprintf("sa:%s", req.AgentID)},
		)
	}

	entryReq := &entryv1.BatchCreateEntryRequest{
		Entries: []*spiretypes.Entry{
			{
				SpiffeId:  spiffeID,
				ParentId:  parsedParent,
				Selectors: selectors,
			},
		},
	}

	resp, rpcErr := client.BatchCreateEntry(ctx, entryReq)
	response.LatencyMs = c.now().Sub(start).Milliseconds()

	if rpcErr != nil {
		st, _ := status.FromError(rpcErr)
		outcome, typedErr, isIdempotent := MapGRPCStatusToOutcome(st.Code(), st.Message(), rpcErr)
		response.Outcome = outcome
		response.Error = rpcErr.Error()
		if isIdempotent || st.Code() == codes.AlreadyExists {
			response.Outcome = OutcomeContained
			response.EntryCreated = true
			response.Error = ""
			return response, nil
		}
		return response, typedErr
	}

	if resp != nil && len(resp.Results) > 0 {
		res := resp.Results[0]
		if res.Status != nil {
			statusCode := codes.Code(res.Status.Code)
			outcome, typedErr, isIdempotent := MapGRPCStatusToOutcome(statusCode, res.Status.Message, nil)
			if statusCode == codes.AlreadyExists || isIdempotent {
				response.Outcome = OutcomeContained
				response.EntryCreated = true
			} else if typedErr != nil {
				response.Outcome = outcome
				response.Error = typedErr.Error()
				return response, typedErr
			} else {
				response.Outcome = OutcomeContained
				response.EntryCreated = true
				if res.Entry != nil {
					response.EntryID = res.Entry.Id
				}
			}
		}
	}

	response.Outcome = OutcomeContained
	slog.Info("spire reentry completed",
		"event", SpireReentryEventName,
		"agent_id", req.AgentID,
		"spiffe_id", req.SPIFFEID,
		"entry_created", response.EntryCreated,
		"outcome", string(response.Outcome),
		"latency_ms", response.LatencyMs,
		"idempotency_key", req.IdempotencyKey)

	return response, nil
}

// Health checks if SPIRE Server is responding to API queries.
func (c *grpcSpireClient) Health(ctx context.Context) error {
	// Same typed-nil guard as EvictAgent — /health must report unavailable rather
	// than crash the process that answers the readiness probe.
	if c == nil {
		return fmt.Errorf("spire client not initialised: %w", ErrEnforcementUnavailable)
	}
	client, err := c.getEntryClient()
	if err != nil {
		return fmt.Errorf("spire health check failed: %w", err)
	}

	req := &entryv1.CountEntriesRequest{}
	_, rpcErr := client.CountEntries(ctx, req)
	if rpcErr != nil {
		st, _ := status.FromError(rpcErr)
		return fmt.Errorf("spire server health probe failed (code %v): %w", st.Code(), ErrEnforcementUnavailable)
	}
	return nil
}

// Close closes the underlying gRPC client connection.
func (c *grpcSpireClient) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn != nil {
		err := c.conn.Close()
		c.conn = nil
		c.entryClient = nil
		return err
	}
	return nil
}
