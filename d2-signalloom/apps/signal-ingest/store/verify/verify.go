// Package verify independently verifies Signal Loom segment evidence corpora.
package verify

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
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
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
)

const (
	segmentSchema       = "signalloom.segment/v1"
	checkpointSchema    = "signalloom.audit.checkpoint/v1"
	highWaterSchema     = "signalloom.segment.highwater/v1"
	segmentScope        = "signaldb/observations"
	segmentPredicate    = "https://controlplane.io/attestations/signalloom-segment/v1"
	checkpointPredicate = "https://controlplane.io/attestations/signalloom-audit-checkpoint/v1"
	dssePayloadType     = "application/vnd.in-toto+json"
	statementType       = "https://in-toto.io/Statement/v1"
	maxEnvelopeBytes    = 4 << 20

	SemanticRedactionNotAssessed = "not_assessed"
	IntegrityScopeComplete       = "complete"
	IntegrityScopePartial        = "partial"
)

type Config struct {
	EvidenceDir    string
	SegmentRoot    string
	HighWaterPath  string
	PublicKeyPaths []string
}

type Result struct {
	Segments                     int    `json:"segments"`
	Checkpoints                  int    `json:"checkpoints"`
	TrustedKeys                  int    `json:"trusted_keys"`
	UnattestedHistoricalSegments int    `json:"unattested_historical_segments"`
	LostErrorCount               uint64 `json:"lost_error_count"`
	MaxSequence                  uint64 `json:"max_sequence"`
	CumulativeRows               uint64 `json:"cumulative_row_count"`
	TipCheckpoint                string `json:"tip_checkpoint_digest"`
	SignaturesVerified           bool   `json:"signatures_verified"`
	IntegrityScope               string `json:"integrity_scope"`
	SemanticRedaction            string `json:"semantic_redaction"`
}

type SegmentConfig struct {
	AttestationPath string
	SegmentPath     string
	PublicKeyPaths  []string
}

type SegmentResult struct {
	SegmentID         string `json:"segment_id"`
	Digest            string `json:"digest"`
	ByteLength        int64  `json:"byte_length"`
	SignerKeyID       string `json:"signer_key_id"`
	SignatureVerified bool   `json:"signature_verified"`
	SemanticRedaction string `json:"semantic_redaction"`
}

type Keyring map[string]ed25519.PublicKey

type evidenceIndex struct {
	attestationCount int
	checkpoints      map[uint64]string
}

type journalRecord struct {
	SchemaVersion       string               `json:"schema_version"`
	Sequence            uint64               `json:"sequence"`
	SegmentID           string               `json:"segment_id"`
	Digest              string               `json:"digest"`
	ByteLength          int64                `json:"byte_length"`
	SignerKeyID         string               `json:"signer_key_id"`
	State               string               `json:"state"`
	Error               string               `json:"error"`
	Attestation         string               `json:"attestation"`
	CheckpointInclusion *checkpointInclusion `json:"checkpoint_inclusion"`
}

type checkpointInclusion struct {
	CheckpointIndex uint64 `json:"checkpoint_index"`
	LeafIndex       uint64 `json:"leaf_index"`
}

type envelope struct {
	PayloadType string      `json:"payloadType"`
	Payload     string      `json:"payload"`
	Signatures  []signature `json:"signatures"`
}

type signature struct {
	KeyID string `json:"keyid"`
	Sig   string `json:"sig"`
}

type statement struct {
	Type          string          `json:"_type"`
	Subject       []subject       `json:"subject"`
	PredicateType string          `json:"predicateType"`
	Predicate     json.RawMessage `json:"predicate"`
}

type subject struct {
	Name   string        `json:"name"`
	Digest subjectDigest `json:"digest"`
}

type subjectDigest struct {
	SHA256 string `json:"sha256"`
}

type segmentClaim struct {
	SchemaVersion string `json:"schema_version"`
	Sequence      uint64 `json:"sequence"`
	SegmentID     string `json:"segment_id"`
	Digest        string `json:"digest"`
	ByteLength    int64  `json:"byte_length"`
	SignerKeyID   string `json:"signer_key_id"`
	State         string `json:"state"`
	Error         string `json:"error"`
}

type checkpointClaim struct {
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
}

