// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package transform

import "regexp"

// Identifier patterns (SLDP-P3-1).
//
// Before this card neither redaction path knew what an identifier looked like. transform/redactor.go
// carried Bearer, JWT and PEM; transform/secrets_scrubber.go added AWS, GitHub PAT and Vault. All
// six are *secrets*. There was no email, IP-address or username pattern anywhere in the repository,
// while the proposal classifies a source IP as personal data following Breyer (CJEU C-582/14) — so
// every one of those flowed through both scrubbers untouched and into an immutable segment.
//
// These patterns are deliberately conservative. A false positive redacts a value that did not need
// it, which is recoverable; a false negative writes a person's identifier into a signed Parquet
// block that can never afterwards be rewritten, which is not.
var (
	// emailPattern matches an addr-spec conservatively: no quoted local parts, no comments.
	emailPattern = regexp.MustCompile(`\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b`)

	// ipv4Pattern matches a dotted quad whose octets are each 0-255.
	//
	// Go's RE2 has no lookaround, so the boundary is enforced with explicit guard groups: group 1
	// requires the character before the quad to be neither a digit nor a dot, and group 3 the same
	// after it. Both are captured and re-emitted by redactIdentifiers. Without them "1.2.3.4.5"
	// would have its first four components matched and a build number would be redacted as an
	// address. A three-component version such as Go's own "1.24.1" cannot match at all, because the
	// pattern requires four octets.
	ipv4Pattern = regexp.MustCompile(
		`(^|[^0-9.])((?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3})([^0-9.]|$)`)

	// ipv6Pattern matches full and compressed forms. It requires at least two colons so that a
	// Kubernetes subject such as "system:serviceaccount:ns:name" cannot be mistaken for an address
	// — that is handled by k8sSubjectPattern instead.
	ipv6Pattern = regexp.MustCompile(
		`(?i)\b(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{1,4}\b|(?:[0-9a-f]{1,4}:){1,7}:(?:[0-9a-f]{1,4})?`)

	// k8sSubjectPattern matches Kubernetes and generic RBAC subject forms.
	k8sSubjectPattern = regexp.MustCompile(
		`\bsystem:(?:serviceaccount|node|kube-proxy|anonymous):[A-Za-z0-9._\-]+(?::[A-Za-z0-9._\-]+)?`)

	// usernamePattern matches explicitly-labelled principal forms such as "user:alice" or
	// "username = bob". The label AND the original separator are both captured, so redaction
	// rewrites only the value and leaves the surrounding text byte-identical. Normalising the
	// separator instead would make the redactor a silent reformatter of every record it touched.
	usernamePattern = regexp.MustCompile(
		`(?i)\b(user|username|login|subject|principal|upn)(\s*[:=]\s*)([A-Za-z0-9._\-\\@]+)`)
)

// redactIdentifiers replaces every direct-identifier class in text using the supplied keyed
// replacement function.
//
// The replacement is deterministic rather than a fixed sentinel, so two occurrences of the same
// identifier remain comparable without being readable in the clear.
//
// KNOWN WEAKNESS, recorded rather than left implied. The strength depends entirely on which
// replacement the caller passes, and the two callers differ:
//   - CryptographicSecretScrubber.ScrubText passes AnonymizeHMAC — keyed, 128-bit. Sound.
//   - SecretRedactor.RedactText passes hashRedact, which is an UNKEYED SHA-256 truncated to 8 hex
//     characters (32 bits). For a small enumerable domain — and the whole IPv4 space is 2^32 — that
//     is reversible by exhaustive search in minutes, and it collides across a large corpus.
//
// So redaction via SecretRedactor obscures an identifier in a log line; it does NOT pseudonymise it
// to the standard the segment columns meet. Raised by adversarial review (SLDP-P3-1, finding F2);
// fixing it means keying hashRedact, which changes every existing REDACTED_SHA256 value and is
// therefore a migration, not an edit. See docs/signalloom/sldp-p3-1-proof.md.
func redactIdentifiers(text string, replace func(string) string) string {
	if text == "" {
		return ""
	}

	// Kubernetes subjects first: they contain colons that the IPv6 pattern would otherwise
	// partially consume, and they are the most specific shape.
	text = k8sSubjectPattern.ReplaceAllStringFunc(text, replace)
	text = emailPattern.ReplaceAllStringFunc(text, replace)
	text = ipv6Pattern.ReplaceAllStringFunc(text, replace)

	// IPv4 carries its delimiters in capture groups 1 and 3, so they must be put back.
	text = ipv4Pattern.ReplaceAllStringFunc(text, func(m string) string {
		parts := ipv4Pattern.FindStringSubmatch(m)
		if len(parts) != 4 {
			return m
		}
		return parts[1] + replace(parts[2]) + parts[3]
	})

	text = usernamePattern.ReplaceAllStringFunc(text, func(m string) string {
		parts := usernamePattern.FindStringSubmatch(m)
		if len(parts) != 4 {
			return m
		}
		return parts[1] + parts[2] + replace(parts[3])
	})

	return text
}
