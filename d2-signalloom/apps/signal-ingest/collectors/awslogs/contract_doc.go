// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package awslogs projects AWS CloudTrail, IAM, VPC Flow and GuardDuty telemetry onto
// model.Observation under a documented label contract, buffers it durably, and
// acknowledges the source queue only once the sink has accepted every record.
//
// # Label contract (SLAWS v2 §2.3, D4 — binding for every policy rule)
//
// This file is the single documentation of the contract and contract_test.go
// asserts every key below against every fixture in testdata/. Keys are ADDITIVE
// ONLY: a rule written against this contract must keep compiling, so a key is
// never renamed or removed, only added.
//
//	Key               CloudTrail                    IAM                      VPC Flow                       GuardDuty (EventBridge)
//	----------------- ----------------------------- ------------------------ ------------------------------ ------------------------------
//	tenant_id         collector config              collector config         collector config               collector config
//	provider          "aws"                         "aws"                    "aws"                          "aws"
//	aws_account_id    recipientAccountId            recipientAccountId       account-id (field 2)           detail.accountId, else account
//	actor_account_id  twelve-digit account or absent, same                     —                              —
//	                  userIdentity.arn field 4
//	aws_region        awsRegion (per record)        awsRegion                collector config               detail.region, else region,
//	                                                                                                        else collector config
//	event_source      eventSource                   "iam.amazonaws.com"      "vpcflow"                      envelope source ("aws.guardduty")
//	event_name        eventName                     eventName                action: ACCEPT | REJECT        detail.type (the finding type)
//	error_code        errorCode, only when present  same                     —                              —
//	severity          —                             —                        —                              detail.severity, integer floor
//	resource_type     resources[0].type             resources[0].type or     "AWS::EC2::NetworkInterface"   detail.resource.resourceType
//	                                                the name allowlist below
//	resource_name     resources[0].ARN              resources[0].ARN or      interface-id (field 3)         first networkInterfaceId, only
//	                                                the name allowlist below                                when it is an eni- id
//	source_ip         sourceIPAddress               sourceIPAddress          srcaddr (field 4)              —
//	dst_ip            —                             —                        dstaddr (field 5)              —
//	dst_port          —                             —                        dstport (field 7)              —
//	protocol          —                             —                        protocol (field 8, IANA number) —
//	bytes             —                             —                        bytes (field 10)               —
//
// Non-label fields:
//
//   - Layer is model.LayerCloudControlPlane for CloudTrail, IAM and GuardDuty, and
//     model.LayerNetworkEgress for VPC Flow.
//   - Source is one of aws:cloudtrail, aws:iam, aws:vpcflow, aws:guardduty. IAM is selected when
//     eventSource is exactly iam.amazonaws.com; everything else on the CloudTrail
//     path is aws:cloudtrail. aws:collector is reserved for the collector's own
//     operational observations (buffer eviction), which carry type and count.
//   - ActorHint is userIdentity.arn verbatim, pseudonymised later by the store. VPC
//     Flow records name no principal, so ActorHint is empty there and the §2.3 actor
//     row reads "—"; a flow record is attributed by dst_ip and resource_name. A
//     GuardDuty finding names at most a userName, never an ARN, so ActorHint is
//     empty there too; an ARN is never fabricated from a userName.
//   - Timestamp is eventTime for CloudTrail/IAM, the flow `start` field for VPC
//     Flow, and the EventBridge envelope `time` for GuardDuty. It is NEVER time.Now(): replay over an S3 backlog has to reproduce live
//     output, and a wall-clock stamp would make that impossible (pkg/obscel
//     determinism contract).
//   - ID is sha256 hex of RawEvidenceRef, so the same record projected twice — live
//     and again on replay — is the same observation and deduplicates naturally. It is
//     never a random UUID.
//   - RawEvidenceRef is s3://<bucket>/<key>#<record-index> in live mode and
//     testdata/<file>#<record-index> in fixture mode. The index is the ordinal of the
//     record within the object (CloudTrail Records[] position; for VPC Flow the
//     ordinal among data lines, header and blank lines excluded), NOT a physical line
//     number. The customer bucket stays the system of record for the raw event.
//   - Description is one line under MaxDescriptionLen runes, built only from the
//     projected label values. For GuardDuty it is "guardduty <type> on
//     <resourceType>" and nothing else: no title, no resource identifier.
//
// # Envelope dispatch
//
// A JSON object is routed by shape, never by key name: detail-type "GuardDuty
// Finding" goes to ProjectGuardDuty, a Records array goes to ProjectCloudTrail, and
// anything else is ErrUnrecognisedEnvelope, which the collector stores as a
// projection_failure. Before this, an EventBridge envelope decoded as a CloudTrail
// file with no records and projected to a silent zero.
//
// GuardDuty severity is a float on the wire (7.5, 8.9). The label is its integer
// floor, so int(obs.labels.severity) never fails in CEL and the GuardDuty bands
// survive: low < 4, medium 4..6, high >= 7. The rest of detail -- title,
// description, accessKeyDetails, instanceDetails, service -- is never decoded.
//
// # The requestParameters name allowlist
//
// When an IAM record carries no resources[] entry the resource is taken from
// requestParameters, but only from ResourceNameKeys, in that fixed order, and only
// the scalar value of the matched key. Nothing else in requestParameters is read and
// the container is never serialised. This is the one place the projection touches
// requestParameters at all, and the allowlist is what keeps the negative contract
// below true by construction rather than by scrubbing.
//
// # Negative contract (asserted by TestNegativeContract_*)
//
// No key and no value, in any column of any observation, may carry:
//
//   - a session token or an access key ID or a secret access key,
//   - the requestParameters or responseElements container, serialised or named,
//   - any raw JSON body.
//
// testdata/poisoned.json exists solely to prove it: its requestParameters and
// responseElements carry a session token, two access key IDs, a secret and an
// external ID, every one prefixed POISON so the test can derive its assertions from
// the fixture bytes. None of them may reach Store.Append in any column. Projection
// is an allowlist of named scalars, so a new AWS field cannot leak by default — the
// failure mode is a missing label, which a test catches, not a leaked secret, which
// one might not.
package awslogs