type highWater struct {
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

func VerifyCorpus(ctx context.Context, cfg Config) (Result, error) {
	result := Result{SemanticRedaction: SemanticRedactionNotAssessed, IntegrityScope: IntegrityScopePartial}
	if cfg.EvidenceDir == "" || cfg.SegmentRoot == "" || cfg.HighWaterPath == "" {
		return result, errors.New("verify corpus requires evidence directory, segment root, and protected highwater path")
	}
	keys, err := LoadKeyring(cfg.PublicKeyPaths)
	if err != nil {
		return result, err
	}
	result.TrustedKeys = len(keys)
	index, err := indexEvidence(cfg.EvidenceDir)
	if err != nil {
		return result, err
	}
	records, journalSize, err := readJournal(filepath.Join(cfg.EvidenceDir, "segments.jsonl"))
	if err != nil {
		return result, err
	}
	previous := strings.Repeat("0", sha256.Size*2)
	for position, record := range records {
		if err := ctx.Err(); err != nil {
			return result, err
		}
		wantSequence := uint64(position + 1)
		if err := validateJournalRecord(record, wantSequence); err != nil {
			return result, err
		}
		if err := verifySegmentRecord(cfg, record, keys); err != nil {
			return result, fmt.Errorf("segment sequence %d: %w", record.Sequence, err)
		}
		checkpointPath, ok := index.checkpoints[record.Sequence-1]
		if !ok {
			return result, fmt.Errorf("checkpoint sequence %d: checkpoint index is missing", record.Sequence)
		}
		checkpointDigest, err := verifyCheckpoint(checkpointPath, record, previous, keys)
		if err != nil {
			return result, fmt.Errorf("checkpoint sequence %d: %w", record.Sequence, err)
		}
		previous = checkpointDigest
	}
	high, err := verifyHighWater(cfg, records, journalSize, index)
	if err != nil {
		return result, err
	}
	if index.attestationCount != len(records) || len(index.checkpoints) != len(records) {
		return result, errors.New("evidence inventory count differs from verified journal")
	}
	result.Segments = len(records)
	result.Checkpoints = len(index.checkpoints)
	result.MaxSequence = uint64(len(records))
	result.CumulativeRows = uint64(len(records))
	result.TipCheckpoint = previous
	result.SignaturesVerified = len(records) > 0
	result.UnattestedHistoricalSegments = len(high.HistoricalSegments)
	result.LostErrorCount = high.LostErrorCount
	if len(records) > 0 && len(high.HistoricalSegments) == 0 && high.LostErrorCount == 0 {
		result.IntegrityScope = IntegrityScopeComplete
	}
	return result, nil
}

func VerifySegment(ctx context.Context, cfg SegmentConfig) (SegmentResult, error) {
	result := SegmentResult{SemanticRedaction: SemanticRedactionNotAssessed}
	if cfg.AttestationPath == "" || cfg.SegmentPath == "" {
		return result, errors.New("verify segment requires attestation and segment paths")
	}
	if err := ctx.Err(); err != nil {
		return result, err
	}
	keys, err := LoadKeyring(cfg.PublicKeyPaths)
	if err != nil {
		return result, err
	}
	claim, signer, err := verifySegmentEvidence(cfg.AttestationPath, cfg.SegmentPath, keys)
	if err != nil {
		return result, err
	}
	result.SegmentID = claim.SegmentID
	result.Digest = claim.Digest
	result.ByteLength = claim.ByteLength
	result.SignerKeyID = signer
	result.SignatureVerified = true
	return result, nil
}

func LoadKeyring(paths []string) (Keyring, error) {
	if len(paths) == 0 {
		return nil, errors.New("verify corpus requires at least one external public key")
	}
	keys := make(Keyring, len(paths))
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read public key %s: %w", path, err)
		}
		block, rest := pem.Decode(raw)
		if block == nil || len(bytes.TrimSpace(rest)) != 0 {
			return nil, fmt.Errorf("parse public key %s: expected one PEM block", path)
		}
		parsed, err := x509.ParsePKIXPublicKey(block.Bytes)
		if err != nil {
			return nil, fmt.Errorf("parse public key %s: %w", path, err)
		}
		key, ok := parsed.(ed25519.PublicKey)
		if !ok {
			return nil, fmt.Errorf("public key %s is %T, not Ed25519", path, parsed)
		}
		spki, err := x509.MarshalPKIXPublicKey(key)
		if err != nil {
			return nil, fmt.Errorf("marshal public key %s: %w", path, err)
		}
		digest := sha256.Sum256(spki)
		keys[hex.EncodeToString(digest[:])] = key
	}
	return keys, nil
}

