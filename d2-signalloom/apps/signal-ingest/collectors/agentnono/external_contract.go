package agentnono

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"time"
)

const (
	ExternalContractVersion = "1.0.0"
	HostAssertionFormat     = "signalloom-host-assertions-v1"
	IntegrityAuthority      = "agentnono-go-v1"
	maxWireSequence         = uint64(9007199254740991)
)

var (
	idPattern        = regexp.MustCompile(`^[a-z][a-z0-9-]{2,63}$`)
	sessionPattern   = regexp.MustCompile(`^[A-Za-z0-9-]{3,128}$`)
	uploadPattern    = regexp.MustCompile(`^[A-Za-z0-9-]{16,128}$`)
	keyPattern       = regexp.MustCompile(`^[A-Za-z0-9._:-]{3,128}$`)
	hex64Pattern     = regexp.MustCompile(`^[0-9a-f]{64}$`)
	integerPattern   = regexp.MustCompile(`^-?(0|[1-9][0-9]*)$`)
	uint64Pattern    = regexp.MustCompile(`^(0|[1-9][0-9]{0,19})$`)
	timestampPattern = regexp.MustCompile(`^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,9})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$`)
)

type ExternalEvidence struct {
	SchemaVersion    string          `json:"schema_version"`
	SessionID        string          `json:"session_id"`
	Sequence         uint64          `json:"sequence"`
	ObservedAt       string          `json:"observed_at"`
	Source           string          `json:"source"`
	EvidenceType     string          `json:"evidence_type"`
	ObservationState string          `json:"observation_state"`
	IntegrityState   string          `json:"integrity_state"`
	AgentID          string          `json:"agent_id"`
	HostID           string          `json:"host_id"`
	Attributes       json.RawMessage `json:"attributes"`
}

type HostAssertionEnvelope struct {
	Format        string             `json:"format"`
	Algorithm     string             `json:"algorithm"`
	PayloadSHA256 string             `json:"payload_sha256"`
	KeyID         string             `json:"key_id"`
	Signature     string             `json:"signature"`
	Assertions    []ExternalEvidence `json:"assertions"`
}

// OriginalChainReference is an untrusted host reference, never a verification result.
type OriginalChainReference struct {
	SessionID   string `json:"session_id"`
	EventCount  uint64 `json:"event_count"`
	FinalDigest string `json:"final_digest"`
}

type ExternalUpload struct {
	SchemaVersion          string                 `json:"schema_version"`
	UploadID               string                 `json:"upload_id"`
	ReplayKey              string                 `json:"replay_key"`
	SessionID              string                 `json:"session_id"`
	SequenceStart          uint64                 `json:"sequence_start"`
	SequenceEnd            uint64                 `json:"sequence_end"`
	AssertionEnvelope      HostAssertionEnvelope  `json:"assertion_envelope"`
	OriginalChainReference OriginalChainReference `json:"original_chain_reference"`
}

type TrustedHostBinding struct {
	AgentID   string
	HostID    string
	KeyID     string
	PublicKey ed25519.PublicKey
}

type ServerIntegrityResult struct {
	Authority   string  `json:"authority"`
	SessionID   string  `json:"session_id"`
	EventCount  uint64  `json:"event_count"`
	FinalDigest *string `json:"final_digest"`
	State       string  `json:"state"`
	EvaluatedAt string  `json:"evaluated_at"`
	Reason      string  `json:"reason"`
}

type UploadAcknowledgement struct {
	SchemaVersion      string `json:"schema_version"`
	UploadID           string `json:"upload_id"`
	ReplayResult       string `json:"replay_result"`
	HostSignatureState string `json:"host_signature_state"`
	OriginalChainState string `json:"original_chain_state"`
}

// LocalChainInput is trusted collector-local state. It is never populated from an upload body.
type LocalChainInput struct {
	ExpectedSessionID string
	Finalized         bool
	Events            []*NonoAuditEvent
}

func decodeStrict(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("trailing JSON value")
	}
	return nil
}

func inspectJSON(data []byte) (any, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	value, err := readJSONValue(decoder)
	if err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("trailing JSON value")
	}
	return value, nil
}

