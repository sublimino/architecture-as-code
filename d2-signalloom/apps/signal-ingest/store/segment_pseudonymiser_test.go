// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package store

import (
	"encoding/hex"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// TestSegmentPseudonymiserMatchesObscelPseudonymiser proves byte equality on a fixed vector
// between store.SegmentPseudonymiser and obscel.HMACPseudonymiser.
func TestSegmentPseudonymiserMatchesObscelPseudonymiser(t *testing.T) {
	rootHex := "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
	root, err := hex.DecodeString(rootHex)
	if err != nil {
		t.Fatalf("DecodeString: %v", err)
	}

	tenant := "kusari"
	epoch := uint32(1)

	segP, err := NewSegmentPseudonymiser(root, tenant, epoch)
	if err != nil {
		t.Fatalf("NewSegmentPseudonymiser: %v", err)
	}

	obsP, err := obscel.NewHMACPseudonymiser(root, tenant, epoch)
	if err != nil {
		t.Fatalf("NewHMACPseudonymiser: %v", err)
	}

	vectors := []string{
		"arn:aws:iam::123456789012:user/kusari-agent",
		"arn:aws:iam::123456789012:role/admin",
		"arn:aws:sts::123456789012:assumed-role/operator/session-1",
		"alice@example.com",
		"",
	}

	for _, v := range vectors {
		t.Run("vector_"+v, func(t *testing.T) {
			gotSeg, err1 := segP.Pseudonym(v)
			if err1 != nil {
				t.Fatalf("segP.Pseudonym(%q): %v", v, err1)
			}
			gotObs, err2 := obsP.Pseudonym(v)
			if err2 != nil {
				t.Fatalf("obsP.Pseudonym(%q): %v", v, err2)
			}
			if gotSeg != gotObs {
				t.Fatalf("pseudonym mismatch for %q: seg=%q obscel=%q", v, gotSeg, gotObs)
			}
		})
	}
}