func readJournal(path string) ([]journalRecord, int64, error) {
	pathInfo, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, 0, nil
	}
	if err != nil {
		return nil, 0, fmt.Errorf("inspect segment journal: %w", err)
	}
	if !pathInfo.Mode().IsRegular() {
		return nil, 0, errors.New("segment journal is not a regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, 0, fmt.Errorf("open segment journal: %w", err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, 0, fmt.Errorf("stat segment journal: %w", err)
	}
	var records []journalRecord
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		var record journalRecord
		if err := decodeStrict(scanner.Bytes(), &record); err != nil {
			return nil, 0, fmt.Errorf("parse segment journal record %d: %w", len(records)+1, err)
		}
		records = append(records, record)
	}
	if err := scanner.Err(); err != nil {
		return nil, 0, fmt.Errorf("scan segment journal: %w", err)
	}
	return records, info.Size(), nil
}

func validateJournalRecord(record journalRecord, sequence uint64) error {
	if record.SchemaVersion != segmentSchema {
		return fmt.Errorf("journal sequence %d has unsupported schema %q", sequence, record.SchemaVersion)
	}
	if record.Sequence != sequence {
		return fmt.Errorf("journal sequence %d found at position %d", record.Sequence, sequence)
	}
	if record.State != "ok" || record.Error != "" {
		return fmt.Errorf("journal sequence %d has unsupported state", sequence)
	}
	if !validDigest(record.Digest) || !validDigest(record.SignerKeyID) {
		return fmt.Errorf("journal sequence %d has invalid digest or signer key ID", sequence)
	}
	if record.ByteLength < 0 || record.CheckpointInclusion == nil {
		return fmt.Errorf("journal sequence %d has invalid size or checkpoint inclusion", sequence)
	}
	if record.CheckpointInclusion.CheckpointIndex != sequence-1 || record.CheckpointInclusion.LeafIndex != 0 {
		return fmt.Errorf("journal sequence %d has invalid checkpoint inclusion", sequence)
	}
	want := filepath.ToSlash(filepath.Join("attestations", fmt.Sprintf("%020d.dsse.json", sequence)))
	if record.Attestation != want {
		return fmt.Errorf("journal sequence %d has invalid attestation path %q", sequence, record.Attestation)
	}
	return nil
}

func verifySegmentRecord(cfg Config, record journalRecord, keys Keyring) error {
	attestationPath, err := confinedPath(cfg.EvidenceDir, record.Attestation)
	if err != nil {
		return err
	}
	if _, err := validateDescendantPath(cfg.EvidenceDir, attestationPath); err != nil {
		return fmt.Errorf("validate attestation path: %w", err)
	}
	segmentPath, err := confinedPath(cfg.SegmentRoot, record.SegmentID)
	if err != nil {
		return err
	}
	if _, err := validateDescendantPath(cfg.SegmentRoot, segmentPath); err != nil {
		return fmt.Errorf("validate segment path: %w", err)
	}
	claim, signer, err := verifySegmentEvidence(attestationPath, segmentPath, keys)
	if err != nil {
		return err
	}
	if signer != record.SignerKeyID {
		return errors.New("signature key ID differs from journal signer")
	}
	want := segmentClaim{record.SchemaVersion, record.Sequence, record.SegmentID, record.Digest, record.ByteLength, record.SignerKeyID, record.State, record.Error}
	if claim != want {
		return errors.New("signed segment predicate differs from journal")
	}
	return nil
}

