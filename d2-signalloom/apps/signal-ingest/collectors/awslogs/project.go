// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// Origin names the object a batch of records came from. A zero Bucket means the
// batch came from an embedded fixture, in which case Key is the testdata path.
type Origin struct {
	Bucket string
	Key    string
}

// Ref returns the RawEvidenceRef for the record at index within this origin.
func (o Origin) Ref(index int) string {
	if o.Bucket == "" {
		return fmt.Sprintf("%s#%d", o.Key, index)
	}
	return fmt.Sprintf("s3://%s/%s#%d", o.Bucket, o.Key, index)
}

// Projector turns raw AWS telemetry into observations under the §2.3 label contract.
//
// TenantID comes from collector configuration, never from the record: one collector
// instance serves exactly one customer account (SLAWS D7), so a record cannot assert
// a tenant it does not belong to. Region is the fallback for VPC Flow, whose lines
// carry no region of their own.
type Projector struct {
	TenantID string
	Region   string
}

// cloudTrailFile is the envelope CloudTrail writes to S3.
type cloudTrailFile struct {
	Records []cloudTrailRecord `json:"Records"`
}

// cloudTrailRecord is the allowlist of fields the projection reads. Every other
// field in the record, requestParameters and responseElements included, is
// deliberately absent from this struct: what is not decoded cannot leak.
// requestParameters is the single exception and is read as raw JSON so the
// ResourceNameKeys allowlist can pull one scalar out of it without the container
// ever becoming a value.
type cloudTrailRecord struct {
	EventTime          string `json:"eventTime"`
	EventSource        string `json:"eventSource"`
	EventName          string `json:"eventName"`
	AWSRegion          string `json:"awsRegion"`
	RecipientAccountID string `json:"recipientAccountId"`
	SourceIPAddress    string `json:"sourceIPAddress"`
	ErrorCode          string `json:"errorCode"`
	UserIdentity       struct {
		ARN string `json:"arn"`
	} `json:"userIdentity"`
	Resources []struct {
		Type string `json:"type"`
		ARN  string `json:"ARN"`
	} `json:"resources"`
	RequestParameters json.RawMessage `json:"requestParameters"`
}

// Project dispatches on the origin key: a .log or .txt object is VPC Flow text, and
// anything else is a CloudTrail/IAM JSON envelope. A .gz suffix is stripped first so
// a real S3 key routes the same as a decompressed fixture.
func (p Projector) Project(body []byte, origin Origin) ([]model.Observation, error) {
	key := strings.TrimSuffix(origin.Key, ".gz")
	switch {
	case strings.HasSuffix(key, ".log"), strings.HasSuffix(key, ".txt"):
		return p.ProjectVPCFlow(body, origin)
	default:
		return p.ProjectCloudTrail(body, origin)
	}
}

// ProjectCloudTrail projects a CloudTrail Records[] envelope. IAM records are
// recognised by eventSource and sourced as aws:iam; the rest are aws:cloudtrail.
func (p Projector) ProjectCloudTrail(body []byte, origin Origin) ([]model.Observation, error) {
	var file cloudTrailFile
	if err := json.Unmarshal(body, &file); err != nil {
		return nil, fmt.Errorf("awslogs: decoding CloudTrail envelope %s: %w", origin.Key, err)
	}

	out := make([]model.Observation, 0, len(file.Records))
	for i, rec := range file.Records {
		obs, err := p.projectCloudTrailRecord(rec, origin, i)
		if err != nil {
			return nil, err
		}
		out = append(out, obs)
	}
	return out, nil
}

