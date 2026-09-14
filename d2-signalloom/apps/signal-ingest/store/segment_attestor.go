package store

import (
	"bufio"
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/thanos-io/objstore"
)

const (
	segmentSchema        = "signalloom.segment/v1"
	segmentErrorSchema   = "signalloom.segment.error/v1"
	segmentScope         = "signaldb/observations"
	segmentPredicateType = "https://controlplane.io/attestations/signalloom-segment/v1"
	checkpointSchema     = "signalloom.audit.checkpoint/v1"
	checkpointPredicate  = "https://controlplane.io/attestations/signalloom-audit-checkpoint/v1"
	highWaterSchema      = "signalloom.segment.highwater/v1"
	dssePayloadType      = "application/vnd.in-toto+json"
	inTotoStatementType  = "https://in-toto.io/Statement/v1"
)

var errAttestationQueueFull = errors.New("segment attestation queue full")

var (
	segmentReadDir = os.ReadDir
	segmentLstat   = os.Lstat
)

type SegmentAttestorConfig struct {
	EvidenceDir        string
	Signer             Signer
	PrivateKeyPath     string
	HighWaterPath      string
	ArchivistaURL      string
	RequireArchivista  bool
	QueueSize          int
	HTTPClient         *http.Client
	SegmentRoot        string
	ErrorQueueSize     int
	PublicationTimeout time.Duration
}

type segmentUpload struct {
	name   string
	digest string
	size   int64
}

type attestorRequest struct {
	upload  *segmentUpload
	barrier chan struct{}
}

type attestorErrorRequest struct {
	operation string
	upload    segmentUpload
	cause     error
	barrier   chan struct{}
}

type SegmentAttestor struct {
	cfg           SegmentAttestorConfig
	signer        Signer
	queue         chan attestorRequest
	done          chan struct{}
	errorDone     chan struct{}
	errorCond     *sync.Cond
	pendingErrors []attestorErrorRequest
	journal       map[string]segmentUpload
	nextSeq       uint64
	prevCP        string
	queueMu       sync.RWMutex
	errorMu       sync.Mutex
	processingMu  sync.RWMutex
	processingErr error
	errorsMu      sync.Mutex
	highWaterMu   sync.Mutex
	closed        bool
	errorClosed   bool
	overflows     atomic.Uint64
	lostErrors    atomic.Uint64
	durableErrors atomic.Uint64
}

// SegmentAttestorStatus makes bounded-queue losses observable without waiting
// for filesystem or network I/O.
type SegmentAttestorStatus struct {
	QueueOverflows      uint64
	ErrorQueueOverflows uint64
	DurableErrors       uint64
	ProcessingError     string
}

func (a *SegmentAttestor) Status() SegmentAttestorStatus {
	a.processingMu.RLock()
	processingError := ""
	if a.processingErr != nil {
		processingError = a.processingErr.Error()
	}
	a.processingMu.RUnlock()
	return SegmentAttestorStatus{
		QueueOverflows:      a.overflows.Load(),
		ErrorQueueOverflows: a.lostErrors.Load(),
		DurableErrors:       a.durableErrors.Load(),
		ProcessingError:     processingError,
	}
}

type segmentRecord struct {
	SchemaVersion       string               `json:"schema_version"`
	Sequence            uint64               `json:"sequence"`
	SegmentID           string               `json:"segment_id"`
	Digest              string               `json:"digest"`
	ByteLength          int64                `json:"byte_length"`
	SignerKeyID         string               `json:"signer_key_id"`
	KeyVersion          string               `json:"key_version,omitempty"`
	State               string               `json:"state"`
	Error               string               `json:"error"`
	Attestation         string               `json:"attestation"`
	CheckpointInclusion *checkpointInclusion `json:"checkpoint_inclusion"`
}

type checkpointInclusion struct {
	CheckpointIndex uint64 `json:"checkpoint_index"`
	LeafIndex       uint64 `json:"leaf_index"`
}

type checkpoint struct {
	TenantScope          string  `json:"tenant_scope"`
	Index                uint64  `json:"index"`
	PrevCheckpointDigest string  `json:"prev_checkpoint_digest"`
	WindowStartExclusive *string `json:"window_start_exclusive"`
	WindowEndInclusive   string  `json:"window_end_inclusive"`
	RowCount             uint64  `json:"row_count"`
	CumulativeRowCount   uint64  `json:"cumulative_row_count"`
	MerkleRoot           string  `json:"merkle_root"`
	BoundaryBasis        string  `json:"boundary_basis"`
	SchemaVersion        string  `json:"schema_version"`
	SignerKeyID          string  `json:"signer_key_id,omitempty"`
	KeyVersion           string  `json:"key_version,omitempty"`
}

