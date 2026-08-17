package audit

import (
	"context"
	"net"
	"testing"
	"time"
)

// The startup defect this file exists to prevent:
//
// signal-ingest read DATABASE_URL from a secretKeyRef, so the DSN was always
// set and main.go always took the Postgres branch. NewPostgresWriter then
// called db.Ping() with no bound. In fe-signalloom the namespace runs a
// default-deny NetworkPolicy and signal-ingest shipped no policy of its own,
// so the packets to postgresql.inf-signalloom:5432 were dropped rather than
// refused. A dropped SYN is not an error, it is silence -- Ping neither
// returned nor failed. main.go's documented fallback
//
//	if err != nil { ...falling back to nop...; auditWriter = audit.NopWriter{} }
//
// could therefore never execute: a hang is not an error. The process never
// reached ListenAndServe, never bound :8082, and the startupProbe
// (periodSeconds 2 x failureThreshold 10) killed it at ~19s. CrashLoopBackOff.
//
// The invariant under test is the one that makes that fallback reachable: an
// unreachable DSN must return an ERROR within the caller's bound, never block
// past it.

// probeBound is the context bound the tests give the connect. Deliberately
// short so the suite stays fast; the production bound is DefaultConnectTimeout
// and is asserted separately below.
const probeBound = 1500 * time.Millisecond

// returnSlack is how long past probeBound the call may take before the test
// calls it a hang. Generous, because a shared CI box schedules goroutines
// late; still far short of the 20s startup-probe budget the bug consumed.
const returnSlack = 4 * time.Second

// blackholeCandidates are addresses a TCP SYN is expected to vanish into:
// packets dropped, no RST, no ICMP unreachable. That silence is what makes
// them a faithful stand-in for a NetworkPolicy drop -- an address that
// answers with a refusal would let an unbounded Ping return quickly and the
// test would pass against the very code it is meant to fail.
//
// 10.255.255.1 is RFC1918 space with no host; 192.0.2.1 is TEST-NET-1
// (RFC 5737). Note 203.0.113.0/24 (TEST-NET-3) is NOT here: on a host with no
// default route it answers ENETUNREACH in single-digit milliseconds, which is
// exactly the vacuous case this list is curated to avoid.
var blackholeCandidates = []string{
	"10.255.255.1:5432",
	"192.0.2.1:5432",
}

// findBlackhole returns an address that genuinely swallows a SYN, or "" if the
// environment routes/refuses all of them. Verifying this rather than assuming
// it is the difference between a test that can fail and decoration: on a host
// where every candidate answers fast, the assertions below would pass without
// any timeout in the production code at all.
func findBlackhole(t *testing.T) string {
	t.Helper()
	for _, addr := range blackholeCandidates {
		start := time.Now()
		conn, err := net.DialTimeout("tcp", addr, probeBound)
		elapsed := time.Since(start)
		if conn != nil {
			conn.Close()
		}
		// A blackhole is the case where the dial burned the whole budget
		// without a verdict. Anything that answered -- accept or refuse --
		// is useless here.
		if err != nil && elapsed >= probeBound {
			t.Logf("blackhole confirmed: %s (dial burned %v with no verdict: %v)", addr, elapsed.Round(time.Millisecond), err)
			return addr
		}
		t.Logf("not a blackhole: %s answered in %v (err=%v)", addr, elapsed.Round(time.Millisecond), err)
	}
	return ""
}

func dsnFor(addr string) string {
	return "postgres://u:p@" + addr + "/db?sslmode=disable"
}

// callWithinBound runs fn on its own goroutine and reports whether it returned
// before limit. It never blocks the test past limit: the point of this helper
// is that the regression presents as a FAILURE, not as a suite that hangs
// until the CI job is killed. The goroutine is deliberately left running --
// it is stuck in exactly the syscall under investigation and cannot be
// cancelled; the test binary exits and takes it with it.
func callWithinBound(limit time.Duration, fn func() error) (err error, returned bool, elapsed time.Duration) {
	type result struct {
		err     error
		elapsed time.Duration
	}
	done := make(chan result, 1)
	start := time.Now()
	go func() {
		e := fn()
		done <- result{err: e, elapsed: time.Since(start)}
	}()

	select {
	case r := <-done:
		return r.err, true, r.elapsed
	case <-time.After(limit):
		return nil, false, time.Since(start)
	}
}

// TestNewPostgresWriterContext_UnreachableDSNErrorsWithinBound is the direct
// falsification of the shipped defect. Against an unbounded db.Ping() the
// connect never returns and this fails with "did not return"; against the
// bounded PingContext it returns a deadline error well inside the budget.
func TestNewPostgresWriterContext_UnreachableDSNErrorsWithinBound(t *testing.T) {
	t.Parallel()

	addr := findBlackhole(t)
	if addr == "" {
		t.Skip("no blackholed address available in this environment; " +
			"every candidate answered, so the hang this test falsifies cannot be staged here")
	}

	tests := []struct {
		name string
		dsn  string
	}{
		{name: "blackholed host", dsn: dsnFor(addr)},
		// Same address via the keyword DSN form pq also accepts. The bound
		// must hold regardless of how the caller spelled the DSN, because
		// the deployment's secret could carry either.
		{name: "blackholed host, keyword form", dsn: "host=" + host(addr) + " port=5432 user=u password=p dbname=db sslmode=disable"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), probeBound)
			defer cancel()

			var pw *PostgresWriter
			err, returned, elapsed := callWithinBound(probeBound+returnSlack, func() error {
				var e error
				pw, e = NewPostgresWriterContext(ctx, tc.dsn)
				return e
			})

			if !returned {
				t.Fatalf("NewPostgresWriterContext did not return within %v (bound was %v) -- "+
					"the connect is unbounded, so main.go's NopWriter fallback can never fire and "+
					"the startup probe kills the pod before it binds", probeBound+returnSlack, probeBound)
			}
			if err == nil {
				t.Fatalf("want an error for unreachable DSN, got nil (writer=%v) -- "+
					"a silent success here would hand main.go a writer whose every "+
					"audit write fails at request time", pw)
			}
			if pw != nil {
				t.Errorf("want nil writer alongside the error, got %v -- a half-open pool "+
					"leaks a connection the caller has no handle to close", pw)
			}
			if elapsed > probeBound+returnSlack {
				t.Errorf("returned after %v, want within %v", elapsed, probeBound+returnSlack)
			}
			t.Logf("returned in %v with: %v", elapsed.Round(time.Millisecond), err)
		})
	}
}