func verifySegmentEvidence(attestationPath, segmentPath string, keys Keyring) (segmentClaim, string, error) {
	var claim segmentClaim
	statement, signer, err := verifyEnvelope(attestationPath, keys)
	if err != nil {
		return claim, "", err
	}
	if statement.Type != statementType || statement.PredicateType != segmentPredicate {
		return claim, "", errors.New("segment statement has unsupported type")
	}
	if err := decodeStrict(statement.Predicate, &claim); err != nil {
		return claim, "", fmt.Errorf("parse segment predicate: %w", err)
	}
	if claim.SchemaVersion != segmentSchema {
		return claim, "", fmt.Errorf("segment predicate has unsupported schema %q", claim.SchemaVersion)
	}
	if claim.State != "ok" || claim.Error != "" || claim.ByteLength < 0 || !validDigest(claim.Digest) || claim.SignerKeyID != signer {
		return claim, "", errors.New("segment predicate contains invalid integrity fields")
	}
	if len(statement.Subject) != 1 || statement.Subject[0].Name != claim.SegmentID || statement.Subject[0].Digest.SHA256 != claim.Digest {
		return claim, "", errors.New("segment signed subject differs from predicate")
	}
	info, err := os.Lstat(segmentPath)
	if err != nil {
		return claim, "", fmt.Errorf("inspect persisted segment: %w", err)
	}
	if !info.Mode().IsRegular() {
		return claim, "", errors.New("persisted segment is not a regular file")
	}
	file, err := os.Open(segmentPath)
	if err != nil {
		return claim, "", fmt.Errorf("open persisted segment: %w", err)
	}
	hash := sha256.New()
	written, copyErr := io.Copy(hash, file)
	closeErr := file.Close()
	if copyErr != nil {
		return claim, "", fmt.Errorf("hash persisted segment: %w", copyErr)
	}
	if closeErr != nil {
		return claim, "", fmt.Errorf("close persisted segment: %w", closeErr)
	}
	if written != claim.ByteLength {
		return claim, "", fmt.Errorf("segment byte length mismatch: got %d, want %d", written, claim.ByteLength)
	}
	if hex.EncodeToString(hash.Sum(nil)) != claim.Digest {
		return claim, "", errors.New("segment digest mismatch")
	}
	return claim, signer, nil
}

func verifyCheckpoint(path string, record journalRecord, previous string, keys Keyring) (string, error) {
	statement, signer, err := verifyEnvelope(path, keys)
	if err != nil {
		return "", err
	}
	if signer != record.SignerKeyID {
		return "", errors.New("checkpoint signature key ID differs from journal signer")
	}
	if statement.Type != statementType || statement.PredicateType != checkpointPredicate {
		return "", errors.New("checkpoint statement has unsupported type")
	}
	var claim checkpointClaim
	if err := decodeStrict(statement.Predicate, &claim); err != nil {
		return "", fmt.Errorf("parse checkpoint predicate: %w", err)
	}
	if claim.SchemaVersion != checkpointSchema {
		return "", fmt.Errorf("checkpoint predicate has unsupported schema %q", claim.SchemaVersion)
	}
	if err := validateCheckpointClaim(claim, record, previous); err != nil {
		return "", err
	}
	digest := checkpointHash(claim)
	wantSubject := fmt.Sprintf("signalloom-segment-checkpoint/%s/%08d", segmentScope, claim.Index)
	if len(statement.Subject) != 1 || statement.Subject[0].Name != wantSubject || statement.Subject[0].Digest.SHA256 != digest {
		return "", errors.New("checkpoint signed subject digest differs from predicate")
	}
	wantName := fmt.Sprintf("%08d-%s.dsse.json", claim.Index, digest[:12])
	if filepath.Base(path) != wantName {
		return "", errors.New("checkpoint filename differs from signed checkpoint digest")
	}
	return digest, nil
}

func validateCheckpointClaim(claim checkpointClaim, record journalRecord, previous string) error {
	sequence := record.Sequence
	if claim.TenantScope != segmentScope || claim.Index != sequence-1 || claim.PrevCheckpointDigest != previous {
		return errors.New("checkpoint index or previous checkpoint digest is discontinuous")
	}
	end := fmt.Sprintf("%020d", sequence)
	if claim.WindowEndInclusive != end || claim.RowCount != 1 || claim.CumulativeRowCount != sequence || claim.BoundaryBasis != "segment_sequence" {
		return errors.New("checkpoint row count or sequence boundary is discontinuous")
	}
	if sequence == 1 {
		if claim.WindowStartExclusive != nil {
			return errors.New("first checkpoint has unexpected window start")
		}
	} else {
		start := fmt.Sprintf("%020d", sequence-1)
		if claim.WindowStartExclusive == nil || *claim.WindowStartExclusive != start {
			return errors.New("checkpoint window start is discontinuous")
		}
	}
	if claim.MerkleRoot != merkleLeaf(record) {
		return errors.New("checkpoint Merkle root differs from journal record")
	}
	return nil
}