func readJSONValue(decoder *json.Decoder) (any, error) {
	token, err := decoder.Token()
	if err != nil {
		return nil, err
	}
	switch value := token.(type) {
	case json.Delim:
		if value == '{' {
			return readJSONObject(decoder)
		}
		if value == '[' {
			return readJSONArray(decoder)
		}
	case string:
		if !asciiOnly(value) {
			return nil, errors.New("contract strings must be ASCII")
		}
		return value, nil
	case json.Number:
		lexical := value.String()
		if !integerPattern.MatchString(lexical) || lexical == "-0" {
			return nil, fmt.Errorf("non-canonical integer %q", lexical)
		}
		parsed, err := strconv.ParseInt(lexical, 10, 64)
		if err != nil || parsed < -int64(maxWireSequence) || parsed > int64(maxWireSequence) {
			return nil, fmt.Errorf("integer outside JavaScript safe range %q", lexical)
		}
		return value, nil
	default:
		return value, nil
	}
	return nil, errors.New("invalid JSON delimiter")
}

func readJSONObject(decoder *json.Decoder) (map[string]any, error) {
	object := make(map[string]any)
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		key, ok := keyToken.(string)
		if !ok || !asciiOnly(key) {
			return nil, errors.New("JSON object keys must be ASCII strings")
		}
		if _, duplicate := object[key]; duplicate {
			return nil, fmt.Errorf("duplicate JSON key %q", key)
		}
		item, err := readJSONValue(decoder)
		if err != nil {
			return nil, err
		}
		object[key] = item
	}
	if _, err := decoder.Token(); err != nil {
		return nil, err
	}
	return object, nil
}

func readJSONArray(decoder *json.Decoder) ([]any, error) {
	var array []any
	for decoder.More() {
		item, err := readJSONValue(decoder)
		if err != nil {
			return nil, err
		}
		array = append(array, item)
	}
	if _, err := decoder.Token(); err != nil {
		return nil, err
	}
	return array, nil
}

func asciiOnly(value string) bool {
	for index := 0; index < len(value); index++ {
		if value[index] > 0x7f {
			return false
		}
	}
	return true
}

func requireKeys(value any, keys ...string) (map[string]any, error) {
	object, ok := value.(map[string]any)
	if !ok {
		return nil, errors.New("required JSON object missing")
	}
	if len(object) != len(keys) {
		return nil, errors.New("JSON object key set does not match contract")
	}
	for _, key := range keys {
		if _, present := object[key]; !present {
			return nil, fmt.Errorf("required JSON key %q missing", key)
		}
	}
	return object, nil
}

func requireInteger(object map[string]any, key string) error {
	if _, ok := object[key].(json.Number); !ok {
		return fmt.Errorf("required JSON key %q must be an integer", key)
	}
	return nil
}

func requireUploadKeys(value any) error {
	upload, err := requireKeys(value, "schema_version", "upload_id", "replay_key", "session_id", "sequence_start", "sequence_end", "assertion_envelope", "original_chain_reference")
	if err != nil {
		return err
	}
	for _, key := range []string{"sequence_start", "sequence_end"} {
		if err := requireInteger(upload, key); err != nil {
			return err
		}
	}
	return requireEnvelopeKeys(upload)
}

func requireEnvelopeKeys(upload map[string]any) error {
	envelope, err := requireKeys(upload["assertion_envelope"], "format", "algorithm", "payload_sha256", "key_id", "signature", "assertions")
	if err != nil {
		return err
	}
	reference, err := requireKeys(upload["original_chain_reference"], "session_id", "event_count", "final_digest")
	if err != nil {
		return err
	}
	if err := requireInteger(reference, "event_count"); err != nil {
		return err
	}
	assertions, ok := envelope["assertions"].([]any)
	if !ok {
		return errors.New("assertions must be an array")
	}
	for _, item := range assertions {
		if err := requireEvidenceKeys(item); err != nil {
			return err
		}
	}
	return nil
}

func requireEvidenceKeys(value any) error {
	evidence, err := requireKeys(value, "schema_version", "session_id", "sequence", "observed_at", "source", "evidence_type", "observation_state", "integrity_state", "agent_id", "host_id", "attributes")
	if err != nil {
		return err
	}
	if err := requireInteger(evidence, "sequence"); err != nil {
		return err
	}
	typeName, ok := evidence["evidence_type"].(string)
	if !ok {
		return errors.New("evidence_type must be a string")
	}
	attributeKeys := map[string][]string{
		"process":          {"health_state", "cpu_time_ms", "resident_memory_bytes", "exit_code", "restart_count"},
		"artifact":         {"artifact_id", "root_id", "sha256", "size_bytes", "mtime_ns"},
		"network":          {"destination_id", "decision"},
		"collection-limit": {"reason_code", "max_file_size_bytes", "max_files_per_window", "max_bytes_per_window", "window_seconds"},
	}
	keys, known := attributeKeys[typeName]
	if !known {
		return errors.New("invalid evidence type")
	}
	attributes, err := requireKeys(evidence["attributes"], keys...)
	if err != nil {
		return err
	}
	return requireAttributeIntegers(typeName, attributes)
}