type protectedHighWater struct {
	SchemaVersion      string   `json:"schema_version"`
	MaxSequence        uint64   `json:"max_sequence"`
	JournalSize        int64    `json:"journal_size"`
	AttestationCount   int      `json:"attestation_count"`
	CheckpointCount    int      `json:"checkpoint_count"`
	LastSegmentID      string   `json:"last_segment_id"`
	LastDigest         string   `json:"last_digest"`
	HistoricalSegments []string `json:"historical_segments,omitempty"`
	LostErrorCount     uint64   `json:"lost_error_count,omitempty"`
}

type dsseEnvelope struct {
	PayloadType string          `json:"payloadType"`
	Payload     string          `json:"payload"`
	Signatures  []dsseSignature `json:"signatures"`
}

type dsseSignature struct {
	KeyID string `json:"keyid"`
	Sig   string `json:"sig"`
}

func dssePAE(payloadType string, payload []byte) []byte {
	return []byte(fmt.Sprintf("DSSEv1 %d %s %d %s", len([]byte(payloadType)), payloadType, len(payload), payload))
}

func hexDigest(raw []byte) string { return hex.EncodeToString(raw) }

func NewSegmentAttestor(cfg SegmentAttestorConfig) (*SegmentAttestor, error) {
	if cfg.EvidenceDir == "" || cfg.HighWaterPath == "" {
		return nil, errors.New("segment attestor requires evidence directory and protected highwater path")
	}
	if cfg.Signer == nil && cfg.PrivateKeyPath == "" {
		return nil, errors.New("segment attestor requires either Signer or PrivateKeyPath")
	}
	if cfg.RequireArchivista && cfg.ArchivistaURL == "" {
		return nil, errors.New("segment attestor requires Archivista URL when publication is required")
	}
	if cfg.QueueSize <= 0 {
		cfg.QueueSize = 16
	}
	if cfg.ErrorQueueSize <= 0 {
		cfg.ErrorQueueSize = 128
	}
	if cfg.PublicationTimeout <= 0 {
		cfg.PublicationTimeout = 10 * time.Second
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: 10 * time.Second}
	}
	signer := cfg.Signer
	if signer == nil {
		var err error
		signer, err = NewLocalEd25519Signer(cfg.PrivateKeyPath)
		if err != nil {
			return nil, err
		}
	}
	for _, directory := range []string{cfg.EvidenceDir, filepath.Join(cfg.EvidenceDir, "attestations"), filepath.Join(cfg.EvidenceDir, "checkpoints"), filepath.Join(cfg.EvidenceDir, "keys")} {
		if err := os.MkdirAll(directory, 0o750); err != nil {
			return nil, fmt.Errorf("create segment evidence directory: %w", err)
		}
	}
	// Persist/retain public key verification material for offline corpus verification
	if pub := signer.PublicKey(); pub != nil {
		pubDER, err := x509.MarshalPKIXPublicKey(pub)
		if err != nil {
			return nil, fmt.Errorf("marshal signer public key: %w", err)
		}
		pubPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER})
		pubPath := filepath.Join(cfg.EvidenceDir, "keys", signer.KeyID()+".pem")
		if err := atomicWrite(pubPath, pubPEM, 0o644); err != nil {
			return nil, fmt.Errorf("persist signer public key verification material: %w", err)
		}
	}
	a := &SegmentAttestor{
		cfg: cfg, signer: signer, queue: make(chan attestorRequest, cfg.QueueSize), done: make(chan struct{}),
		errorDone: make(chan struct{}), journal: map[string]segmentUpload{}, prevCP: strings.Repeat("0", 64),
	}
	a.errorCond = sync.NewCond(&a.errorMu)
	if err := a.loadState(); err != nil {
		return nil, err
	}
	go a.run()
	go a.runErrors()
	return a, nil
}

