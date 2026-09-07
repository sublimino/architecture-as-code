// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Command stun-tcctl drives Tier 0 network severance from the host.
//
// It is a deliberately separate binary from the signalloom-stun-sentinel
// daemon. The daemon owns the cgroup-freeze half of Tier 0 containment
// (CRKC-P1-2) and its own Kubernetes informer; this binary owns the packet-path
// half. Keeping them as separate modules means the two can be developed,
// reviewed and rolled back independently, and it is why this card touches none
// of the daemon's files.
//
//	stun-tcctl isolate --interface veth123 --ip 10.244.0.7
//	stun-tcctl release --interface veth123 --ip 10.244.0.7
//	stun-tcctl status  --interface veth123
//	stun-tcctl serve   --addr :8082
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/tc"
)

const usage = `stun-tcctl — Tier 0 host-side network severance for stunned agents

USAGE:
  stun-tcctl <command> [flags]

COMMANDS:
  isolate    Attach the drop filter (if needed) and sever the interface
  release    Restore connectivity by clearing the isolation entry
  attach     Attach the drop filter without isolating
  detach     Remove the drop filters (leaves the shared clsact qdisc)
  status     Report attachment, isolation state and drop counters
  metrics    Print Prometheus exposition text to stdout
  serve      Run the HTTP trigger and metrics endpoint
  version    Print version information

COMMON FLAGS:
  --interface <name>   Host-side veth device (required by most commands)
  --ip <addr>          Container IPv4, used for conntrack flush and IP-keyed drop
  --pid <n>            Resolve the interface from a container PID instead
  --cgroup <path>      Resolve the interface from a pod cgroup path instead
  --dry-run            Validate and report without mutating kernel state
  --json               Emit machine-readable output

SAFETY:
  Attachment is refused for non-veth devices (eth0, lo, docker0, br-*, ...).
  This guard is not advisory: an unconditional drop filter on a host device
  would take the node off the network.
`

var version = "0.1.0-crkc-p1-3"

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	cmd := os.Args[1]
	if cmd == "-h" || cmd == "--help" || cmd == "help" {
		fmt.Print(usage)
		os.Exit(0)
	}
	if cmd == "version" || cmd == "--version" {
		fmt.Printf("stun-tcctl %s\n", version)
		os.Exit(0)
	}

	if err := run(cmd, os.Args[2:]); err != nil {
		fmt.Fprintf(os.Stderr, "stun-tcctl: %v\n", err)
		os.Exit(1)
	}
}

type opts struct {
	iface    string
	ip       string
	pid      int
	cgroup   string
	dryRun   bool
	jsonOut  bool
	addr     string
	waitFlag time.Duration
}

func parseFlags(cmd string, args []string) (*opts, error) {
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	o := &opts{}
	fs.StringVar(&o.iface, "interface", "", "host-side veth device name")
	fs.StringVar(&o.ip, "ip", "", "container IPv4 address")
	fs.IntVar(&o.pid, "pid", 0, "container PID to resolve the veth from")
	fs.StringVar(&o.cgroup, "cgroup", "", "pod cgroup path to resolve the veth from")
	fs.BoolVar(&o.dryRun, "dry-run", false, "validate without mutating kernel state")
	fs.BoolVar(&o.jsonOut, "json", false, "emit JSON")
	fs.StringVar(&o.addr, "addr", ":8082", "listen address for serve")
	fs.DurationVar(&o.waitFlag, "timeout", 10*time.Second, "operation timeout")
	if err := fs.Parse(args); err != nil {
		return nil, err
	}
	return o, nil
}

// resolveInterface turns whichever selector the caller supplied into a host
// veth name.
func resolveInterface(o *opts) (string, error) {
	if o.iface != "" {
		return o.iface, nil
	}
	d := tc.NewDiscoverer()
	if o.pid > 0 {
		return d.HostVethForPID(o.pid)
	}
	if o.cgroup != "" {
		return d.HostVethForCgroup(o.cgroup)
	}
	return "", errors.New("one of --interface, --pid or --cgroup is required")
}

func newLoader(o *opts) *tc.Loader {
	if o.dryRun {
		return tc.NewDryRunLoader()
	}
	return tc.NewLoader()
}

