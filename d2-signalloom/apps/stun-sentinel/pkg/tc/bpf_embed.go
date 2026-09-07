// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

import (
	"bytes"
	_ "embed"
	"errors"
	"fmt"
	"os"
	"syscall"

	"github.com/cilium/ebpf"
)

// tcDropObject is the compiled BPF ELF, built by bpf/build.sh inside the pinned
// container and committed to the repository.
//
// Embedding the object rather than shelling out to clang at runtime is the
// whole point of the build strategy CRKC-P1-PRE recorded: the DaemonSet image
// carries no compiler, the build host needs no LLVM, and the bytecode that was
// reviewed is byte-for-byte the bytecode that loads.
//
//go:embed tc_drop.bpf.o
var tcDropObject []byte

// BPFObject returns a copy of the embedded object. Exported so tests can assert
// on the artifact (ELF magic, size, section presence) without reaching outside
// the package, and so the CLI can dump it for offline inspection.
func BPFObject() []byte {
	out := make([]byte, len(tcDropObject))
	copy(out, tcDropObject)
	return out
}

// loadCollectionSpec parses the embedded ELF into a CollectionSpec.
func loadCollectionSpec() (*ebpf.CollectionSpec, error) {
	if len(tcDropObject) == 0 {
		return nil, errors.New("embedded BPF object is empty: run bpf/build.sh")
	}
	spec, err := ebpf.LoadCollectionSpecFromReader(bytes.NewReader(tcDropObject))
	if err != nil {
		return nil, fmt.Errorf("parse embedded BPF ELF: %w", err)
	}
	return spec, nil
}

// isNotFound reports whether an error means "the thing is not there".
//
// This matters more than it looks. A container terminating during a veth lookup
// is routine, and the kernel reports it through several distinct channels
// depending on which syscall noticed: ENOENT, ENODEV, ESRCH, or a
// netlink.LinkNotFoundError. Treating any of them as a hard failure turns a
// normal pod deletion into a Sentinel error, and the resulting log noise is how
// real failures get ignored.
func isNotFound(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, os.ErrNotExist) ||
		errors.Is(err, syscall.ENOENT) ||
		errors.Is(err, syscall.ENODEV) ||
		errors.Is(err, syscall.ESRCH) ||
		errors.Is(err, ErrInterfaceGone) {
		return true
	}
	// vishvananda/netlink returns a distinct type for a missing link.
	var linkErr interface{ Error() string }
	if errors.As(err, &linkErr) {
		msg := linkErr.Error()
		if containsAny(msg, "Link not found", "no such device", "no such file") {
			return true
		}
	}
	return false
}

// isExist reports whether an error means "already present". clsact qdisc
// creation is expected to hit this constantly and it is not a failure.
func isExist(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, os.ErrExist) || errors.Is(err, syscall.EEXIST) {
		return true
	}
	return containsAny(err.Error(), "file exists", "File exists", "already exists")
}

// isPermission reports whether an error means a capability is missing. Surfaced
// separately because the remedy is entirely different: it is a DaemonSet
// securityContext change, not a retry.
func isPermission(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, os.ErrPermission) ||
		errors.Is(err, syscall.EPERM) ||
		errors.Is(err, syscall.EACCES) {
		return true
	}
	return containsAny(err.Error(), "operation not permitted", "permission denied")
}

func containsAny(haystack string, needles ...string) bool {
	for _, n := range needles {
		if len(n) > 0 && len(haystack) >= len(n) {
			for i := 0; i+len(n) <= len(haystack); i++ {
				if haystack[i:i+len(n)] == n {
					return true
				}
			}
		}
	}
	return false
}
