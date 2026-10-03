// SPDX-License-Identifier: (GPL-2.0-only OR BSD-2-Clause)
// Copyright 2026 ControlPlane Security Authors
//
// prefilter_harness.c -- runs the probe's path_prefilter.h natively, so a Go
// test can hold the exact kernel decision to the userspace one. NOT part of
// the BPF object.
//
// stdin: paths, each terminated by a NUL byte. stdout: one '1' (candidate) or
// '0' (skipped) per path. Each path is truncated to 255 bytes and NUL-terminated
// in a 256-byte buffer, as bpf_probe_read_user_str does in the probe.
//
// No system headers: it builds with -nostdinc, so the only C under test is
// the probe's own, and a toolchain without a readable libc include tree still
// compiles it. getchar/putchar resolve against libc at link time.

#include "path_prefilter.h"

int getchar(void);
int putchar(int c);

/*
 * The probe reuses a per-CPU scratch buffer, so the bytes after a path's NUL
 * are whatever the previous, longer path left there. Fill them with "/./."
 * so any lookahead past the terminator shows up as a wrong answer.
 */
static void stale(char *buf)
{
	int i;

	for (i = 0; i < SENTINEL_PREFILTER_BUF; i++)
		buf[i] = (i % 2) ? '.' : '/';
}

int main(void)
{
	char buf[SENTINEL_PREFILTER_BUF];
	int n = 0;
	int c;

	stale(buf);
	while ((c = getchar()) != -1) {
		if (c != '\0') {
			if (n < SENTINEL_PREFILTER_BUF - 1)
				buf[n++] = (char)c;
			continue;
		}
		buf[n] = '\0';
		putchar(sentinel_path_candidate(buf) ? '1' : '0');
		stale(buf);
		n = 0;
	}
	return 0;
}