func run(cmd string, args []string) error {
	o, err := parseFlags(cmd, args)
	if err != nil {
		return err
	}

	switch cmd {
	case "isolate":
		return doIsolate(o)
	case "release":
		return doRelease(o)
	case "attach":
		return doAttach(o)
	case "detach":
		return doDetach(o)
	case "status":
		return doStatus(o)
	case "metrics":
		return doMetrics(o)
	case "serve":
		return doServe(o)
	default:
		fmt.Fprint(os.Stderr, usage)
		return fmt.Errorf("unknown command %q", cmd)
	}
}

func doIsolate(o *opts) error {
	iface, err := resolveInterface(o)
	if err != nil {
		return err
	}
	l := newLoader(o)
	defer l.Close()
	if err := l.Load(); err != nil {
		return err
	}
	if err := l.Attach(iface); err != nil {
		return err
	}
	ip := net.ParseIP(o.ip)
	elapsed, err := l.Isolate(iface, ip)
	if err != nil {
		return err
	}
	return emit(o, map[string]any{
		"action":      "isolate",
		"interface":   iface,
		"ip":          o.ip,
		"elapsed_ms":  float64(elapsed.Nanoseconds()) / 1e6,
		"under_100ms": elapsed < 100*time.Millisecond,
		"dry_run":     o.dryRun,
	}, fmt.Sprintf("isolated %s in %.3fms", iface, float64(elapsed.Nanoseconds())/1e6))
}

func doRelease(o *opts) error {
	iface, err := resolveInterface(o)
	if err != nil {
		return err
	}
	l := newLoader(o)
	defer l.Close()
	if err := l.Load(); err != nil {
		return err
	}
	// Release must work even if this process never attached: adopt the
	// interface into our attached set first so the map key resolves.
	_ = l.Attach(iface)
	if err := l.Release(iface, net.ParseIP(o.ip)); err != nil {
		return err
	}
	return emit(o, map[string]any{
		"action":    "release",
		"interface": iface,
		"ip":        o.ip,
		"dry_run":   o.dryRun,
	}, fmt.Sprintf("released %s", iface))
}

func doAttach(o *opts) error {
	iface, err := resolveInterface(o)
	if err != nil {
		return err
	}
	l := newLoader(o)
	defer l.Close()
	if err := l.Load(); err != nil {
		return err
	}
	if err := l.Attach(iface); err != nil {
		return err
	}
	return emit(o, map[string]any{"action": "attach", "interface": iface},
		fmt.Sprintf("attached drop filter to %s", iface))
}

func doDetach(o *opts) error {
	iface, err := resolveInterface(o)
	if err != nil {
		return err
	}
	l := newLoader(o)
	defer l.Close()
	if err := l.Load(); err != nil {
		return err
	}
	_ = l.Attach(iface)
	if err := l.Detach(iface); err != nil {
		return err
	}
	return emit(o, map[string]any{"action": "detach", "interface": iface},
		fmt.Sprintf("detached drop filters from %s", iface))
}

func doStatus(o *opts) error {
	iface, err := resolveInterface(o)
	if err != nil {
		return err
	}
	l := newLoader(o)
	defer l.Close()
	if err := l.Load(); err != nil {
		return err
	}
	stats, err := l.Stats(iface)
	if err != nil {
		return err
	}
	payload := map[string]any{
		"interface":       stats.Interface,
		"ifindex":         stats.IfIndex,
		"isolated":        stats.Isolated,
		"packets_dropped": stats.PacketsDropped,
		"bytes_dropped":   stats.BytesDropped,
	}
	if o.ip != "" {
		if n, err := tc.CountIP(net.ParseIP(o.ip)); err == nil {
			payload["conntrack_entries"] = n
		}
	}
	return emit(o, payload, fmt.Sprintf("%s ifindex=%d isolated=%v packets_dropped=%d bytes_dropped=%d",
		stats.Interface, stats.IfIndex, stats.Isolated, stats.PacketsDropped, stats.BytesDropped))
}