// TestOpenPostgresWriter_NeverContactsServer pins the property main.go relies
// on to keep boot off the network entirely: opening the pool is local work.
// If this ever starts dialling, boot regains a dependency on Postgres being up
// and the whole class of defect returns by a different door.
func TestOpenPostgresWriter_NeverContactsServer(t *testing.T) {
	t.Parallel()

	addr := findBlackhole(t)
	if addr == "" {
		t.Skip("no blackholed address available in this environment")
	}

	// Far tighter than any dial could complete in: if Open dials at all
	// against a blackhole, it cannot come back this fast.
	const localWorkBound = 250 * time.Millisecond

	var pw *PostgresWriter
	err, returned, elapsed := callWithinBound(localWorkBound, func() error {
		var e error
		pw, e = OpenPostgresWriter(dsnFor(addr))
		return e
	})
	if !returned {
		t.Fatalf("OpenPostgresWriter did not return within %v -- it is contacting the "+
			"server, which puts the network back on the boot path", localWorkBound)
	}
	if err != nil {
		t.Fatalf("OpenPostgresWriter(valid DSN, dead host) = %v, want nil: opening the "+
			"pool must not depend on the server being reachable", err)
	}
	if pw == nil {
		t.Fatal("want a writer, got nil")
	}
	defer pw.Close()
	t.Logf("pool opened in %v without touching the network", elapsed.Round(time.Millisecond))
}

// TestPostgresWriter_PingHonoursContextDeadline covers the readiness path.
// /readyz calls Ping on every probe; if Ping can block past its context the
// readiness probe hangs and the pod is killed by the liveness probe instead --
// the same failure mode as the boot hang, relocated.
func TestPostgresWriter_PingHonoursContextDeadline(t *testing.T) {
	t.Parallel()

	addr := findBlackhole(t)
	if addr == "" {
		t.Skip("no blackholed address available in this environment")
	}

	pw, err := OpenPostgresWriter(dsnFor(addr))
	if err != nil {
		t.Fatalf("OpenPostgresWriter: %v", err)
	}
	defer pw.Close()

	ctx, cancel := context.WithTimeout(context.Background(), probeBound)
	defer cancel()

	pingErr, returned, elapsed := callWithinBound(probeBound+returnSlack, func() error {
		return pw.Ping(ctx)
	})
	if !returned {
		t.Fatalf("Ping did not return within %v (bound %v) -- /readyz would hang", probeBound+returnSlack, probeBound)
	}
	if pingErr == nil {
		t.Fatal("want an error pinging a blackholed host, got nil -- /readyz would report " +
			"a pod ready to audit into a database it cannot reach")
	}
	t.Logf("Ping returned in %v with: %v", elapsed.Round(time.Millisecond), pingErr)
}

// TestDefaultConnectTimeout_FitsStartupProbeBudget is the arithmetic the
// deployment depends on, asserted rather than left in a comment. The
// startupProbe in apps/signal-ingest/base/deployment.yaml is periodSeconds 2 x
// failureThreshold 10, so the kubelet kills the container ~20s after start.
// The bound must leave the listener enough of that budget to bind and be
// probed several times over, or a slow-but-recoverable database converts
// straight back into CrashLoopBackOff.
func TestDefaultConnectTimeout_FitsStartupProbeBudget(t *testing.T) {
	t.Parallel()

	const (
		probePeriod      = 2 * time.Second
		probeFailures    = 10
		startupBudget    = probePeriod * probeFailures // 20s
		wantSpareProbes  = 5                           // successful-probe attempts left after the bound elapses
		spareProbeBudget = probePeriod * wantSpareProbes
	)

	if DefaultConnectTimeout <= 0 {
		t.Fatalf("DefaultConnectTimeout = %v, want a positive bound", DefaultConnectTimeout)
	}
	if DefaultConnectTimeout > startupBudget-spareProbeBudget {
		t.Errorf("DefaultConnectTimeout = %v leaves only %v of the %v startup-probe budget; "+
			"want at least %v (%d probe attempts) spare so the listener is reached and "+
			"probed before the kubelet kills the container",
			DefaultConnectTimeout, startupBudget-DefaultConnectTimeout, startupBudget,
			spareProbeBudget, wantSpareProbes)
	}
	// A bound under a second would degrade a healthy-but-cold database to
	// NopWriter on nothing worse than a slow DNS answer. Silently losing the
	// audit trail is the more expensive error of the two.
	if DefaultConnectTimeout < time.Second {
		t.Errorf("DefaultConnectTimeout = %v is too tight; a cold cluster's first "+
			"DNS + TCP + auth round trip can exceed it, and degrading the audit "+
			"trail costs more than a second of boot", DefaultConnectTimeout)
	}
}

// host strips the port from an addr:port pair for the keyword-form DSN.
func host(addr string) string {
	h, _, err := net.SplitHostPort(addr)
	if err != nil {
		return addr
	}
	return h
}
