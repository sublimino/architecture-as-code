// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package netebpf

import (
	"math"
	"strings"
)

// Qname entropy bucket thresholds.
//
// A DNS-tunnelling client encodes exfiltrated bytes into the leftmost label of a
// query name, which makes that label long and high-entropy (base32/base64/hex of
// ciphertext) compared with a human-chosen hostname. The collector buckets the
// Shannon entropy (base 2, over the character distribution) of that leftmost
// label so the detection signal survives into an immutable segment WITHOUT the
// cleartext name itself — a name would be a forbidden direct identifier, the
// bucket is not.
//
// Thresholds, chosen against real hostnames vs. tunnelling payloads:
//   - entropy  < 3.0 bits/char  -> "low"    (e.g. "api", "metrics", "kube-dns")
//   - 3.0 <= e < 4.0 bits/char  -> "medium" (mixed-case service names, some hex)
//   - entropy >= 4.0 bits/char  -> "high"   (base32/base64 tunnelling payloads)
// An absent domain (a direct-IP connection, no DNS at all) buckets to "none" so a
// rule can tell "no name was resolved" from "a low-entropy name was resolved".
const (
	entropyBucketMediumFloor = 3.0
	entropyBucketHighFloor   = 4.0
)

// QnameEntropyBucket returns the entropy bucket of domain's leftmost DNS label.
//
// It is pure and deterministic: the same domain always buckets the same way, so
// fixture mode and a live stream agree. The leftmost label is the text before the
// first ".", or the whole string when there is no ".".
func QnameEntropyBucket(domain string) string {
	domain = strings.TrimSpace(domain)
	if domain == "" {
		return "none"
	}
	label := domain
	if i := strings.IndexByte(domain, '.'); i >= 0 {
		label = domain[:i]
	}
	if label == "" {
		// A leading dot ("...example.com") has an empty leftmost label; there is
		// no payload to score, so it is the same signal class as no name.
		return "none"
	}
	switch e := shannonEntropyBitsPerChar(label); {
	case e >= entropyBucketHighFloor:
		return "high"
	case e >= entropyBucketMediumFloor:
		return "medium"
	default:
		return "low"
	}
}

// shannonEntropyBitsPerChar returns the Shannon entropy of s in bits per
// character, over the empirical distribution of its bytes. An empty string has
// zero entropy.
func shannonEntropyBitsPerChar(s string) float64 {
	if s == "" {
		return 0
	}
	counts := make(map[rune]int, len(s))
	total := 0
	for _, r := range s {
		counts[r]++
		total++
	}
	if total == 0 {
		return 0
	}
	entropy := 0.0
	for _, c := range counts {
		p := float64(c) / float64(total)
		entropy -= p * math.Log2(p)
	}
	return entropy
}