func requireAttributeIntegers(typeName string, attributes map[string]any) error {
	numericKeys := map[string][]string{
		"process":          {"cpu_time_ms", "resident_memory_bytes", "restart_count"},
		"artifact":         {"size_bytes"},
		"collection-limit": {"max_file_size_bytes", "max_files_per_window", "max_bytes_per_window", "window_seconds"},
	}
	for _, key := range numericKeys[typeName] {
		if err := requireInteger(attributes, key); err != nil {
			return err
		}
	}
	if typeName == "process" && attributes["exit_code"] != nil {
		return requireInteger(attributes, "exit_code")
	}
	return nil
}

func DecodeExternalUpload(data []byte) (*ExternalUpload, error) {
	value, err := inspectJSON(data)
	if err != nil {
		return nil, fmt.Errorf("inspect external upload: %w", err)
	}
	if err := requireUploadKeys(value); err != nil {
		return nil, fmt.Errorf("inspect external upload: %w", err)
	}
	var upload ExternalUpload
	if err := decodeStrict(data, &upload); err != nil {
		return nil, fmt.Errorf("decode external upload: %w", err)
	}
	if err := upload.Validate(); err != nil {
		return nil, err
	}
	return &upload, nil
}

func (upload ExternalUpload) Validate() error {
	if err := upload.validateMetadata(); err != nil {
		return err
	}
	for index, evidence := range upload.AssertionEnvelope.Assertions {
		if err := validateEvidence(evidence, upload.SessionID, upload.SequenceStart+uint64(index)); err != nil {
			return err
		}
	}
	return nil
}

func (upload ExternalUpload) validateMetadata() error {
	if upload.SchemaVersion != ExternalContractVersion || !uploadPattern.MatchString(upload.UploadID) || !hex64Pattern.MatchString(upload.ReplayKey) {
		return errors.New("invalid upload version or identity")
	}
	if !sessionPattern.MatchString(upload.SessionID) || upload.SequenceStart > maxWireSequence || upload.SequenceEnd > maxWireSequence || upload.SequenceEnd < upload.SequenceStart {
		return errors.New("invalid session or sequence range")
	}
	count := upload.SequenceEnd - upload.SequenceStart + 1
	if count > 500 || uint64(len(upload.AssertionEnvelope.Assertions)) != count {
		return errors.New("assertions must exactly cover the bounded sequence range")
	}
	envelope := upload.AssertionEnvelope
	if envelope.Format != HostAssertionFormat || envelope.Algorithm != "Ed25519" || !hex64Pattern.MatchString(envelope.PayloadSHA256) || !keyPattern.MatchString(envelope.KeyID) {
		return errors.New("invalid assertion envelope metadata")
	}
	signature, err := base64.RawURLEncoding.DecodeString(envelope.Signature)
	if err != nil || len(signature) != ed25519.SignatureSize || base64.RawURLEncoding.EncodeToString(signature) != envelope.Signature {
		return errors.New("signature must be unpadded base64url Ed25519")
	}
	reference := upload.OriginalChainReference
	if reference.SessionID != upload.SessionID || reference.EventCount < 1 || reference.EventCount > 100000 || !hex64Pattern.MatchString(reference.FinalDigest) {
		return errors.New("invalid untrusted original-chain reference")
	}
	return nil
}

func validateEvidence(evidence ExternalEvidence, sessionID string, sequence uint64) error {
	if evidence.SchemaVersion != ExternalContractVersion || evidence.SessionID != sessionID || evidence.Sequence != sequence {
		return errors.New("evidence sequence or session mismatch")
	}
	if !idPattern.MatchString(evidence.AgentID) || !idPattern.MatchString(evidence.HostID) || !validTimestamp(evidence.ObservedAt) {
		return errors.New("invalid evidence identity or timestamp")
	}
	if !oneOf(evidence.Source, "nono-0.73.0", "host-sensor-v1") || !oneOf(evidence.ObservationState, "observed", "denied", "unobserved") || evidence.IntegrityState != "not-integrity-verified" {
		return errors.New("invalid evidence state")
	}
	return validateEvidenceAttributes(evidence)
}

