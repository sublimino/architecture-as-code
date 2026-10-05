// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package synth generates a deterministic synthetic AWS telemetry stream:
// CloudTrail and VPC Flow objects in the real wire shapes, with controlled
// attack bursts injected into otherwise benign traffic.
//
// # Why this exists alongside the fixtures
//
// The Kusari fixtures are small and hand-written, which is what makes them
// readable and what makes a per-rule expectation table possible. They cannot
// answer two questions the pilot will be asked:
//
//  1. Does a rule stay quiet in VOLUME? A rule that fires on one record in a
//     seven-record fixture may fire on a thousand in a thousand-record hour, and
//     a false-positive rate is not visible at fixture scale. The baseline
//     profile exists for exactly this: benign traffic that must produce ZERO
//     findings, at whatever volume you ask for.
//  2. Does a stage-2 window fire on a burst it was not hand-built around?
//     Injecting a burst into generated noise tests the window against arrival
//     interleaving the fixture author did not choose.
//
// # Determinism is the whole contract
//
// Generate is a pure function of its arguments. The same seed yields
// byte-identical CloudTrail and VPC Flow objects, asserted by
// TestGenerate_SameSeedIsByteIdentical. That matters for more than tidiness:
// awslogs derives Observation.ID from the evidence reference, so a generator
// that shifted its records would change every observation ID and make a replay
// comparison meaningless. Nothing here reads the clock, the environment, or a
// map iteration order.
//
// Output is written as objects, not as observations, so the stream goes through
// the SAME production Projector the collector uses. A generator that emitted
// model.Observation directly would bypass the §2.3 projection and could not
// catch a projection defect, which is half of what it is for.
package synth

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// Profile selects which attack bursts are injected into the benign baseline.
type Profile string

const (
	// ProfileBaseline is benign traffic only. It must produce ZERO findings
	// against either shipped bundle, which makes it the false-positive gate.
	ProfileBaseline Profile = "baseline"
	// ProfileIAMBurst injects three IAM credential/policy changes by one actor
	// inside ten minutes: the iam-change-burst-10m threshold.
	ProfileIAMBurst Profile = "iam-burst"
	// ProfileRejectBurst injects twenty REJECT flows from one source address
	// inside five minutes: the vpc-reject-burst-5m threshold.
	ProfileRejectBurst Profile = "reject-burst"
	// ProfileCrossAccount injects two AssumeRole calls by one foreign principal
	// inside thirty minutes: the cross-account-assume-role-burst-30m threshold.
	ProfileCrossAccount Profile = "cross-account"
	// ProfileAll injects every burst above, into one stream.
	ProfileAll Profile = "all"
)

// Profiles returns every profile, in a fixed order.
func Profiles() []Profile {
	return []Profile{ProfileBaseline, ProfileIAMBurst, ProfileRejectBurst, ProfileCrossAccount, ProfileAll}
}

// BaseTime is the first instant of every generated stream.
//
// It is a fixed date, deliberately a day after the Kusari fixtures, so a stream
// and the fixture corpus can be ingested together without their stage-2 windows
// interacting. It is NOT time.Now(): a generated corpus whose timestamps moved
// between runs could not be compared with itself, and the determinism contract
// forbids a wall-clock reading anywhere in this path.
var BaseTime = time.Date(2026, 10, 4, 0, 0, 0, 0, time.UTC)

// The account and region every generated record belongs to. The account is in
// the shipped bundles' vars.tenant_accounts, which the cross-account rule needs.
const (
	Account = "123456789012"
	Region  = "us-east-1"

	// ForeignAccount is the account the cross-account burst assumes FROM. It is
	// not in vars.tenant_accounts and not in
	// vars.cross_account_assume_role_actors.
	ForeignAccount = "777766665555"
)

// Burst records one injected attack, so a test can assert what should have been
// detected without re-deriving it from the profile.
type Burst struct {
	// Kind is the profile fragment that injected it.
	Kind string
	// Rule is the stage-1 rule id the burst's records must fire.
	Rule string
	// Window is the stage-2 window id the burst must cross, if any.
	Window string
	// Actor and SourceIP are the key dimensions the window counts on.
	Actor, SourceIP string
	// Records is how many records were injected.
	Records int
}