func doMetrics(o *opts) error {
	reg := tc.NewRegistry()
	if o.iface != "" {
		l := newLoader(o)
		defer l.Close()
		if err := l.Load(); err == nil {
			if stats, err := l.Stats(o.iface); err == nil {
				reg.ObserveDrops(stats.Interface, stats.PacketsDropped, stats.BytesDropped)
				reg.SetIsolated(stats.Interface, stats.Isolated)
			}
		}
	}
	fmt.Print(reg.Render())
	return nil
}

func doServe(o *opts) error {
	l := newLoader(o)
	defer l.Close()
	if err := l.Load(); err != nil {
		return err
	}
	reg := tc.NewRegistry()
	l.SetMetricsHooks(reg.ObserveIsolationDuration, reg.ObserveDrops)

	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})

	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		// Refresh from the BPF map before rendering, so a scrape always
		// reports kernel truth rather than the last thing we happened to
		// observe.
		for _, iface := range l.AttachedInterfaces() {
			if stats, err := l.Stats(iface); err == nil {
				reg.ObserveDrops(iface, stats.PacketsDropped, stats.BytesDropped)
				reg.SetIsolated(iface, stats.Isolated)
			}
		}
		reg.SetAttachedFilters(len(l.AttachedInterfaces()))
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		fmt.Fprint(w, reg.Render())
	})

	// Trigger endpoints. POST only: a GET that mutates kernel state would be
	// reachable by any link prefetch or crawler on the node network.
	mux.HandleFunc("/v1/isolate", triggerHandler(l, reg, true))
	mux.HandleFunc("/v1/release", triggerHandler(l, reg, false))

	srv := &http.Server{
		Addr:              o.addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		fmt.Fprintf(os.Stderr, "stun-tcctl: serving on %s\n", o.addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		// Clean shutdown matters here beyond tidiness: the BPF maps and
		// the netlink sockets are kernel resources, and a daemon that
		// leaks them on every restart is a genuine kernel memory leak.
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
		fmt.Fprintln(os.Stderr, "stun-tcctl: shut down cleanly")
		return nil
	}
}

func triggerHandler(l *tc.Loader, reg *tc.Registry, isolate bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST required", http.StatusMethodNotAllowed)
			return
		}
		iface := r.URL.Query().Get("interface")
		ipStr := r.URL.Query().Get("ip")
		if iface == "" {
			http.Error(w, "interface query parameter required", http.StatusBadRequest)
			return
		}
		ip := net.ParseIP(ipStr)

		w.Header().Set("Content-Type", "application/json")
		enc := json.NewEncoder(w)

		if isolate {
			if err := l.Attach(iface); err != nil && !errors.Is(err, tc.ErrNotVeth) {
				w.WriteHeader(http.StatusInternalServerError)
				_ = enc.Encode(map[string]any{"error": err.Error()})
				return
			} else if errors.Is(err, tc.ErrNotVeth) {
				w.WriteHeader(http.StatusForbidden)
				_ = enc.Encode(map[string]any{"error": err.Error()})
				return
			}
			elapsed, err := l.Isolate(iface, ip)
			if err != nil {
				w.WriteHeader(http.StatusInternalServerError)
				_ = enc.Encode(map[string]any{"error": err.Error(), "elapsed_ms": ms(elapsed)})
				return
			}
			reg.ObserveIsolationDuration(iface, elapsed)
			reg.SetIsolated(iface, true)
			_ = enc.Encode(map[string]any{
				"action": "isolate", "interface": iface, "ip": ipStr,
				"elapsed_ms": ms(elapsed), "under_100ms": elapsed < 100*time.Millisecond,
			})
			return
		}

		if err := l.Release(iface, ip); err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			_ = enc.Encode(map[string]any{"error": err.Error()})
			return
		}
		reg.SetIsolated(iface, false)
		_ = enc.Encode(map[string]any{"action": "release", "interface": iface, "ip": ipStr})
	}
}

func ms(d time.Duration) float64 { return float64(d.Nanoseconds()) / 1e6 }

func emit(o *opts, payload map[string]any, human string) error {
	if o.jsonOut {
		b, err := json.MarshalIndent(payload, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(b))
		return nil
	}
	fmt.Println(human)
	return nil
}

var _ = strconv.Itoa // retained for future selector parsing
