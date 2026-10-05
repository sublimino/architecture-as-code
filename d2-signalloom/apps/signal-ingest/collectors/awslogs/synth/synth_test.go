// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package synth

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

// The determinism contract. awslogs derives Observation.ID from the evidence
// reference, which is the record's ordinal within its object, so a generator
// that shifted its records by one would change every observation ID in the
// stream — and a replay comparison over a generated corpus would then be
// comparing two different corpora while looking like a policy difference.
func TestGenerate_SameSeedIsByteIdentical(t *testing.T) {
	for _, p := range Profiles() {
		t.Run(string(p), func(t *testing.T) {
			a, err := Generate(42, 60, 20, p)
			if err != nil {
				t.Fatalf("Generate: %v", err)
			}
			b, err := Generate(42, 60, 20, p)
			if err != nil {
				t.Fatalf("Generate: %v", err)
			}
			if !bytes.Equal(a.CloudTrail, b.CloudTrail) {
				t.Errorf("two runs at seed 42 produced different CloudTrail bytes (%d vs %d)",
					len(a.CloudTrail), len(b.CloudTrail))
			}
			if !bytes.Equal(a.VPCFlow, b.VPCFlow) {
				t.Errorf("two runs at seed 42 produced different VPC Flow bytes (%d vs %d)",
					len(a.VPCFlow), len(b.VPCFlow))
			}
			if len(a.CloudTrail) == 0 || len(a.VPCFlow) == 0 {
				t.Fatal("one of the objects is empty; byte equality would be trivially true")
			}
		})
	}
}

// ... and the seed actually does something. Without this the equality above
// would pass on a generator that ignored its seed entirely, which is the one
// way to be deterministic and useless at the same time.
func TestGenerate_DifferentSeedsDiffer(t *testing.T) {
	a, err := Generate(1, 60, 20, ProfileAll)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	b, err := Generate(2, 60, 20, ProfileAll)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if bytes.Equal(a.CloudTrail, b.CloudTrail) {
		t.Error("seeds 1 and 2 produced identical CloudTrail bytes; the seed is not being used")
	}
	if bytes.Equal(a.VPCFlow, b.VPCFlow) {
		t.Error("seeds 1 and 2 produced identical VPC Flow bytes; the seed is not being used")
	}
}

// A generated stream projects through the production Projector without error,
// under the §2.3 label contract, and the evidence refs are visibly synthetic.
func TestGenerate_ProjectsThroughTheProductionProjector(t *testing.T) {
	s, err := Generate(7, 30, 10, ProfileAll)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	obs, err := s.Observations("kusari", Region)
	if err != nil {
		t.Fatalf("Observations: %v", err)
	}
	if len(obs) == 0 {
		t.Fatal("the generated stream projected to nothing")
	}
	for _, o := range obs {
		if err := o.Validate(); err != nil {
			t.Fatalf("generated observation %s is not valid: %v", o.RawEvidenceRef, err)
		}
		if !strings.HasPrefix(o.RawEvidenceRef, "synth/") {
			t.Fatalf("generated observation carries evidence ref %q, which is not visibly synthetic", o.RawEvidenceRef)
		}
		if o.Labels["tenant_id"] != "kusari" {
			t.Fatalf("generated observation %s tenant_id = %q", o.RawEvidenceRef, o.Labels["tenant_id"])
		}
	}

	// IDs are unique, which is what makes the stream dedupable rather than
	// self-colliding. A collision would make the ingest deduper drop real
	// records and the volume test quietly smaller than it claims.
	seen := map[string]string{}
	for _, o := range obs {
		if prev, dup := seen[o.ID]; dup {
			t.Fatalf("observation ID collision between %s and %s", prev, o.RawEvidenceRef)
		}
		seen[o.ID] = o.RawEvidenceRef
	}
}

// No generated timestamp is a wall-clock reading.
func TestGenerate_CarriesNoWallClock(t *testing.T) {
	s, err := Generate(11, 60, 10, ProfileAll)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	obs, err := s.Observations("kusari", Region)
	if err != nil {
		t.Fatalf("Observations: %v", err)
	}
	end := BaseTime.Add(2 * time.Hour)
	for _, o := range obs {
		if o.Timestamp.Before(BaseTime) || o.Timestamp.After(end) {
			t.Fatalf("observation %s is stamped %v, outside the generated span [%v, %v]; something read the clock",
				o.RawEvidenceRef, o.Timestamp, BaseTime, end)
		}
	}
}

