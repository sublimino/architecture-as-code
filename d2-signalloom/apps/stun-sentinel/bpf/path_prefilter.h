// SPDX-License-Identifier: (GPL-2.0-only OR BSD-2-Clause)
// Copyright 2026 ControlPlane Security Authors
//
// path_prefilter.h -- which file opens are worth a ring-buffer slot.
//
// The live sentinel read 374,724,889 records of which 99.93% were not
// sensitive, and the kernel dropped 3,700,717 (1%) for want of ring space: a
// sensitive open could be lost before the correlator ever saw it. This filter
// runs before a slot is reserved, so the ring carries only CANDIDATES.
//
// It is a SUPERSET of the userspace check, never a substitute for it: the
// correlator's IsSensitivePath / sensitiveTarget stays authoritative on every
// record that arrives. A path is a candidate when userspace could possibly
// call it sensitive:
//
//   * it is not absolute (relative, empty, or the user pointer was
//     unreadable): userspace resolves it against the process cwd;
//   * it is a sensitive prefix or lies beneath one (sensitive_prefixes.h,
//     generated from correlator.DefaultSensitivePrefixes);
//   * it is not lexically clean (`//`, `/./`, `/../`, or a trailing `/.` or
//     `/..`): userspace path.Clean()s it first, so /tmp/../etc/passwd counts.
//
// Plain C, no BPF helpers, so pkg/correlator/prefilter_agreement_test.go can
// compile this exact file natively and prove it agrees with userspace on a
// shared table. Bounded loop only (verifier: kernel >= 5.3).

#ifndef SENTINEL_PATH_PREFILTER_H
#define SENTINEL_PATH_PREFILTER_H

#include "sensitive_prefixes.h"

#define SENTINEL_PREFILTER_BUF 256

/* p: NUL-terminated within SENTINEL_PREFILTER_BUF bytes. 1 = emit, 0 = skip. */
static __attribute__((always_inline)) inline int sentinel_path_candidate(const char *p)
{
	int i;

	if (p[0] != '/')
		return 1;
	if (sentinel_sensitive_prefix(p))
		return 1;
	for (i = 0; i < SENTINEL_PREFILTER_BUF; i++) {
		char c1, c2, c3;

		if (p[i] == '\0')
			return 0;
		if (p[i] != '/')
			continue;
		/* Past the buffer reads as NUL: the string ends there anyway. */
		c1 = i + 1 < SENTINEL_PREFILTER_BUF ? p[i + 1] : '\0';
		c2 = i + 2 < SENTINEL_PREFILTER_BUF ? p[i + 2] : '\0';
		c3 = i + 3 < SENTINEL_PREFILTER_BUF ? p[i + 3] : '\0';
		if (c1 == '/')
			return 1;
		if (c1 == '.' && (c2 == '/' || c2 == '\0'))
			return 1;
		if (c1 == '.' && c2 == '.' && (c3 == '/' || c3 == '\0'))
			return 1;
	}
	/* No NUL in the whole buffer: not a string the probe produces. Emit it. */
	return 1;
}

#endif /* SENTINEL_PATH_PREFILTER_H */