func (p Projector) projectCloudTrailRecord(rec cloudTrailRecord, origin Origin, index int) (model.Observation, error) {
	ts, err := time.Parse(time.RFC3339, rec.EventTime)
	if err != nil {
		return model.Observation{}, fmt.Errorf("awslogs: %s record %d: parsing eventTime %q: %w", origin.Key, index, rec.EventTime, err)
	}

	source := SourceCloudTrail
	if rec.EventSource == EventSourceIAM {
		source = SourceIAM
	}

	region := rec.AWSRegion
	if region == "" {
		region = p.Region
	}

	labels := map[string]string{
		LabelTenantID:     p.TenantID,
		LabelProvider:     ProviderAWS,
		LabelAWSAccountID: rec.RecipientAccountID,
		LabelAWSRegion:    region,
		LabelEventSource:  rec.EventSource,
		LabelEventName:    rec.EventName,
		LabelSourceIP:     rec.SourceIPAddress,
	}
	if rec.ErrorCode != "" {
		labels[LabelErrorCode] = rec.ErrorCode
	}
	// The ACTING principal's account, so the cross-account question is a
	// comparison of two labels rather than a dissection of obs.actor -- which is a
	// keyed pseudonym by the time a rule sees it, and carries no ARN structure on
	// either the live or the replay path. Omitted, never empty, when no account is
	// named: see LabelActorAccountID.
	if actorAccount := actorAccountOf(rec.UserIdentity.ARN); actorAccount != "" {
		labels[LabelActorAccountID] = actorAccount
	}

	resourceType, resourceName := resourceOf(rec)
	if resourceType != "" {
		labels[LabelResourceType] = resourceType
	}
	if resourceName != "" {
		labels[LabelResourceName] = resourceName
	}

	ref := origin.Ref(index)
	return model.Observation{
		ID:             derivedObservationID(ref),
		Timestamp:      ts.UTC(),
		Layer:          model.LayerCloudControlPlane,
		Fidelity:       model.FidelityStrong,
		Source:         source,
		Confidence:     0.9,
		ActorHint:      rec.UserIdentity.ARN,
		RawEvidenceRef: ref,
		Labels:         labels,
		Description:    controlPlaneDescription(labels, rec.UserIdentity.ARN),
	}, nil
}

// arnAccountField is the 0-based index of the account component of an ARN:
// arn:<partition>:<service>:<region>:<account-id>:<resource>.
const arnAccountField = 4

// actorAccountOf returns the AWS account named by an ARN, or "" when it names
// none.
//
// It is a field index and nothing more -- no partition allowlist, no service
// switch -- because the account's POSITION is the stable part of the ARN grammar
// across partitions (aws, aws-cn, aws-us-gov) and across the two shapes an
// assuming principal takes (arn:aws:iam::<acct>:... and
// arn:aws:sts::<acct>:assumed-role/...). Matching on a prefix is what the CEL
// rule used to do and it needed two cases to cover one question.
//
// Three inputs yield "" and all three mean "no account is named": an empty ARN
// (an AWS service principal), a string that is not an ARN at all, and a genuine
// ARN whose account field is empty by design (arn:aws:s3:::bucket). They are not
// distinguished because no caller has a different answer for them, and because
// the alternative -- falling back to the recipient account -- would make every
// one of them read as same-account, which is the silent-false direction.
func actorAccountOf(arn string) string {
	fields := strings.Split(arn, ":")
	// A well-formed ARN has SIX components, so the resource component must be
	// present for the account component to be trustworthy. Accepting five would
	// read the last field of a truncated string as an account.
	if len(fields) < arnAccountField+2 || fields[0] != "arn" {
		return ""
	}
	return fields[arnAccountField]
}

// resourceOf returns the resource type and name for a record: the first resources[]
// entry when there is one, otherwise — for IAM only — the first match in the
// ResourceNameKeys allowlist. Nothing else in requestParameters is read.
func resourceOf(rec cloudTrailRecord) (resourceType, resourceName string) {
	for _, r := range rec.Resources {
		if r.Type != "" || r.ARN != "" {
			return r.Type, r.ARN
		}
	}
	if rec.EventSource != EventSourceIAM || len(rec.RequestParameters) == 0 {
		return "", ""
	}

	// Decode to scalar strings only. A nested object or array decodes to the zero
	// value of string and is skipped, so a container can never become a label value
	// even if AWS one day reuses an allowlisted key name for a structure.
	var params map[string]json.RawMessage
	if err := json.Unmarshal(rec.RequestParameters, &params); err != nil {
		return "", ""
	}
	for _, candidate := range ResourceNameKeys {
		raw, ok := params[candidate.Key]
		if !ok {
			continue
		}
		var value string
		if err := json.Unmarshal(raw, &value); err != nil || value == "" {
			continue
		}
		return candidate.Type, value
	}
	return "", ""
}

// vpcFlowFieldCount is the number of fields in the VPC Flow Logs version 2 default
// format: version account-id interface-id srcaddr dstaddr srcport dstport protocol
// packets bytes start end action log-status.
const vpcFlowFieldCount = 14

// ProjectVPCFlow projects VPC Flow Logs version 2 text. The header line, blank lines
// and the "-" no-data placeholder lines AWS emits for idle interfaces are skipped;
// the record index counts only projected records.
func (p Projector) ProjectVPCFlow(body []byte, origin Origin) ([]model.Observation, error) {
	var out []model.Observation
	index := 0

	for lineNo, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "version ") || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != vpcFlowFieldCount {
			return nil, fmt.Errorf("awslogs: %s line %d: got %d VPC Flow fields, want %d (version 2 default format)", origin.Key, lineNo+1, len(fields), vpcFlowFieldCount)
		}
		obs, err := p.projectFlowFields(fields, origin, index, lineNo+1)
		if err != nil {
			return nil, err
		}
		out = append(out, obs)
		index++
	}
	return out, nil
}