func (a *SegmentAttestor) loadState() error {
	if _, err := os.Stat(a.cfg.HighWaterPath); errors.Is(err, os.ErrNotExist) {
		hasEvidence, evidenceErr := hasSegmentEvidence(a.cfg.EvidenceDir)
		if evidenceErr != nil {
			return evidenceErr
		}
		if hasEvidence {
			return errors.New("segment attestor evidence exists without protected highwater")
		}
		if a.cfg.SegmentRoot != "" {
			historical, inventoryErr := segmentInventory(a.cfg.SegmentRoot)
			if inventoryErr != nil {
				return inventoryErr
			}
			if err := a.replaceHighWater(protectedHighWater{SchemaVersion: highWaterSchema, HistoricalSegments: historical}); err != nil {
				return err
			}
		}
	} else if err != nil {
		return fmt.Errorf("inspect protected highwater: %w", err)
	}
	path := filepath.Join(a.cfg.EvidenceDir, "segments.jsonl")
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		if err := a.validateHighWater(nil); err != nil {
			return err
		}
		return a.validateSegmentInventory(nil)
	}
	if err != nil {
		return fmt.Errorf("open segment journal: %w", err)
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	var records []segmentRecord
	for scanner.Scan() {
		var record segmentRecord
		if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
			return fmt.Errorf("read segment journal: %w", err)
		}
		if record.Sequence != uint64(len(records)+1) {
			return fmt.Errorf("segment journal sequence %d at position %d", record.Sequence, len(records)+1)
		}
		records = append(records, record)
		if record.State == "ok" {
			a.journal[record.SegmentID] = segmentUpload{name: record.SegmentID, digest: record.Digest, size: record.ByteLength}
		}
		a.nextSeq = record.Sequence
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("scan segment journal: %w", err)
	}
	if err := a.validateHighWater(records); err != nil {
		return err
	}
	if err := a.validateSegmentInventory(records); err != nil {
		return err
	}
	if a.nextSeq == 0 {
		return nil
	}
	entries, err := filepath.Glob(filepath.Join(a.cfg.EvidenceDir, "checkpoints", fmt.Sprintf("%08d-*.dsse.json", a.nextSeq-1)))
	if err != nil {
		return err
	}
	if len(entries) != 1 {
		return fmt.Errorf("checkpoint inventory has %d checkpoints for journal sequence %d", len(entries), a.nextSeq)
	}
	raw, err := os.ReadFile(entries[0])
	if err != nil {
		return err
	}
	var envelope dsseEnvelope
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return err
	}
	payload, err := base64.StdEncoding.DecodeString(envelope.Payload)
	if err != nil {
		return err
	}
	var statement struct {
		Subject []struct {
			Digest map[string]string `json:"digest"`
		} `json:"subject"`
	}
	if err := json.Unmarshal(payload, &statement); err != nil {
		return fmt.Errorf("read latest checkpoint subject: %w", err)
	}
	if len(statement.Subject) != 1 {
		return errors.New("read latest checkpoint subject: expected exactly one subject")
	}
	a.prevCP = statement.Subject[0].Digest["sha256"]
	if len(a.prevCP) != sha256.Size*2 {
		return errors.New("read latest checkpoint subject: invalid SHA-256 digest")
	}
	return nil
}

func (a *SegmentAttestor) validateHighWater(records []segmentRecord) error {
	raw, err := os.ReadFile(a.cfg.HighWaterPath)
	if errors.Is(err, os.ErrNotExist) {
		hasEvidence, evidenceErr := hasSegmentEvidence(a.cfg.EvidenceDir)
		if evidenceErr != nil {
			return evidenceErr
		}
		if hasEvidence {
			return errors.New("segment attestor evidence exists without protected highwater")
		}
		if a.cfg.SegmentRoot == "" {
			return nil
		}
		historical, inventoryErr := segmentInventory(a.cfg.SegmentRoot)
		if inventoryErr != nil {
			return inventoryErr
		}
		return a.replaceHighWater(protectedHighWater{SchemaVersion: highWaterSchema, HistoricalSegments: historical})
	}
	if err != nil {
		return fmt.Errorf("read protected highwater: %w", err)
	}
	var high protectedHighWater
	if err := json.Unmarshal(raw, &high); err != nil {
		return fmt.Errorf("parse protected highwater: %w", err)
	}
	if high.SchemaVersion != highWaterSchema {
		return fmt.Errorf("protected highwater has unsupported schema %q", high.SchemaVersion)
	}
	journalPath := filepath.Join(a.cfg.EvidenceDir, "segments.jsonl")
	if uint64(len(records)) < high.MaxSequence || fileSize(journalPath) < high.JournalSize {
		return errors.New("segment journal is below protected highwater")
	}
	if countFiles(filepath.Join(a.cfg.EvidenceDir, "attestations", "*.dsse.json")) < high.AttestationCount {
		return errors.New("segment attestation inventory is below protected highwater")
	}
	if countFiles(filepath.Join(a.cfg.EvidenceDir, "checkpoints", "*.dsse.json")) < high.CheckpointCount {
		return errors.New("segment checkpoint inventory is below protected highwater")
	}
	if high.MaxSequence > 0 {
		tip := records[high.MaxSequence-1]
		if tip.SegmentID != high.LastSegmentID || tip.Digest != high.LastDigest {
			return errors.New("segment tip differs from protected highwater")
		}
	}
	return nil
}