// The burst manifest describes what was actually injected, so a caller can
// assert on it without re-deriving the profile.
func TestGenerate_BurstManifestMatchesTheProfile(t *testing.T) {
	for _, tc := range []struct {
		profile Profile
		windows []string
	}{
		{ProfileBaseline, nil},
		{ProfileIAMBurst, []string{"iam-change-burst-10m"}},
		{ProfileRejectBurst, []string{"vpc-reject-burst-5m"}},
		{ProfileCrossAccount, []string{"cross-account-assume-role-burst-30m"}},
		{ProfileAll, []string{"iam-change-burst-10m", "cross-account-assume-role-burst-30m", "vpc-reject-burst-5m"}},
	} {
		t.Run(string(tc.profile), func(t *testing.T) {
			s, err := Generate(5, 60, 10, tc.profile)
			if err != nil {
				t.Fatalf("Generate: %v", err)
			}
			if len(s.Bursts) != len(tc.windows) {
				t.Fatalf("profile %s injected %d bursts, want %d", tc.profile, len(s.Bursts), len(tc.windows))
			}
			for i, want := range tc.windows {
				if s.Bursts[i].Window != want {
					t.Errorf("burst %d window = %q, want %q", i, s.Bursts[i].Window, want)
				}
				if s.Bursts[i].Records == 0 {
					t.Errorf("burst %d (%s) injected no records", i, s.Bursts[i].Kind)
				}
			}
		})
	}
}

// The baseline draws only from the harmless pool: no event name in it appears in
// either shipped bundle's rule lists, and every flow is an ACCEPT.
//
// This is the cheap local half of the false-positive gate. The expensive half —
// running the baseline through the real evaluator and asserting zero findings —
// lives in the e2e package, which is where the bundles are.
func TestGenerate_BaselineIsHarmlessByConstruction(t *testing.T) {
	s, err := Generate(3, 60, 20, ProfileBaseline)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if len(s.Bursts) != 0 {
		t.Fatalf("the baseline profile injected %d bursts", len(s.Bursts))
	}

	// Every mutating API name either shipped bundle lists. A baseline that drew
	// one of these would produce a finding and the e2e gate would go red; this
	// test says so here, where the fix is one line in benignEvents.
	for _, banned := range []string{
		"CreateAccessKey", "UpdateAccessKey", "AttachUserPolicy", "AttachRolePolicy",
		"AttachGroupPolicy", "PutUserPolicy", "PutRolePolicy", "PutGroupPolicy",
		"CreatePolicyVersion", "SetDefaultPolicyVersion", "CreateLoginProfile",
		"UpdateLoginProfile", "ConsoleLogin", "AssumeRole",
		"PutBucketPolicy", "DeleteBucketPolicy", "PutBucketAcl",
		"PutBucketPublicAccessBlock", "DeletePublicAccessBlock",
		"DeleteBucketPublicAccessBlock", "PutAccountPublicAccessBlock",
		"UpdateClusterConfig", "UpdateClusterVersion", "AssociateEncryptionConfig",
		"CreateAddon", "UpdateAddon", "DeleteAddon", "DeleteCluster",
		"CreateAccessEntry", "UpdateAccessEntry", "AssociateAccessPolicy",
		"DeleteDetector", "UpdateDetector", "CreateFilter", "UpdateFilter",
		"ArchiveFindings", "UpdateFindingsFeedback", "DeleteMembers",
		"DisassociateMembers", "DisableOrganizationAdminAccount",
		"StopMonitoringMembers", "DeletePublishingDestination",
	} {
		if bytes.Contains(s.CloudTrail, []byte(`"eventName": "`+banned+`"`)) {
			t.Errorf("the baseline drew %q, which a shipped bundle rule lists; it is not harmless", banned)
		}
	}
	if bytes.Contains(s.VPCFlow, []byte(" REJECT ")) {
		t.Error("the baseline emitted a REJECT flow; vpc-egress-rejected would fire")
	}
}

// Bad arguments are errors rather than an empty corpus. An empty corpus is how a
// volume test comes to assert nothing while staying green.
func TestGenerate_RejectsBadArguments(t *testing.T) {
	for _, tc := range []struct {
		name          string
		minutes, rate int
		profile       Profile
	}{
		{"zero minutes", 0, 10, ProfileBaseline},
		{"negative minutes", -1, 10, ProfileBaseline},
		{"zero rate", 60, 0, ProfileBaseline},
		{"unknown profile", 60, 10, Profile("chaos")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := Generate(1, tc.minutes, tc.rate, tc.profile); err == nil {
				t.Fatal("want an error, got nil")
			}
		})
	}
}
