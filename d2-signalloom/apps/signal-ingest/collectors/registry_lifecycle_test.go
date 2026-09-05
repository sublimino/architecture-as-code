// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package collectors

import (
	"context"
	"fmt"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// mockLifecycleCollector is a test collector that tracks lifecycle invocations.
type mockLifecycleCollector struct {
	name        string
	mode        Mode
	startCalls  int32
	stopCalls   int32
	healthCalls int32
	shouldPanic bool
	startErr    error
	healthErr   error
	startBlock  chan struct{}
	workerDone  chan struct{}
}

func newMockCollector(name string, mode Mode) *mockLifecycleCollector {
	return &mockLifecycleCollector{
		name:       name,
		mode:       mode,
		workerDone: make(chan struct{}),
	}
}

func (m *mockLifecycleCollector) Name() string { return m.name }
func (m *mockLifecycleCollector) Mode() Mode   { return m.mode }

func (m *mockLifecycleCollector) Start(ctx context.Context) error {
	atomic.AddInt32(&m.startCalls, 1)
	if m.startErr != nil {
		return m.startErr
	}
	if m.startBlock != nil {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-m.startBlock:
			return nil
		}
	}
	if m.mode == ModeLive {
		// Spawn a worker goroutine to simulate background processing
		go func() {
			defer close(m.workerDone)
			select {
			case <-ctx.Done():
				return
			}
		}()
	}
	return nil
}

func (m *mockLifecycleCollector) Stop() {
	atomic.AddInt32(&m.stopCalls, 1)
	if m.shouldPanic {
		panic("intentional panic in Stop()")
	}
}

func (m *mockLifecycleCollector) Health(ctx context.Context) error {
	atomic.AddInt32(&m.healthCalls, 1)
	return m.healthErr
}

// TestRegistry_ConcurrentRegistrationStress registers N collectors from N goroutines concurrently
// and verifies that the internal registry structures remain consistent with zero dropped entries.
func TestRegistry_ConcurrentRegistrationStress(t *testing.T) {
	const numGoroutines = 50
	reg := NewRegistry()

	var wg sync.WaitGroup
	wg.Add(numGoroutines)

	for i := 0; i < numGoroutines; i++ {
		go func(id int) {
			defer wg.Done()
			colName := fmt.Sprintf("collector-%03d", id)
			col := newMockCollector(colName, ModeLive)
			reg.Register(col)

			// Interleave concurrent reads
			_ = reg.Collectors()
			_ = reg.GetCollector(colName)
		}(i)
	}

	wg.Wait()

	// Verify all N collectors are registered
	collectors := reg.Collectors()
	if len(collectors) != numGoroutines {
		t.Fatalf("registered collector count = %d, want %d", len(collectors), numGoroutines)
	}

	// Verify each individual collector can be retrieved by name
	for i := 0; i < numGoroutines; i++ {
		colName := fmt.Sprintf("collector-%03d", i)
		c := reg.GetCollector(colName)
		if c == nil {
			t.Errorf("collector %q not found in registry", colName)
		} else if c.Name() != colName {
			t.Errorf("got collector name %q, want %q", c.Name(), colName)
		}
	}
}