func (a *SegmentAttestor) validateSegmentInventory(records []segmentRecord) error {
	if a.cfg.SegmentRoot == "" {
		return nil
	}
	raw, err := os.ReadFile(a.cfg.HighWaterPath)
	if err != nil {
		return fmt.Errorf("read protected highwater inventory: %w", err)
	}
	var high protectedHighWater
	if err := json.Unmarshal(raw, &high); err != nil {
		return fmt.Errorf("parse protected highwater inventory: %w", err)
	}
	allowed := append([]string(nil), high.HistoricalSegments...)
	for _, record := range records {
		if record.State == "ok" {
			allowed = append(allowed, record.SegmentID)
		}
	}
	slices.Sort(allowed)
	allowed = slices.Compact(allowed)
	actual, err := segmentInventory(a.cfg.SegmentRoot)
	if err != nil {
		return err
	}
	if !slices.Equal(actual, allowed) {
		return fmt.Errorf("persisted segment inventory differs from protected history and journal: got %v, want %v", actual, allowed)
	}
	return nil
}

func segmentInventory(root string) ([]string, error) {
	scope := filepath.Join(root, filepath.FromSlash(segmentScope))
	scopeInfo, err := segmentLstat(scope)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("inspect persisted segment scope: %w", err)
	}
	if scopeInfo.Mode()&os.ModeSymlink != 0 || !scopeInfo.IsDir() {
		return nil, fmt.Errorf("persisted segment scope %s is not a regular directory", scope)
	}
	blocks, err := segmentReadDir(scope)
	if err != nil {
		return nil, fmt.Errorf("read persisted segment scope: %w", err)
	}
	result := make([]string, 0, len(blocks))
	for _, block := range blocks {
		if block.Type()&os.ModeSymlink != 0 || !block.IsDir() {
			return nil, fmt.Errorf("persisted segment block %s is not a regular directory", block.Name())
		}
		blockPath := filepath.Join(scope, block.Name())
		entries, err := segmentReadDir(blockPath)
		if err != nil {
			return nil, fmt.Errorf("read persisted segment block %s: %w", block.Name(), err)
		}
		if !slices.ContainsFunc(entries, func(entry os.DirEntry) bool { return entry.Name() == "data.parquet" }) {
			continue
		}
		path := filepath.Join(blockPath, "data.parquet")
		info, err := segmentLstat(path)
		if err != nil {
			return nil, fmt.Errorf("inspect persisted segment %s: %w", block.Name(), err)
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return nil, fmt.Errorf("persisted segment %s is not a regular file", block.Name())
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return nil, fmt.Errorf("resolve persisted segment path: %w", err)
		}
		result = append(result, filepath.ToSlash(relative))
	}
	slices.Sort(result)
	return result, nil
}

func hasSegmentEvidence(root string) (bool, error) {
	for _, name := range []string{"segments.jsonl", "segments.errors.jsonl"} {
		if _, err := segmentLstat(filepath.Join(root, name)); err == nil {
			return true, nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return false, fmt.Errorf("inspect segment evidence %s: %w", name, err)
		}
	}
	for _, name := range []string{"attestations", "checkpoints"} {
		entries, err := segmentReadDir(filepath.Join(root, name))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return false, fmt.Errorf("read segment evidence directory %s: %w", name, err)
		}
		if len(entries) > 0 {
			return true, nil
		}
	}
	return false, nil
}

func (a *SegmentAttestor) enqueue(upload segmentUpload) {
	a.queueMu.RLock()
	if a.closed {
		a.queueMu.RUnlock()
		a.reportError("enqueue", upload, errors.New("segment attestor closed"))
		return
	}
	select {
	case a.queue <- attestorRequest{upload: &upload}:
	default:
		a.overflows.Add(1)
		a.queueMu.RUnlock()
		a.reportError("queue_overflow", upload, errAttestationQueueFull)
		return
	}
	a.queueMu.RUnlock()
}