// Stream is one generated corpus.
type Stream struct {
	Seed            int64
	Profile         Profile
	Minutes         int
	EventsPerMinute int

	// CloudTrail is one CloudTrail Records[] envelope; VPCFlow is one VPC Flow
	// Logs version 2 text object. Both are in the wire shape the collector reads
	// from S3, so they go through the production Projector.
	CloudTrail []byte
	VPCFlow    []byte

	// Bursts is what was injected. Empty for ProfileBaseline.
	Bursts []Burst
}

// CloudTrailKey and VPCFlowKey are the object keys a Stream's bytes are
// projected under. The suffixes are what route the Projector (.log is flow
// text), and the "synth/" prefix keeps generated evidence refs visibly distinct
// from fixture ones.
func (s *Stream) CloudTrailKey() string { return fmt.Sprintf("synth/%s-%d.json", s.Profile, s.Seed) }

// VPCFlowKey is the flow object's key.
func (s *Stream) VPCFlowKey() string { return fmt.Sprintf("synth/%s-%d.log", s.Profile, s.Seed) }

// Observations projects the stream through the production awslogs Projector.
func (s *Stream) Observations(tenantID, region string) ([]model.Observation, error) {
	p := awslogs.Projector{TenantID: tenantID, Region: region}

	ct, err := p.Project(s.CloudTrail, awslogs.Origin{Key: s.CloudTrailKey()})
	if err != nil {
		return nil, fmt.Errorf("synth: projecting the generated CloudTrail object: %w", err)
	}
	flow, err := p.Project(s.VPCFlow, awslogs.Origin{Key: s.VPCFlowKey()})
	if err != nil {
		return nil, fmt.Errorf("synth: projecting the generated VPC Flow object: %w", err)
	}
	return append(ct, flow...), nil
}

// Generate builds a stream.
//
// minutes is the span, eventsPerMinute the benign rate. Both must be positive:
// a zero-length stream is almost certainly a caller bug, and returning an empty
// corpus silently is how a volume test comes to assert nothing.
func Generate(seed int64, minutes, eventsPerMinute int, profile Profile) (*Stream, error) {
	if minutes <= 0 {
		return nil, fmt.Errorf("synth: minutes must be positive, got %d", minutes)
	}
	if eventsPerMinute <= 0 {
		return nil, fmt.Errorf("synth: eventsPerMinute must be positive, got %d", eventsPerMinute)
	}
	switch profile {
	case ProfileBaseline, ProfileIAMBurst, ProfileRejectBurst, ProfileCrossAccount, ProfileAll:
	default:
		return nil, fmt.Errorf("synth: unknown profile %q, want one of %v", profile, Profiles())
	}

	// One source, used in a fixed sequence. Determinism is a property of the
	// ORDER of draws, so nothing below may iterate a map or branch on anything
	// outside this function's arguments.
	rng := rand.New(rand.NewSource(seed)) //nolint:gosec // deterministic corpus generation, not cryptography

	s := &Stream{Seed: seed, Profile: profile, Minutes: minutes, EventsPerMinute: eventsPerMinute}

	records := benignCloudTrail(rng, minutes, eventsPerMinute)
	flows := benignFlows(rng, minutes, eventsPerMinute)

	if profile == ProfileIAMBurst || profile == ProfileAll {
		rs, b := iamBurst(minutes)
		records = append(records, rs...)
		s.Bursts = append(s.Bursts, b)
	}
	if profile == ProfileCrossAccount || profile == ProfileAll {
		rs, b := crossAccountBurst(minutes)
		records = append(records, rs...)
		s.Bursts = append(s.Bursts, b)
	}
	if profile == ProfileRejectBurst || profile == ProfileAll {
		fs, b := rejectBurst(minutes)
		flows = append(flows, fs...)
		s.Bursts = append(s.Bursts, b)
	}

	// Canonical order. Sorting is not cosmetic: the record index within an
	// object is the evidence reference, and the evidence reference is the
	// observation ID, so an unstable order would change every ID.
	sortRecords(records)
	sortFlows(flows)

	ct, err := json.MarshalIndent(cloudTrailFile{Records: records}, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("synth: encoding the generated CloudTrail object: %w", err)
	}
	s.CloudTrail = append(ct, '\n')
	s.VPCFlow = renderFlows(flows)
	return s, nil
}

// ---------------------------------------------------------------------------
// CloudTrail
// ---------------------------------------------------------------------------

type cloudTrailFile struct {
	Records []cloudTrailRecord `json:"Records"`
}