// TestRegistry_ShutdownExactlyOnce verifies that Stop() calls each started collector's Stop()
// exactly once, and repeated Stop() invocations do not cause double-close or duplicate calls.
func TestRegistry_ShutdownExactlyOnce(t *testing.T) {
	reg := NewRegistry()
	cols := make([]*mockLifecycleCollector, 5)

	for i := range cols {
		cols[i] = newMockCollector(fmt.Sprintf("col-%d", i), ModeLive)
		reg.Register(cols[i])
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := reg.Start(ctx); err != nil {
		t.Fatalf("reg.Start failed: %v", err)
	}

	// Verify all were started
	for i, c := range cols {
		if calls := atomic.LoadInt32(&c.startCalls); calls != 1 {
			t.Errorf("col[%d] startCalls = %d, want 1", i, calls)
		}
		if calls := atomic.LoadInt32(&c.stopCalls); calls != 0 {
			t.Errorf("col[%d] stopCalls before Stop() = %d, want 0", i, calls)
		}
	}

	// First Stop() invocation
	reg.Stop()

	// Verify each collector was stopped exactly once
	for i, c := range cols {
		if calls := atomic.LoadInt32(&c.stopCalls); calls != 1 {
			t.Errorf("col[%d] stopCalls after first Stop() = %d, want 1", i, calls)
		}
	}

	// Second Stop() invocation (idempotency & double-close guard)
	reg.Stop()

	for i, c := range cols {
		if calls := atomic.LoadInt32(&c.stopCalls); calls != 1 {
			t.Errorf("col[%d] stopCalls after second Stop() = %d, want 1 (double-close occurred)", i, calls)
		}
	}
}

// TestRegistry_ShutdownPanicIsolation proves that if a collector panics during Stop(),
// the panic is caught and isolated, allowing subsequent collectors to be cleanly stopped.
func TestRegistry_ShutdownPanicIsolation(t *testing.T) {
	reg := NewRegistry()

	colA := newMockCollector("col-a", ModeLive)
	colB := newMockCollector("col-b", ModeLive)
	colB.shouldPanic = true // panicking collector in middle of shutdown
	colC := newMockCollector("col-c", ModeLive)

	reg.Register(colA)
	reg.Register(colB)
	reg.Register(colC)

	ctx := context.Background()
	if err := reg.Start(ctx); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	// Stop must not panic and must complete
	reg.Stop()

	// Assert colA was stopped
	if calls := atomic.LoadInt32(&colA.stopCalls); calls != 1 {
		t.Errorf("colA stopCalls = %d, want 1", calls)
	}

	// Assert colB was called (and its panic isolated)
	if calls := atomic.LoadInt32(&colB.stopCalls); calls != 1 {
		t.Errorf("colB stopCalls = %d, want 1", calls)
	}

	// Assert colC was NOT aborted and was also stopped exactly once
	if calls := atomic.LoadInt32(&colC.stopCalls); calls != 1 {
		t.Errorf("colC stopCalls = %d, want 1 (shutdown was aborted by preceding panic)", calls)
	}
}

// TestRegistry_GoroutineLeakAssertion proves that no background worker goroutines outlive Stop().
func TestRegistry_GoroutineLeakAssertion(t *testing.T) {
	reg := NewRegistry()
	sink := &trackingSink{}

	// Create real live BaoAuditCollector and SPIREACollector
	col1 := NewBaoAuditCollector(ModeLive, sink)
	col2 := NewSPIREACollector(ModeLive, sink)

	reg.Register(col1)
	reg.Register(col2)

	// Snapshot baseline goroutine count
	baseGoroutines := runtime.NumGoroutine()

	ctx, cancel := context.WithCancel(context.Background())
	if err := reg.Start(ctx); err != nil {
		t.Fatalf("reg.Start failed: %v", err)
	}

	// Ensure workers are active
	time.Sleep(30 * time.Millisecond)
	runningGoroutines := runtime.NumGoroutine()
	if runningGoroutines <= baseGoroutines {
		t.Logf("running goroutines (%d) vs baseline (%d)", runningGoroutines, baseGoroutines)
	}

	// Trigger cancellation and Stop()
	cancel()
	reg.Stop()

	// Wait with timeout for goroutines to settle back to baseline
	deadline := time.Now().Add(1 * time.Second)
	var finalGoroutines int
	for time.Now().Before(deadline) {
		finalGoroutines = runtime.NumGoroutine()
		if finalGoroutines <= baseGoroutines+1 { // allow +/- 1 for test runtime
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	if finalGoroutines > baseGoroutines+2 {
		t.Fatalf("goroutine leak detected: baseline=%d, active_after_stop=%d (leaked %d goroutines)",
			baseGoroutines, finalGoroutines, finalGoroutines-baseGoroutines)
	}
}

// TestRegistry_BoundedStartupTimeout proves that the registry does not block indefinitely
// when a collector's Start() hangs, and reflects the startup error in Health().
func TestRegistry_BoundedStartupTimeout(t *testing.T) {
	reg := NewRegistry()

	colFast := newMockCollector("col-fast", ModeLive)
	colHanging := newMockCollector("col-hanging", ModeLive)
	colHanging.startBlock = make(chan struct{}) // never unblocked

	reg.Register(colFast)
	reg.Register(colHanging)

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	start := time.Now()
	err := reg.Start(ctx)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("expected Start() error on timeout context, got nil")
	}

	if elapsed > 500*time.Millisecond {
		t.Fatalf("Start() took %v to timeout, expected bounded ~100ms", elapsed)
	}

	// Health check must reflect startup failure
	healthErr := reg.Health(context.Background())
	if healthErr == nil {
		t.Fatal("Health() returned nil after failed startup, want error")
	}
}

// TestRegistry_OffModeInertness verifies that collectors in ModeOff are completely ignored during Start/Stop.
func TestRegistry_OffModeInertness(t *testing.T) {
	reg := NewRegistry()
	cols := make([]*mockLifecycleCollector, 10)

	for i := range cols {
		cols[i] = newMockCollector(fmt.Sprintf("off-col-%d", i), ModeOff)
		reg.Register(cols[i])
	}

	baseGoroutines := runtime.NumGoroutine()

	ctx := context.Background()
	if err := reg.Start(ctx); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	// Verify no collector was started
	for i, c := range cols {
		if calls := atomic.LoadInt32(&c.startCalls); calls != 0 {
			t.Errorf("col[%d] in ModeOff had startCalls = %d, want 0", i, calls)
		}
	}

	time.Sleep(10 * time.Millisecond)
	if afterGoroutines := runtime.NumGoroutine(); afterGoroutines > baseGoroutines+1 {
		t.Errorf("off-mode collectors spawned goroutines: before=%d, after=%d", baseGoroutines, afterGoroutines)
	}

	reg.Stop()

	// Verify no collector had Stop() called
	for i, c := range cols {
		if calls := atomic.LoadInt32(&c.stopCalls); calls != 0 {
			t.Errorf("col[%d] in ModeOff had stopCalls = %d, want 0", i, calls)
		}
	}
}