// Label keys. These strings are the contract; policy rules are written against them.
const (
	LabelTenantID     = "tenant_id"
	LabelProvider     = "provider"
	LabelAWSAccountID = "aws_account_id"

	// LabelActorAccountID is the account of the ACTING principal, parsed from
	// userIdentity.arn. It is the counterpart of LabelAWSAccountID, which is the
	// account that RECEIVED the call, and the pair is what makes "did this cross
	// an account boundary" answerable.
	//
	// It exists because the answer must survive the segment. The cross-account
	// rule used to recover this account inside CEL with
	// obs.actor.startsWith("arn:aws:iam::" + aws_account_id + ":"), which read
	// the actor as STRUCTURE. obs.actor is now a keyed pseudonym on both the live
	// and the replay path (the SLAWS replay-parity contract), so that structure is
	// gone: both startsWith calls evaluate false, both negations evaluate true,
	// and a same-account role chain reads as cross-account. Parsing the account
	// here puts it in a label, labels round-trip through a v2 segment, and the
	// rule compares two labels instead of dissecting an identity.
	//
	// An account number is not personal data, which is the same reasoning that
	// already projects recipientAccountId in cleartext.
	//
	// OPTIONAL, and absent rather than empty when no account is named: an AWS
	// service principal carries no userIdentity.arn, and an empty value would
	// satisfy has() and then compare unequal to every recipient account, turning
	// the rule into a detector for the absence of an actor.
	LabelActorAccountID = "actor_account_id"

	LabelAWSRegion    = "aws_region"
	LabelEventSource  = "event_source"
	LabelEventName    = "event_name"
	LabelErrorCode    = "error_code"
	LabelResourceType = "resource_type"
	LabelResourceName = "resource_name"
	LabelSourceIP     = "source_ip"
	LabelDstIP        = "dst_ip"
	LabelDstPort      = "dst_port"
	LabelProtocol     = "protocol"
	LabelBytes        = "bytes"

	// LabelSeverity is the integer floor of a GuardDuty finding's detail.severity.
	// It is already admitted by store/label_allowlist.go, so FrostDB accepts it.
	LabelSeverity = "severity"

	// LabelType and LabelCount appear only on the collector's own operational
	// observations (Source aws:collector), never on a projected AWS record.
	LabelType  = "type"
	LabelCount = "count"
)

// Observation sources emitted by this collector.
const (
	SourceCloudTrail = "aws:cloudtrail"
	SourceIAM        = "aws:iam"
	SourceVPCFlow    = "aws:vpcflow"
	SourceCollector  = "aws:collector"
	SourceGuardDuty  = "aws:guardduty"
)