type cloudTrailRecord struct {
	EventVersion       string          `json:"eventVersion"`
	EventTime          string          `json:"eventTime"`
	EventSource        string          `json:"eventSource"`
	EventName          string          `json:"eventName"`
	AWSRegion          string          `json:"awsRegion"`
	RecipientAccountID string          `json:"recipientAccountId"`
	SourceIPAddress    string          `json:"sourceIPAddress"`
	UserIdentity       identity        `json:"userIdentity"`
	Resources          []resourceEntry `json:"resources,omitempty"`
}

type identity struct {
	Type      string `json:"type"`
	ARN       string `json:"arn"`
	AccountID string `json:"accountId"`
}

type resourceEntry struct {
	Type string `json:"type"`
	ARN  string `json:"ARN"`
}

// benignEvent is one entry in the harmless event pool: an API that neither
// shipped bundle lists. If a rule ever widens to cover one of these, the
// baseline profile's zero-findings assertion goes red, which is the point.
type benignEvent struct {
	Source, Name, ResourceType, ResourceARN string
}

var benignEvents = []benignEvent{
	{"iam.amazonaws.com", "ListUsers", "", ""},
	{"iam.amazonaws.com", "GetUser", "AWS::IAM::User", "arn:aws:iam::" + Account + ":user/synth-reader"},
	{"iam.amazonaws.com", "ListAttachedUserPolicies", "AWS::IAM::User", "arn:aws:iam::" + Account + ":user/synth-reader"},
	{"s3.amazonaws.com", "GetBucketPolicy", "AWS::S3::Bucket", "arn:aws:s3:::synth-artifacts"},
	{"s3.amazonaws.com", "ListBuckets", "", ""},
	{"s3.amazonaws.com", "GetBucketVersioning", "AWS::S3::Bucket", "arn:aws:s3:::synth-artifacts"},
	{"eks.amazonaws.com", "DescribeCluster", "AWS::EKS::Cluster", "arn:aws:eks:" + Region + ":" + Account + ":cluster/synth"},
	{"eks.amazonaws.com", "ListClusters", "", ""},
	{"eks.amazonaws.com", "ListNodegroups", "AWS::EKS::Cluster", "arn:aws:eks:" + Region + ":" + Account + ":cluster/synth"},
	{"sts.amazonaws.com", "GetCallerIdentity", "", ""},
	{"guardduty.amazonaws.com", "GetDetector", "AWS::GuardDuty::Detector", "arn:aws:guardduty:" + Region + ":" + Account + ":detector/d-synth"},
	{"guardduty.amazonaws.com", "ListFindings", "AWS::GuardDuty::Detector", "arn:aws:guardduty:" + Region + ":" + Account + ":detector/d-synth"},
}

// benignActors are the identities that generate the baseline. They are distinct
// from every fixture actor and from every burst actor, so a window keyed on
// actor cannot merge generated noise into a fixture's or a burst's counter.
var benignActors = []string{
	"arn:aws:iam::" + Account + ":user/synth-reader",
	"arn:aws:iam::" + Account + ":role/synth-ci",
	"arn:aws:sts::" + Account + ":assumed-role/synth-ci/job-1",
	"arn:aws:iam::" + Account + ":user/synth-operator",
}

var benignSourceIPs = []string{"198.51.100.10", "198.51.100.11", "203.0.113.30", "10.0.5.4"}

// benignCloudTrail draws roughly 60% of the requested rate as control-plane
// events; the rest become flows.
func benignCloudTrail(rng *rand.Rand, minutes, perMinute int) []cloudTrailRecord {
	n := minutes * perMinute * 6 / 10
	out := make([]cloudTrailRecord, 0, n)
	for i := 0; i < n; i++ {
		e := benignEvents[rng.Intn(len(benignEvents))]
		actor := benignActors[rng.Intn(len(benignActors))]
		ip := benignSourceIPs[rng.Intn(len(benignSourceIPs))]
		at := BaseTime.Add(time.Duration(rng.Intn(minutes*60)) * time.Second)

		rec := cloudTrailRecord{
			EventVersion:       "1.09",
			EventTime:          at.UTC().Format(time.RFC3339),
			EventSource:        e.Source,
			EventName:          e.Name,
			AWSRegion:          Region,
			RecipientAccountID: Account,
			SourceIPAddress:    ip,
			UserIdentity:       identityFor(actor),
		}
		if e.ResourceType != "" {
			rec.Resources = []resourceEntry{{Type: e.ResourceType, ARN: e.ResourceARN}}
		}
		out = append(out, rec)
	}
	return out
}