func (p Projector) projectFlowFields(f []string, origin Origin, index, lineNo int) (model.Observation, error) {
	const (
		fAccountID   = 1
		fInterfaceID = 2
		fSrcAddr     = 3
		fDstAddr     = 4
		fDstPort     = 6
		fProtocol    = 7
		fBytes       = 9
		fStart       = 10
		fAction      = 12
	)

	startUnix, err := strconv.ParseInt(f[fStart], 10, 64)
	if err != nil {
		return model.Observation{}, fmt.Errorf("awslogs: %s line %d: parsing flow start %q: %w", origin.Key, lineNo, f[fStart], err)
	}

	action := f[fAction]
	if action != "ACCEPT" && action != "REJECT" {
		return model.Observation{}, fmt.Errorf("awslogs: %s line %d: flow action %q is neither ACCEPT nor REJECT", origin.Key, lineNo, action)
	}

	labels := map[string]string{
		LabelTenantID:     p.TenantID,
		LabelProvider:     ProviderAWS,
		LabelAWSAccountID: f[fAccountID],
		LabelAWSRegion:    p.Region,
		LabelEventSource:  EventSourceVPCFlow,
		LabelEventName:    action,
		LabelResourceType: ResourceTypeENI,
		LabelResourceName: f[fInterfaceID],
		LabelSourceIP:     f[fSrcAddr],
		LabelDstIP:        f[fDstAddr],
		LabelDstPort:      f[fDstPort],
		LabelProtocol:     f[fProtocol],
		LabelBytes:        f[fBytes],
	}

	ref := origin.Ref(index)
	return model.Observation{
		ID:        derivedObservationID(ref),
		Timestamp: time.Unix(startUnix, 0).UTC(),
		Layer:     model.LayerNetworkEgress,
		Fidelity:  model.FidelitySuggestive,
		Source:    SourceVPCFlow,
		// Flow logs are aggregated per capture window and name no principal, so a
		// single record is weaker evidence than a signed control-plane event.
		Confidence:     0.6,
		RawEvidenceRef: ref,
		Labels:         labels,
		Description:    flowDescription(labels),
	}, nil
}

// derivedObservationID is sha256 hex of the evidence ref. Two projections of the
// same record — live and again on replay — therefore produce the same ID, which is
// what makes replay deduplicable and comparable (pkg/obscel determinism contract).
func derivedObservationID(ref string) string {
	sum := sha256.Sum256([]byte(ref))
	return hex.EncodeToString(sum[:])
}

func controlPlaneDescription(labels map[string]string, actor string) string {
	var b strings.Builder
	b.WriteString("aws ")
	b.WriteString(labels[LabelEventSource])
	b.WriteString(" ")
	b.WriteString(labels[LabelEventName])
	if rt := labels[LabelResourceType]; rt != "" {
		b.WriteString(" on ")
		b.WriteString(rt)
	}
	// Neither the actor nor the resource name nor the source IP is written here. ActorHint
	// is pseudonymised by the store (segment schema v2) and a resource name is often an
	// ARN that names a principal (AttachUserPolicy on a user); repeating either in the
	// plaintext description would defeat that (Cato rounds 2 and 3, ISC-23). The values
	// remain available as labels, which is the §2.3 projection.
	_ = actor
	if code := labels[LabelErrorCode]; code != "" {
		b.WriteString(" denied ")
		b.WriteString(code)
	}
	return oneLine(b.String())
}

func flowDescription(labels map[string]string) string {
	return oneLine(fmt.Sprintf("aws vpcflow %s %s %s to %s:%s proto %s %s bytes",
		labels[LabelEventName],
		labels[LabelResourceName],
		labels[LabelSourceIP],
		labels[LabelDstIP],
		labels[LabelDstPort],
		labels[LabelProtocol],
		labels[LabelBytes],
	))
}

// oneLine collapses any newline and truncates on a rune boundary to strictly under
// MaxDescriptionLen runes, so a long ARN cannot turn a one-line summary into a blob
// or split a multi-byte character.
func oneLine(s string) string {
	s = strings.Join(strings.Fields(strings.ReplaceAll(strings.ReplaceAll(s, "\r", " "), "\n", " ")), " ")
	runes := []rune(s)
	if len(runes) < MaxDescriptionLen {
		return s
	}
	const ellipsis = "..."
	keep := MaxDescriptionLen - 1 - len([]rune(ellipsis))
	return string(runes[:keep]) + ellipsis
}