func verifyEnvelope(path string, keys Keyring) (statement, string, error) {
	var result statement
	info, err := os.Lstat(path)
	if err != nil {
		return result, "", fmt.Errorf("inspect DSSE envelope: %w", err)
	}
	if !info.Mode().IsRegular() {
		return result, "", errors.New("DSSE envelope is not a regular file")
	}
	if info.Size() > maxEnvelopeBytes {
		return result, "", fmt.Errorf("DSSE envelope exceeds %d bytes", maxEnvelopeBytes)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return result, "", fmt.Errorf("read DSSE envelope: %w", err)
	}
	var env envelope
	if err := decodeStrict(raw, &env); err != nil {
		return result, "", fmt.Errorf("parse DSSE envelope: %w", err)
	}
	if env.PayloadType != dssePayloadType || env.Payload == "" || len(env.Signatures) == 0 {
		return result, "", errors.New("DSSE envelope has unsupported payload or no signatures")
	}
	payload, err := base64.StdEncoding.Strict().DecodeString(env.Payload)
	if err != nil {
		return result, "", fmt.Errorf("decode DSSE payload: %w", err)
	}
	pae := dssePAE(env.PayloadType, payload)
	for _, candidate := range env.Signatures {
		key, ok := keys[candidate.KeyID]
		if !ok {
			continue
		}
		sig, decodeErr := base64.StdEncoding.Strict().DecodeString(candidate.Sig)
		if decodeErr == nil && ed25519.Verify(key, pae, sig) {
			if err := decodeStrict(payload, &result); err != nil {
				return result, "", fmt.Errorf("parse signed statement: %w", err)
			}
			return result, candidate.KeyID, nil
		}
	}
	for _, candidate := range env.Signatures {
		if _, ok := keys[candidate.KeyID]; !ok {
			return result, "", fmt.Errorf("DSSE signature references untrusted key %q", candidate.KeyID)
		}
	}
	return result, "", errors.New("DSSE signature verification failed")
}

func verifyHighWater(cfg Config, records []journalRecord, journalSize int64, index evidenceIndex) (highWater, error) {
	var high highWater
	raw, err := os.ReadFile(cfg.HighWaterPath)
	if err != nil {
		return high, fmt.Errorf("read protected highwater: %w", err)
	}
	if err := decodeStrict(raw, &high); err != nil {
		return high, fmt.Errorf("parse protected highwater: %w", err)
	}
	if high.SchemaVersion != highWaterSchema {
		return high, fmt.Errorf("protected highwater has unsupported schema %q", high.SchemaVersion)
	}
	if high.MaxSequence != uint64(len(records)) || high.JournalSize != journalSize {
		return high, errors.New("protected highwater sequence or journal size differs from verified corpus")
	}
	if high.AttestationCount != index.attestationCount || high.CheckpointCount != len(index.checkpoints) {
		return high, errors.New("protected highwater evidence counts differ from indexed corpus")
	}
	if len(records) > 0 {
		tip := records[len(records)-1]
		if high.LastSegmentID != tip.SegmentID || high.LastDigest != tip.Digest {
			return high, errors.New("protected highwater tip differs from verified journal")
		}
	}
	if !slices.IsSorted(high.HistoricalSegments) || len(slices.Compact(append([]string(nil), high.HistoricalSegments...))) != len(high.HistoricalSegments) {
		return high, errors.New("protected highwater historical inventory is not sorted and unique")
	}
	wantSegments := append([]string(nil), high.HistoricalSegments...)
	for _, record := range records {
		wantSegments = append(wantSegments, record.SegmentID)
	}
	slices.Sort(wantSegments)
	wantSegments = slices.Compact(wantSegments)
	actualSegments, err := segmentInventory(cfg.SegmentRoot)
	if err != nil {
		return high, err
	}
	if !slices.Equal(actualSegments, wantSegments) {
		return high, errors.New("persisted segment inventory differs from protected history and journal")
	}
	return high, nil
}