func identityFor(arn string) identity {
	t := "IAMUser"
	switch {
	case strings.Contains(arn, ":role/"):
		t = "IAMRole"
	case strings.Contains(arn, ":assumed-role/"):
		t = "AssumedRole"
	case strings.HasSuffix(arn, ":root"):
		t = "Root"
	}
	account := Account
	if parts := strings.Split(arn, ":"); len(parts) > 4 && parts[4] != "" {
		account = parts[4]
	}
	return identity{Type: t, ARN: arn, AccountID: account}
}

// iamBurst is three credential/policy changes by one actor inside ten minutes.
// Anchored at the mid-point of the stream so it is surrounded by noise on both
// sides rather than sitting at an edge where an arrival-order defect could hide.
func iamBurst(minutes int) ([]cloudTrailRecord, Burst) {
	const actor = "arn:aws:iam::" + Account + ":user/synth-escalator"
	const ip = "203.0.113.99"
	start := BaseTime.Add(time.Duration(minutes/2) * time.Minute)

	names := []string{"CreateAccessKey", "AttachUserPolicy", "PutUserPolicy"}
	out := make([]cloudTrailRecord, 0, len(names))
	for i, name := range names {
		out = append(out, cloudTrailRecord{
			EventVersion:       "1.09",
			EventTime:          start.Add(time.Duration(i*2) * time.Minute).UTC().Format(time.RFC3339),
			EventSource:        "iam.amazonaws.com",
			EventName:          name,
			AWSRegion:          Region,
			RecipientAccountID: Account,
			SourceIPAddress:    ip,
			UserIdentity:       identityFor(actor),
			Resources:          []resourceEntry{{Type: "AWS::IAM::User", ARN: actor}},
		})
	}
	return out, Burst{
		Kind:     string(ProfileIAMBurst),
		Rule:     "iam-credential-or-policy-change",
		Window:   "iam-change-burst-10m",
		Actor:    actor,
		SourceIP: ip,
		Records:  len(names),
	}
}

// crossAccountBurst is two AssumeRole calls by one foreign principal inside
// thirty minutes.
func crossAccountBurst(minutes int) ([]cloudTrailRecord, Burst) {
	const actor = "arn:aws:iam::" + ForeignAccount + ":user/synth-partner"
	const ip = "203.0.113.201"
	start := BaseTime.Add(time.Duration(minutes/3) * time.Minute)

	out := make([]cloudTrailRecord, 0, 2)
	for i := 0; i < 2; i++ {
		out = append(out, cloudTrailRecord{
			EventVersion:       "1.09",
			EventTime:          start.Add(time.Duration(i*10) * time.Minute).UTC().Format(time.RFC3339),
			EventSource:        "sts.amazonaws.com",
			EventName:          "AssumeRole",
			AWSRegion:          Region,
			RecipientAccountID: Account,
			SourceIPAddress:    ip,
			UserIdentity:       identityFor(actor),
			Resources:          []resourceEntry{{Type: "AWS::IAM::Role", ARN: "arn:aws:iam::" + Account + ":role/synth-target"}},
		})
	}
	return out, Burst{
		Kind:     string(ProfileCrossAccount),
		Rule:     "cross-account-assume-role",
		Window:   "cross-account-assume-role-burst-30m",
		Actor:    actor,
		SourceIP: ip,
		Records:  2,
	}
}

// sortRecords puts CloudTrail records in canonical order. The tie-breakers are
// exhaustive enough to be a total order on the generated space, because a
// comparator with ties would let sort.Slice's instability reorder equal records
// and change their evidence refs.
func sortRecords(rs []cloudTrailRecord) {
	sort.SliceStable(rs, func(i, j int) bool {
		a, b := rs[i], rs[j]
		switch {
		case a.EventTime != b.EventTime:
			return a.EventTime < b.EventTime
		case a.EventSource != b.EventSource:
			return a.EventSource < b.EventSource
		case a.EventName != b.EventName:
			return a.EventName < b.EventName
		case a.UserIdentity.ARN != b.UserIdentity.ARN:
			return a.UserIdentity.ARN < b.UserIdentity.ARN
		default:
			return a.SourceIPAddress < b.SourceIPAddress
		}
	})
}

// ---------------------------------------------------------------------------
// VPC Flow
// ---------------------------------------------------------------------------