func (a *SegmentAttestor) Wait(ctx context.Context) error {
	barrier := make(chan struct{})
	a.queueMu.RLock()
	if a.closed {
		a.queueMu.RUnlock()
		return waitForSignal(ctx, a.errorDone)
	}
	select {
	case a.queue <- attestorRequest{barrier: barrier}:
		a.queueMu.RUnlock()
	case <-ctx.Done():
		a.queueMu.RUnlock()
		return ctx.Err()
	}
	select {
	case <-barrier:
		errorBarrier := make(chan struct{})
		a.errorMu.Lock()
		if a.errorClosed {
			a.errorMu.Unlock()
			return waitForSignal(ctx, a.errorDone)
		}
		a.pendingErrors = append(a.pendingErrors, attestorErrorRequest{barrier: errorBarrier})
		a.errorCond.Signal()
		a.errorMu.Unlock()
		select {
		case <-errorBarrier:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	case <-ctx.Done():
		return ctx.Err()
	}
}

func waitForSignal(ctx context.Context, signal <-chan struct{}) error {
	select {
	case <-signal:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (a *SegmentAttestor) Close() error {
	a.queueMu.Lock()
	if !a.closed {
		a.closed = true
		close(a.queue)
	}
	a.queueMu.Unlock()
	<-a.done
	a.errorMu.Lock()
	if !a.errorClosed {
		a.errorClosed = true
		a.errorCond.Broadcast()
	}
	a.errorMu.Unlock()
	<-a.errorDone
	return nil
}

func (a *SegmentAttestor) run() {
	defer close(a.done)
	for request := range a.queue {
		if request.barrier != nil {
			a.persistLostErrors()
			close(request.barrier)
			continue
		}
		if processingErr := a.getProcessingError(); processingErr != nil {
			a.reportError("worker_degraded", *request.upload, processingErr)
			continue
		}
		if err := a.process(*request.upload); err != nil {
			a.reportError("attest", *request.upload, err)
			a.setProcessingError(err)
		}
	}
}

func (a *SegmentAttestor) runErrors() {
	defer close(a.errorDone)
	for {
		a.errorMu.Lock()
		for len(a.pendingErrors) == 0 && !a.errorClosed {
			a.errorCond.Wait()
		}
		if len(a.pendingErrors) == 0 {
			a.errorMu.Unlock()
			return
		}
		request := a.pendingErrors[0]
		a.pendingErrors[0] = attestorErrorRequest{}
		a.pendingErrors = a.pendingErrors[1:]
		a.errorMu.Unlock()
		if request.barrier != nil {
			close(request.barrier)
			continue
		}
		a.recordError(request.operation, request.upload, request.cause)
		a.persistLostErrors()
	}
}

func (a *SegmentAttestor) reportError(operation string, upload segmentUpload, cause error) {
	a.errorMu.Lock()
	if a.errorClosed {
		a.errorMu.Unlock()
		a.lostErrors.Add(1)
		return
	}
	if len(a.pendingErrors) >= a.cfg.ErrorQueueSize {
		a.errorMu.Unlock()
		a.lostErrors.Add(1)
		return
	}
	a.pendingErrors = append(a.pendingErrors, attestorErrorRequest{operation: operation, upload: upload, cause: cause})
	a.errorCond.Signal()
	a.errorMu.Unlock()
}

func (a *SegmentAttestor) getProcessingError() error {
	a.processingMu.RLock()
	defer a.processingMu.RUnlock()
	return a.processingErr
}

func (a *SegmentAttestor) setProcessingError(err error) {
	a.processingMu.Lock()
	a.processingErr = err
	a.processingMu.Unlock()
}

func (a *SegmentAttestor) process(upload segmentUpload) error {
	if existing, ok := a.journal[upload.name]; ok {
		if existing.digest == upload.digest && existing.size == upload.size {
			return nil
		}
		return fmt.Errorf("immutable segment %s reuploaded with different bytes", upload.name)
	}
	sequence := a.nextSeq + 1
	attestationPath := filepath.Join("attestations", fmt.Sprintf("%020d.dsse.json", sequence))
	keyID := a.signer.KeyID()
	keyVersion := a.signer.KeyVersion()
	record := segmentRecord{
		SchemaVersion: segmentSchema, Sequence: sequence, SegmentID: upload.name, Digest: upload.digest,
		ByteLength: upload.size, SignerKeyID: keyID, KeyVersion: keyVersion, State: "ok", Error: "", Attestation: filepath.ToSlash(attestationPath),
		CheckpointInclusion: &checkpointInclusion{CheckpointIndex: sequence - 1, LeafIndex: 0},
	}
	predicate := map[string]any{
		"schema_version": record.SchemaVersion, "sequence": record.Sequence, "segment_id": record.SegmentID,
		"digest": record.Digest, "byte_length": record.ByteLength, "signer_key_id": record.SignerKeyID,
		"state": record.State, "error": record.Error,
	}
	if record.KeyVersion != "" {
		predicate["key_version"] = record.KeyVersion
	}
	statement := map[string]any{
		"_type":         inTotoStatementType,
		"subject":       []any{map[string]any{"name": record.SegmentID, "digest": map[string]any{"sha256": record.Digest}}},
		"predicateType": segmentPredicateType, "predicate": predicate,
	}
	envelope, err := a.signer.Sign(context.Background(), statement)
	if err != nil {
		return fmt.Errorf("sign segment: %w", err)
	}
	if err := atomicWrite(filepath.Join(a.cfg.EvidenceDir, attestationPath), append(envelope, '\n'), 0o640); err != nil {
		return fmt.Errorf("persist segment attestation: %w", err)
	}
	if a.cfg.ArchivistaURL != "" {
		if err := a.publishArchivista(envelope); err != nil {
			return err
		}
	}
	journalBytes, err := json.Marshal(record)
	if err != nil {
		return err
	}
	cpDigest, err := a.checkpoint(record)
	if err != nil {
		return err
	}
	if err := appendDurable(filepath.Join(a.cfg.EvidenceDir, "segments.jsonl"), append(journalBytes, '\n')); err != nil {
		return fmt.Errorf("append segment journal: %w", err)
	}
	a.journal[upload.name] = upload
	a.nextSeq = sequence
	a.prevCP = cpDigest
	return a.writeHighWater(record)
}

func (a *SegmentAttestor) checkpoint(record segmentRecord) (string, error) {
	end := fmt.Sprintf("%020d", record.Sequence)
	var start *string
	if record.Sequence > 1 {
		value := fmt.Sprintf("%020d", record.Sequence-1)
		start = &value
	}
	row := map[string]*string{
		"id": &record.SegmentID, "tenant_id": stringPointer(segmentScope), "ts": &end,
		"event_type": stringPointer("segment.persisted"), "agent_id": nil, "agent_name": nil,
		"actor": &record.SignerKeyID,
	}
	detail, err := json.Marshal(segmentRecordMap(record))
	if err != nil {
		return "", err
	}
	detailString := string(detail)
	row["detail"] = &detailString
	leaf := sha256.Sum256(append([]byte{0}, encodeAuditRow(row)...))
	cp := checkpoint{
		SchemaVersion: checkpointSchema, TenantScope: segmentScope, Index: record.Sequence - 1,
		PrevCheckpointDigest: a.prevCP, WindowStartExclusive: start, WindowEndInclusive: end,
		RowCount: 1, CumulativeRowCount: record.Sequence, MerkleRoot: hexDigest(leaf[:]), BoundaryBasis: "segment_sequence",
		SignerKeyID: record.SignerKeyID, KeyVersion: record.KeyVersion,
	}
	cpDigest := checkpointDigest(cp)
	statement := map[string]any{
		"_type":         inTotoStatementType,
		"subject":       []any{map[string]any{"name": fmt.Sprintf("signalloom-segment-checkpoint/%s/%08d", segmentScope, cp.Index), "digest": map[string]any{"sha256": cpDigest}}},
		"predicateType": checkpointPredicate, "predicate": checkpointMap(cp),
	}
	envelope, err := a.signer.Sign(context.Background(), statement)
	if err != nil {
		return "", fmt.Errorf("sign checkpoint: %w", err)
	}
	name := fmt.Sprintf("%08d-%s.dsse.json", cp.Index, cpDigest[:12])
	if err := atomicWrite(filepath.Join(a.cfg.EvidenceDir, "checkpoints", name), append(envelope, '\n'), 0o640); err != nil {
		return "", fmt.Errorf("persist checkpoint: %w", err)
	}
	if a.cfg.ArchivistaURL != "" {
		if err := a.publishArchivista(envelope); err != nil {
			return "", err
		}
	}
	return cpDigest, nil
}

func (a *SegmentAttestor) publishArchivista(envelope []byte) error {
	url := strings.TrimRight(a.cfg.ArchivistaURL, "/") + "/upload"
	timeout := a.cfg.PublicationTimeout
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(string(envelope)))
	if err != nil {
		return fmt.Errorf("create Archivista request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	response, err := a.cfg.HTTPClient.Do(req)
	if err != nil {
		return fmt.Errorf("Archivista publication failed: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, response.Body)
		return fmt.Errorf("Archivista publication failed: HTTP %s", response.Status)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("read Archivista publication response: %w", err)
	}
	receipt := strings.TrimSpace(string(body))
	var payload struct {
		Gitoid string `json:"gitoid"`
	}
	if json.Unmarshal(body, &payload) == nil {
		receipt = payload.Gitoid
	}
	receiptDigest, ok := parseGitoid(receipt)
	if !ok {
		return errors.New("Archivista publication failed: response does not contain a valid gitoid")
	}
	framed := append([]byte(fmt.Sprintf("blob %d\x00", len(envelope))), envelope...)
	expected := sha256.Sum256(framed)
	if receiptDigest != hexDigest(expected[:]) {
		return errors.New("Archivista publication failed: receipt gitoid does not match uploaded envelope")
	}
	return nil
}

func parseGitoid(value string) (string, bool) {
	value = strings.TrimSpace(value)
	value = strings.TrimPrefix(value, "sha256:")
	if len(value) != sha256.Size*2 {
		return "", false
	}
	decoded, err := hex.DecodeString(value)
	return value, err == nil && len(decoded) == sha256.Size && value == strings.ToLower(value)
}

func (a *SegmentAttestor) writeHighWater(record segmentRecord) error {
	a.highWaterMu.Lock()
	defer a.highWaterMu.Unlock()
	previous, err := readHighWater(a.cfg.HighWaterPath)
	if err != nil {
		return err
	}
	state := protectedHighWater{
		SchemaVersion: highWaterSchema, MaxSequence: record.Sequence,
		JournalSize:      fileSize(filepath.Join(a.cfg.EvidenceDir, "segments.jsonl")),
		AttestationCount: countFiles(filepath.Join(a.cfg.EvidenceDir, "attestations", "*.dsse.json")),
		CheckpointCount:  countFiles(filepath.Join(a.cfg.EvidenceDir, "checkpoints", "*.dsse.json")),
		LastSegmentID:    record.SegmentID, LastDigest: record.Digest,
		HistoricalSegments: previous.HistoricalSegments, LostErrorCount: a.lostErrors.Load(),
	}
	if err := validateHighWaterReplacement(previous, state); err != nil {
		return err
	}
	return a.replaceHighWater(state)
}

func (a *SegmentAttestor) persistLostErrors() {
	if a.lostErrors.Load() == 0 {
		return
	}
	a.highWaterMu.Lock()
	defer a.highWaterMu.Unlock()
	state, err := readHighWater(a.cfg.HighWaterPath)
	if err != nil || state.SchemaVersion == "" || state.LostErrorCount >= a.lostErrors.Load() {
		return
	}
	state.LostErrorCount = a.lostErrors.Load()
	if err := a.replaceHighWater(state); err != nil {
		slog.Error("segment error loss could not be protected", "error", err)
	}
}

func readHighWater(path string) (protectedHighWater, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return protectedHighWater{}, nil
	}
	if err != nil {
		return protectedHighWater{}, fmt.Errorf("read protected highwater: %w", err)
	}
	var state protectedHighWater
	if err := json.Unmarshal(raw, &state); err != nil {
		return protectedHighWater{}, fmt.Errorf("parse protected highwater: %w", err)
	}
	return state, nil
}

func validateHighWaterReplacement(previous, next protectedHighWater) error {
	if next.MaxSequence < previous.MaxSequence {
		return errors.New("protected highwater sequence regression")
	}
	if next.AttestationCount < previous.AttestationCount {
		return errors.New("protected highwater attestation count regression")
	}
	if next.CheckpointCount < previous.CheckpointCount {
		return errors.New("protected highwater checkpoint count regression")
	}
	if next.JournalSize < previous.JournalSize {
		return errors.New("protected highwater journal size regression")
	}
	if next.LostErrorCount < previous.LostErrorCount {
		return errors.New("protected highwater lost error count regression")
	}
	if next.MaxSequence == previous.MaxSequence && previous.MaxSequence > 0 &&
		(next.LastSegmentID != previous.LastSegmentID || next.LastDigest != previous.LastDigest) {
		return errors.New("protected highwater equal-sequence tip mutation")
	}
	if previous.SchemaVersion != "" && !slices.Equal(next.HistoricalSegments, previous.HistoricalSegments) {
		return errors.New("protected highwater historical segment inventory mutation")
	}
	return nil
}

func (a *SegmentAttestor) replaceHighWater(state protectedHighWater) error {
	raw, err := json.Marshal(state)
	if err != nil {
		return err
	}
	return atomicWrite(a.cfg.HighWaterPath, append(raw, '\n'), 0o600)
}

func (a *SegmentAttestor) recordError(operation string, upload segmentUpload, cause error) {
	a.errorsMu.Lock()
	defer a.errorsMu.Unlock()
	record := map[string]any{
		"schema_version": segmentErrorSchema, "timestamp": time.Now().UTC().Format(time.RFC3339Nano),
		"operation": operation, "segment_id": upload.name, "digest": upload.digest,
		"byte_length": upload.size, "error": cause.Error(),
	}
	raw, _ := json.Marshal(record)
	path := filepath.Join(a.cfg.EvidenceDir, "segments.errors.jsonl")
	if err := appendDurable(path, append(raw, '\n')); err != nil {
		slog.Error("segment attestation failure could not be recorded", "operation", operation, "segment_id", upload.name, "error", cause, "record_error", err)
		return
	}
	a.durableErrors.Add(1)
	slog.Error("segment attestation failed", "operation", operation, "segment_id", upload.name, "error", cause)
}

type attestingBucket struct {
	objstore.Bucket
	attestor *SegmentAttestor
}

func newAttestingBucket(bucket objstore.Bucket, attestor *SegmentAttestor) objstore.Bucket {
	return &attestingBucket{Bucket: bucket, attestor: attestor}
}

func (b *attestingBucket) Upload(ctx context.Context, name string, reader io.Reader) error {
	hash := sha256.New()
	counting := &countingWriter{writer: hash}
	if err := b.Bucket.Upload(ctx, name, io.TeeReader(reader, counting)); err != nil {
		return err
	}
	if strings.HasPrefix(filepath.ToSlash(name), segmentScope+"/") && strings.HasSuffix(name, "/data.parquet") {
		b.attestor.enqueue(segmentUpload{name: filepath.ToSlash(name), digest: hexDigest(hash.Sum(nil)), size: counting.count})
	}
	return nil
}

type countingWriter struct {
	writer io.Writer
	count  int64
}

func (w *countingWriter) Write(p []byte) (int, error) {
	n, err := w.writer.Write(p)
	w.count += int64(n)
	return n, err
}

func encodeField(value *string) []byte {
	if value == nil {
		return []byte{0}
	}
	raw := []byte(*value)
	out := make([]byte, 9+len(raw))
	out[0] = 1
	binary.BigEndian.PutUint64(out[1:9], uint64(len(raw)))
	copy(out[9:], raw)
	return out
}

func encodeAuditRow(row map[string]*string) []byte {
	version := "signalloom.audit.row/v1"
	parts := [][]byte{encodeField(&version)}
	for _, name := range []string{"id", "tenant_id", "ts", "event_type", "agent_id", "agent_name", "actor", "detail"} {
		parts = append(parts, encodeField(row[name]))
	}
	return bytesJoin(parts)
}

func bytesJoin(parts [][]byte) []byte {
	var out []byte
	for _, part := range parts {
		out = append(out, part...)
	}
	return out
}
func stringPointer(value string) *string { return &value }

func checkpointDigest(cp checkpoint) string {
	values := []*string{
		stringPointer(checkpointSchema), &cp.TenantScope, stringPointer(fmt.Sprint(cp.Index)), &cp.PrevCheckpointDigest,
		cp.WindowStartExclusive, &cp.WindowEndInclusive, stringPointer(fmt.Sprint(cp.RowCount)),
		stringPointer(fmt.Sprint(cp.CumulativeRowCount)), &cp.MerkleRoot, &cp.BoundaryBasis,
	}
	var framed []byte
	for _, value := range values {
		framed = append(framed, encodeField(value)...)
	}
	digest := sha256.Sum256(framed)
	return hexDigest(digest[:])
}

func segmentRecordMap(record segmentRecord) map[string]any {
	m := map[string]any{
		"schema_version": record.SchemaVersion, "sequence": record.Sequence,
		"segment_id": record.SegmentID, "digest": record.Digest,
		"byte_length": record.ByteLength, "signer_key_id": record.SignerKeyID,
		"state": record.State, "error": record.Error, "attestation": record.Attestation,
		"checkpoint_inclusion": map[string]any{
			"checkpoint_index": record.CheckpointInclusion.CheckpointIndex,
			"leaf_index":       record.CheckpointInclusion.LeafIndex,
		},
	}
	if record.KeyVersion != "" {
		m["key_version"] = record.KeyVersion
	}
	return m
}

func checkpointMap(cp checkpoint) map[string]any {
	m := map[string]any{
		"schema_version": cp.SchemaVersion, "tenant_scope": cp.TenantScope,
		"index": cp.Index, "prev_checkpoint_digest": cp.PrevCheckpointDigest,
		"window_start_exclusive": cp.WindowStartExclusive, "window_end_inclusive": cp.WindowEndInclusive,
		"row_count": cp.RowCount, "cumulative_row_count": cp.CumulativeRowCount,
		"merkle_root": cp.MerkleRoot, "boundary_basis": cp.BoundaryBasis,
	}
	if cp.SignerKeyID != "" {
		m["signer_key_id"] = cp.SignerKeyID
	}
	if cp.KeyVersion != "" {
		m["key_version"] = cp.KeyVersion
	}
	return m
}

func appendDurable(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o640)
	if err != nil {
		return err
	}
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	return closeErr
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	tmp := temporary.Name()
	defer os.Remove(tmp)
	if err = temporary.Chmod(mode); err == nil {
		_, err = temporary.Write(data)
	}
	if err == nil {
		err = temporary.Sync()
	}
	if closeErr := temporary.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(tmp, path); err != nil {
		return err
	}
	directory, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func fileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}
func countFiles(pattern string) int { paths, _ := filepath.Glob(pattern); return len(paths) }