func indexEvidence(evidenceDir string) (evidenceIndex, error) {
	index := evidenceIndex{checkpoints: make(map[uint64]string)}
	for _, directory := range []string{"attestations", "checkpoints"} {
		directoryPath := filepath.Join(evidenceDir, directory)
		info, err := validateDescendantPath(evidenceDir, directoryPath)
		if err != nil {
			return index, fmt.Errorf("%s inventory: %w", directory, err)
		}
		if !info.IsDir() {
			return index, fmt.Errorf("%s inventory is not a regular directory", directory)
		}
		entries, err := os.ReadDir(directoryPath)
		if err != nil {
			return index, fmt.Errorf("read %s inventory: %w", directory, err)
		}
		for _, entry := range entries {
			if entry.Type()&os.ModeSymlink != 0 || !entry.Type().IsRegular() {
				return index, fmt.Errorf("%s inventory contains non-regular file %q", directory, entry.Name())
			}
			if directory == "attestations" {
				index.attestationCount++
				continue
			}
			name := entry.Name()
			prefix, _, found := strings.Cut(name, "-")
			if !found || len(prefix) < 8 || !strings.HasSuffix(name, ".dsse.json") {
				return index, fmt.Errorf("checkpoint inventory contains invalid filename %q", name)
			}
			checkpointIndex, err := strconv.ParseUint(prefix, 10, 64)
			if err != nil {
				return index, fmt.Errorf("checkpoint inventory contains invalid index %q", name)
			}
			if _, exists := index.checkpoints[checkpointIndex]; exists {
				return index, fmt.Errorf("checkpoint inventory contains duplicate index %d", checkpointIndex)
			}
			index.checkpoints[checkpointIndex] = filepath.Join(directoryPath, name)
		}
	}
	return index, nil
}

func segmentInventory(root string) ([]string, error) {
	scope := filepath.Join(root, filepath.FromSlash(segmentScope))
	info, err := validateDescendantPath(root, scope)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("validate persisted segment scope: %w", err)
	}
	if !info.IsDir() {
		return nil, errors.New("persisted segment scope is not a regular directory")
	}
	blocks, err := os.ReadDir(scope)
	if err != nil {
		return nil, fmt.Errorf("read persisted segment scope: %w", err)
	}
	var result []string
	for _, block := range blocks {
		if block.Type()&os.ModeSymlink != 0 || !block.IsDir() {
			return nil, fmt.Errorf("persisted segment block %q is not a regular directory", block.Name())
		}
		path := filepath.Join(scope, block.Name(), "data.parquet")
		info, err := os.Lstat(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil || !info.Mode().IsRegular() {
			return nil, fmt.Errorf("inspect persisted segment %q: invalid regular file", block.Name())
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return nil, err
		}
		result = append(result, filepath.ToSlash(relative))
	}
	slices.Sort(result)
	return result, nil
}

func merkleLeaf(record journalRecord) string {
	detail, _ := json.Marshal(map[string]any{
		"schema_version": record.SchemaVersion, "sequence": record.Sequence, "segment_id": record.SegmentID,
		"digest": record.Digest, "byte_length": record.ByteLength, "signer_key_id": record.SignerKeyID,
		"state": record.State, "error": record.Error, "attestation": record.Attestation,
		"checkpoint_inclusion": map[string]any{"checkpoint_index": record.CheckpointInclusion.CheckpointIndex, "leaf_index": record.CheckpointInclusion.LeafIndex},
	})
	end := fmt.Sprintf("%020d", record.Sequence)
	actor, event, tenant, detailString := record.SignerKeyID, "segment.persisted", segmentScope, string(detail)
	row := []*string{stringPointer("signalloom.audit.row/v1"), &record.SegmentID, &tenant, &end, &event, nil, nil, &actor, &detailString}
	var framed []byte
	for _, value := range row {
		framed = append(framed, encodeField(value)...)
	}
	digest := sha256.Sum256(append([]byte{0}, framed...))
	return hex.EncodeToString(digest[:])
}

func checkpointHash(claim checkpointClaim) string {
	values := []*string{
		stringPointer(checkpointSchema), &claim.TenantScope, stringPointer(fmt.Sprint(claim.Index)), &claim.PrevCheckpointDigest,
		claim.WindowStartExclusive, &claim.WindowEndInclusive, stringPointer(fmt.Sprint(claim.RowCount)),
		stringPointer(fmt.Sprint(claim.CumulativeRowCount)), &claim.MerkleRoot, &claim.BoundaryBasis,
	}
	var framed []byte
	for _, value := range values {
		framed = append(framed, encodeField(value)...)
	}
	digest := sha256.Sum256(framed)
	return hex.EncodeToString(digest[:])
}

func dssePAE(payloadType string, payload []byte) []byte {
	return []byte(fmt.Sprintf("DSSEv1 %d %s %d %s", len([]byte(payloadType)), payloadType, len(payload), payload))
}