// DetailTypeGuardDutyFinding is the EventBridge detail-type that selects
// ProjectGuardDuty.
const DetailTypeGuardDutyFinding = "GuardDuty Finding"

// ProviderAWS is the fixed value of the provider label.
const ProviderAWS = "aws"

// EventSourceIAM is the CloudTrail eventSource that selects SourceIAM.
const EventSourceIAM = "iam.amazonaws.com"

// EventSourceVPCFlow is the synthetic event_source for flow log records, which carry
// no eventSource field of their own.
const EventSourceVPCFlow = "vpcflow"

// MaxDescriptionLen bounds Description in runes. §2.3 requires a one-line summary;
// 200 is the documented ceiling and the projection stays strictly under it.
const MaxDescriptionLen = 200

// TypeBufferEviction is the value of the type label on an eviction observation.
const TypeBufferEviction = "buffer_eviction"

// TypeProjectionFailure is the type label on the durable record a collector writes when a
// buffered object cannot be projected; the object stays in the customer bucket (§2.1).
const TypeProjectionFailure = "projection_failure"

// ResourceTypeENI is the resource_type of every VPC Flow record.
const ResourceTypeENI = "AWS::EC2::NetworkInterface"

// ResourceNameKeys is the ordered allowlist of requestParameters keys the projection
// may read when an IAM record carries no resources[] entry, mapped to the resource
// type each implies. Order is significant and fixed: an AttachUserPolicy record
// carries both userName and policyArn, and the subject of the call is the user.
var ResourceNameKeys = []struct {
	Key  string
	Type string
}{
	{"roleName", "AWS::IAM::Role"},
	{"userName", "AWS::IAM::User"},
	{"groupName", "AWS::IAM::Group"},
	{"policyName", "AWS::IAM::Policy"},
	{"policyArn", "AWS::IAM::Policy"},
}

// ForbiddenSubstrings are the tokens the negative contract bans from every key and
// value of every observation this package emits.
var ForbiddenSubstrings = []string{
	"sessionToken",
	"accessKeyId",
	"secretAccessKey",
	"requestParameters",
	"responseElements",
}

var (
	controlPlaneRequiredKeys = []string{
		LabelTenantID,
		LabelProvider,
		LabelAWSAccountID,
		LabelAWSRegion,
		LabelEventSource,
		LabelEventName,
		LabelSourceIP,
	}
	controlPlaneOptionalKeys = []string{
		LabelErrorCode,
		LabelResourceType,
		LabelResourceName,
		// Optional because an AWS service principal names no account. See the
		// constant for why absent beats empty.
		LabelActorAccountID,
	}
	vpcFlowRequiredKeys = []string{
		LabelTenantID,
		LabelProvider,
		LabelAWSAccountID,
		LabelAWSRegion,
		LabelEventSource,
		LabelEventName,
		LabelResourceType,
		LabelResourceName,
		LabelSourceIP,
		LabelDstIP,
		LabelDstPort,
		LabelProtocol,
		LabelBytes,
	}
	guardDutyRequiredKeys = []string{
		LabelTenantID,
		LabelProvider,
		LabelAWSAccountID,
		LabelAWSRegion,
		LabelEventSource,
		LabelEventName,
		LabelSeverity,
		LabelResourceType,
	}
	guardDutyOptionalKeys = []string{
		// Only an ARN-free eni- id; see the GuardDuty column above.
		LabelResourceName,
	}
	collectorRequiredKeys = []string{LabelTenantID, LabelProvider, LabelType, LabelCount}
)

// ContractKeysFor returns the required label keys and the full documented key set for
// an observation source. An unknown source returns two nil slices, which
// contract_test.go treats as a failure: a new source must be documented here before
// it can be emitted.
func ContractKeysFor(source string) (required, documented []string) {
	switch source {
	case SourceCloudTrail, SourceIAM:
		return controlPlaneRequiredKeys, append(append([]string{}, controlPlaneRequiredKeys...), controlPlaneOptionalKeys...)
	case SourceVPCFlow:
		return vpcFlowRequiredKeys, append([]string{}, vpcFlowRequiredKeys...)
	case SourceGuardDuty:
		return guardDutyRequiredKeys, append(append([]string{}, guardDutyRequiredKeys...), guardDutyOptionalKeys...)
	case SourceCollector:
		return collectorRequiredKeys, append([]string{}, collectorRequiredKeys...)
	default:
		return nil, nil
	}
}