func validTimestamp(value string) bool {
	if !timestampPattern.MatchString(value) {
		return false
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	return err == nil && parsed.Location() != nil
}

func oneOf(value string, allowed ...string) bool {
	for _, candidate := range allowed {
		if value == candidate {
			return true
		}
	}
	return false
}

func validateEvidenceAttributes(evidence ExternalEvidence) error {
	switch evidence.EvidenceType {
	case "process":
		var value struct {
			HealthState         string `json:"health_state"`
			CPUTimeMS           uint64 `json:"cpu_time_ms"`
			ResidentMemoryBytes uint64 `json:"resident_memory_bytes"`
			ExitCode            *int32 `json:"exit_code"`
			RestartCount        uint64 `json:"restart_count"`
		}
		if err := decodeStrict(evidence.Attributes, &value); err != nil || !oneOf(value.HealthState, "starting", "running", "stopped", "failed", "unknown") {
			return errors.New("invalid process attributes")
		}
	case "artifact":
		var value struct {
			ArtifactID string `json:"artifact_id"`
			RootID     string `json:"root_id"`
			SHA256     string `json:"sha256"`
			SizeBytes  uint64 `json:"size_bytes"`
			MtimeNS    string `json:"mtime_ns"`
		}
		if err := decodeStrict(evidence.Attributes, &value); err != nil {
			return errors.New("invalid artifact attributes")
		}
		_, mtimeErr := strconv.ParseUint(value.MtimeNS, 10, 64)
		if !regexp.MustCompile(`^hmac-sha256:[0-9a-f]{64}$`).MatchString(value.ArtifactID) || !oneOf(value.RootID, "agent-work", "agent-output") || !hex64Pattern.MatchString(value.SHA256) || value.SizeBytes > 16777216 || !uint64Pattern.MatchString(value.MtimeNS) || mtimeErr != nil {
			return errors.New("invalid artifact attributes")
		}
	case "network":
		var value struct {
			DestinationID string `json:"destination_id"`
			Decision      string `json:"decision"`
		}
		if err := decodeStrict(evidence.Attributes, &value); err != nil || !oneOf(value.DestinationID, "signal-loom-ingest", "agentmaxxing-api") || !oneOf(value.Decision, "allowed", "denied") {
			return errors.New("invalid network attributes")
		}
	case "collection-limit":
		var value struct {
			ReasonCode        string `json:"reason_code"`
			MaxFileSizeBytes  uint64 `json:"max_file_size_bytes"`
			MaxFilesPerWindow uint64 `json:"max_files_per_window"`
			MaxBytesPerWindow uint64 `json:"max_bytes_per_window"`
			WindowSeconds     uint64 `json:"window_seconds"`
		}
		if err := decodeStrict(evidence.Attributes, &value); err != nil || evidence.ObservationState != "unobserved" || !oneOf(value.ReasonCode, "oversize", "files-rate-exhausted", "bytes-rate-exhausted") || value.MaxFileSizeBytes != 16777216 || value.MaxFilesPerWindow != 120 || value.MaxBytesPerWindow != 67108864 || value.WindowSeconds != 60 {
			return errors.New("invalid collection-limit attributes")
		}
	default:
		return errors.New("invalid evidence type")
	}
	return nil
}

// CanonicalSigningBytes returns the frozen sorted-key ASCII JSON subset.
func CanonicalSigningBytes(upload ExternalUpload) ([]byte, error) {
	document := map[string]any{
		"assertions":               upload.AssertionEnvelope.Assertions,
		"domain":                   "signalloom.external-agent-upload.v1",
		"original_chain_reference": upload.OriginalChainReference,
		"schema_version":           upload.SchemaVersion,
		"sequence_end":             upload.SequenceEnd,
		"sequence_start":           upload.SequenceStart,
		"session_id":               upload.SessionID,
		"upload_id":                upload.UploadID,
	}
	encoded, err := json.Marshal(document)
	if err != nil {
		return nil, err
	}
	var normalized any
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	if err := decoder.Decode(&normalized); err != nil {
		return nil, err
	}
	return json.Marshal(normalized)
}

// VerifyHostUpload is the pure Go contract oracle for structure, binding, digest, replay and Ed25519 signature.
func VerifyHostUpload(data []byte, binding TrustedHostBinding) (*ExternalUpload, error) {
	upload, err := DecodeExternalUpload(data)
	if err != nil {
		return nil, err
	}
	if !idPattern.MatchString(binding.AgentID) || !idPattern.MatchString(binding.HostID) || binding.KeyID != upload.AssertionEnvelope.KeyID || len(binding.PublicKey) != ed25519.PublicKeySize {
		return nil, errors.New("upload does not match trusted registration binding")
	}
	for _, evidence := range upload.AssertionEnvelope.Assertions {
		if evidence.AgentID != binding.AgentID || evidence.HostID != binding.HostID {
			return nil, errors.New("assertion identity does not match trusted binding")
		}
	}
	canonical, err := CanonicalSigningBytes(*upload)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(canonical)
	digestHex := hex.EncodeToString(digest[:])
	if upload.ReplayKey != digestHex || upload.AssertionEnvelope.PayloadSHA256 != digestHex {
		return nil, errors.New("canonical payload digest or replay key mismatch")
	}
	signature, _ := base64.RawURLEncoding.DecodeString(upload.AssertionEnvelope.Signature)
	if !ed25519.Verify(binding.PublicKey, canonical, signature) {
		return nil, errors.New("Ed25519 host assertion signature mismatch")
	}
	return upload, nil
}

func VerifyHostUploadAcknowledgement(data []byte, binding TrustedHostBinding, replayResult string) (*ExternalUpload, UploadAcknowledgement, error) {
	if !oneOf(replayResult, "accepted", "idempotent-replay") {
		return nil, UploadAcknowledgement{}, errors.New("invalid replay result")
	}
	upload, err := VerifyHostUpload(data, binding)
	if err != nil {
		return nil, UploadAcknowledgement{}, err
	}
	acknowledgement := UploadAcknowledgement{
		SchemaVersion:      ExternalContractVersion,
		UploadID:           upload.UploadID,
		ReplayResult:       replayResult,
		HostSignatureState: "host-signature-verified",
		OriginalChainState: "original-chain-not-verified",
	}
	return upload, acknowledgement, nil
}

// VerifyOriginalChain evaluates trusted raw events held inside agentnono. Upload data cannot populate input.
func VerifyOriginalChain(verifier *AuditVerifier, input LocalChainInput, now time.Time) (ServerIntegrityResult, error) {
	result := ServerIntegrityResult{Authority: IntegrityAuthority, SessionID: input.ExpectedSessionID, State: "unavailable", EvaluatedAt: now.UTC().Format(time.RFC3339Nano)}
	unavailableReason, err := validateLocalChainInput(verifier, input)
	if err != nil {
		return ServerIntegrityResult{}, err
	}
	if unavailableReason != "" {
		result.Reason = unavailableReason
		return result, nil
	}
	firstSequence := input.Events[0].Seq
	for index, event := range input.Events {
		if event == nil || event.AuditSessionID != input.ExpectedSessionID || event.Seq != firstSequence+int64(index) {
			if result.FinalDigest == nil {
				result.Reason = "event-unverified"
				return result, nil
			}
			result.State = "tampered"
			result.Reason = "chain-continuity-failed"
			return result, nil
		}
		if index > 0 && (result.FinalDigest == nil || event.PrevDigest != *result.FinalDigest) {
			result.State = "tampered"
			result.Reason = "chain-continuity-failed"
			return result, nil
		}
		verification := verifier.VerifyEvent(event)
		result.EventCount++
		result.FinalDigest = &verification.CalculatedDigest
		if verification.Status == StatusTampered {
			result.State = "tampered"
			result.Reason = "event-tampered"
			return result, nil
		}
		if verification.Status != StatusVerified {
			result.EventCount = 0
			result.FinalDigest = nil
			result.State = "unavailable"
			result.Reason = "event-unverified"
			return result, nil
		}
	}
	result.State = "integrity-verified"
	result.Reason = "verified"
	return result, nil
}

func validateLocalChainInput(verifier *AuditVerifier, input LocalChainInput) (string, error) {
	if !sessionPattern.MatchString(input.ExpectedSessionID) {
		return "", errors.New("invalid expected session identifier")
	}
	if verifier == nil {
		return "verifier-unavailable", nil
	}
	if len(input.Events) == 0 {
		return "empty-chain", nil
	}
	if len(input.Events) > 100000 {
		return "event-cap-exceeded", nil
	}
	if !input.Finalized {
		return "not-finalized", nil
	}
	if input.Events[0] == nil {
		return "event-unverified", nil
	}
	return "", nil
}