func encodeField(value *string) []byte {
	if value == nil {
		return []byte{0}
	}
	raw := []byte(*value)
	result := make([]byte, 9+len(raw))
	result[0] = 1
	binary.BigEndian.PutUint64(result[1:9], uint64(len(raw)))
	copy(result[9:], raw)
	return result
}

func decodeStrict(raw []byte, destination any) error {
	typeOfDestination := reflect.TypeOf(destination)
	if typeOfDestination == nil || typeOfDestination.Kind() != reflect.Pointer {
		return errors.New("strict JSON destination must be a pointer")
	}
	if err := validateJSONShape(raw, typeOfDestination.Elem()); err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

func validateJSONShape(raw []byte, expected reflect.Type) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := validateJSONValue(decoder, expected, "$", nil); err != nil {
		return err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

func validateJSONValue(decoder *json.Decoder, expected reflect.Type, path string, first json.Token) error {
	for expected != nil && expected.Kind() == reflect.Pointer {
		expected = expected.Elem()
	}
	if expected == reflect.TypeOf(json.RawMessage{}) {
		expected = nil
	}
	token := first
	var err error
	if token == nil {
		token, err = decoder.Token()
		if err != nil {
			return err
		}
	}
	delimiter, composite := token.(json.Delim)
	if !composite {
		return nil
	}
	switch delimiter {
	case '{':
		fields := exactJSONFields(expected)
		seen := make(map[string]struct{})
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return errors.New("JSON object key is not a string")
			}
			if _, duplicate := seen[key]; duplicate {
				return fmt.Errorf("duplicate JSON key %q at %s", key, path)
			}
			seen[key] = struct{}{}
			fieldType, known := fields[key]
			if expected != nil && !known {
				return fmt.Errorf("json: unknown field %q", key)
			}
			if err := validateJSONValue(decoder, fieldType, path+"."+key, nil); err != nil {
				return err
			}
		}
		_, err = decoder.Token()
		return err
	case '[':
		var elementType reflect.Type
		if expected != nil && (expected.Kind() == reflect.Slice || expected.Kind() == reflect.Array) {
			elementType = expected.Elem()
		}
		for index := 0; decoder.More(); index++ {
			if err := validateJSONValue(decoder, elementType, fmt.Sprintf("%s[%d]", path, index), nil); err != nil {
				return err
			}
		}
		_, err = decoder.Token()
		return err
	default:
		return fmt.Errorf("unexpected JSON delimiter %q", delimiter)
	}
}

func exactJSONFields(expected reflect.Type) map[string]reflect.Type {
	fields := make(map[string]reflect.Type)
	if expected == nil || expected.Kind() != reflect.Struct {
		return fields
	}
	for index := 0; index < expected.NumField(); index++ {
		field := expected.Field(index)
		name := strings.Split(field.Tag.Get("json"), ",")[0]
		if name != "" && name != "-" {
			fields[name] = field.Type
		}
	}
	return fields
}

func confinedPath(root, relative string) (string, error) {
	if relative == "" || filepath.IsAbs(relative) || filepath.ToSlash(filepath.Clean(relative)) != relative || relative == "." || strings.HasPrefix(relative, "../") {
		return "", fmt.Errorf("unsafe relative path %q", relative)
	}
	path := filepath.Join(root, filepath.FromSlash(relative))
	resolved, err := filepath.Rel(root, path)
	if err != nil || resolved == ".." || strings.HasPrefix(resolved, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("path %q escapes configured root", relative)
	}
	return path, nil
}

// validateDescendantPath assumes an immutable offline snapshot. It deliberately
// rejects symlinks in every existing component below the caller-trusted root,
// but does not attempt concurrent-filesystem race resistance via openat handles.
func validateDescendantPath(root, target string) (os.FileInfo, error) {
	relative, err := filepath.Rel(root, target)
	if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return nil, fmt.Errorf("path %q is not a descendant of configured root", target)
	}
	current := root
	components := strings.Split(relative, string(filepath.Separator))
	var info os.FileInfo
	for index, component := range components {
		current = filepath.Join(current, component)
		info, err = os.Lstat(current)
		if err != nil {
			return nil, err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("path component %q is a symlink", current)
		}
		if index < len(components)-1 && !info.IsDir() {
			return nil, fmt.Errorf("intermediate path component %q is not a directory", current)
		}
	}
	return info, nil
}

func validDigest(value string) bool {
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size && value == strings.ToLower(value)
}

func stringPointer(value string) *string { return &value }