// flow is one VPC Flow Logs version 2 record.
type flow struct {
	InterfaceID      string
	SrcAddr, DstAddr string
	SrcPort, DstPort int
	Protocol         int
	Packets, Bytes   int
	Start, End       int64
	Action           string
}

var benignFlowSources = []string{"10.0.5.4", "10.0.5.5", "10.0.6.7"}
var benignFlowDests = []struct {
	Addr     string
	Port     int
	Protocol int
}{
	{"198.51.100.7", 443, 6},
	{"8.8.8.8", 53, 17},
	{"198.51.100.9", 80, 6},
}

// benignFlows are the remaining ~40% of the rate, all ACCEPT. An ACCEPT cannot
// fire vpc-egress-rejected, so these are noise by construction rather than by
// luck of the draw.
func benignFlows(rng *rand.Rand, minutes, perMinute int) []flow {
	n := minutes*perMinute - minutes*perMinute*6/10
	out := make([]flow, 0, n)
	for i := 0; i < n; i++ {
		src := benignFlowSources[rng.Intn(len(benignFlowSources))]
		dst := benignFlowDests[rng.Intn(len(benignFlowDests))]
		start := BaseTime.Add(time.Duration(rng.Intn(minutes*60)) * time.Second).Unix()
		out = append(out, flow{
			InterfaceID: "eni-0synth00000000001",
			SrcAddr:     src,
			DstAddr:     dst.Addr,
			SrcPort:     32768 + rng.Intn(28000),
			DstPort:     dst.Port,
			Protocol:    dst.Protocol,
			Packets:     1 + rng.Intn(40),
			Bytes:       64 + rng.Intn(20000),
			Start:       start,
			End:         start + 30,
			Action:      "ACCEPT",
		})
	}
	return out
}

// rejectBurst is twenty REJECTs from one source address inside five minutes:
// the vpc-reject-burst-5m threshold, reached exactly.
//
// Twelve-second spacing puts all twenty inside 228 seconds, comfortably inside
// the five-minute window, so the decision fires on the twentieth arrival rather
// than depending on where the window boundary happens to fall.
func rejectBurst(minutes int) ([]flow, Burst) {
	const src = "10.0.9.200"
	const count = 20
	start := BaseTime.Add(time.Duration(minutes/2) * time.Minute).Unix()

	out := make([]flow, 0, count)
	for i := 0; i < count; i++ {
		at := start + int64(i*12)
		out = append(out, flow{
			InterfaceID: "eni-0synth00000000002",
			SrcAddr:     src,
			DstAddr:     "198.51.100.21",
			SrcPort:     50000 + i,
			DstPort:     3000 + i,
			Protocol:    6,
			Packets:     1,
			Bytes:       40,
			Start:       at,
			End:         at + 10,
			Action:      "REJECT",
		})
	}
	return out, Burst{
		Kind:     string(ProfileRejectBurst),
		Rule:     "vpc-egress-rejected",
		Window:   "vpc-reject-burst-5m",
		SourceIP: src,
		Records:  count,
	}
}

func sortFlows(fs []flow) {
	sort.SliceStable(fs, func(i, j int) bool {
		a, b := fs[i], fs[j]
		switch {
		case a.Start != b.Start:
			return a.Start < b.Start
		case a.SrcAddr != b.SrcAddr:
			return a.SrcAddr < b.SrcAddr
		case a.DstAddr != b.DstAddr:
			return a.DstAddr < b.DstAddr
		case a.SrcPort != b.SrcPort:
			return a.SrcPort < b.SrcPort
		case a.DstPort != b.DstPort:
			return a.DstPort < b.DstPort
		default:
			return a.Action < b.Action
		}
	})
}

// renderFlows writes the version 2 default format, header first. Field order is
// the one the header names and the one awslogs.ProjectVPCFlow indexes.
func renderFlows(fs []flow) []byte {
	var b strings.Builder
	b.WriteString("version account-id interface-id srcaddr dstaddr srcport dstport protocol packets bytes start end action log-status\n")
	for _, f := range fs {
		fmt.Fprintf(&b, "2 %s %s %s %s %d %d %d %d %d %d %d %s OK\n",
			Account, f.InterfaceID, f.SrcAddr, f.DstAddr,
			f.SrcPort, f.DstPort, f.Protocol, f.Packets, f.Bytes,
			f.Start, f.End, f.Action)
	}
	return []byte(b.String())
}
