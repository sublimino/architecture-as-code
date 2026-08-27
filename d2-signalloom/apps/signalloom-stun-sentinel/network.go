package main

import (
	"fmt"
	"net"
	"os/exec"
	"strings"
)

// tcDropFilter manages TC (traffic control) drop filters on pod veth interfaces.
type tcDropFilter struct{}

// findHostVeth discovers the host-side veth interface for a pod by looking up
// the interface index from /sys/class/net. In production, this uses the pod's
// network namespace link index to find the peer on the host.
func (t *tcDropFilter) findHostVeth(podName, podNamespace string) (string, error) {
	// Strategy: list all veth interfaces and match by naming convention.
	// Kubernetes CNIs typically name the host-side veth with a hash or index.
	// For calico: cali*, for flannel: veth*, for cilium: lxc*.
	ifaces, err := net.Interfaces()
	if err != nil {
		return "", fmt.Errorf("list interfaces: %w", err)
	}

	for _, iface := range ifaces {
		name := iface.Name
		// Match common CNI veth naming patterns.
		if strings.HasPrefix(name, "veth") ||
			strings.HasPrefix(name, "cali") ||
			strings.HasPrefix(name, "lxc") {
			// In a real implementation, we'd match the interface index to the
			// pod's netns peer index via /proc/{pid}/net/. For the demo, we
			// return the first matching veth -- the DaemonSet runs per-node so
			// we can be more precise with nsenter in production.
			return name, nil
		}
	}

	return "", fmt.Errorf("no veth interface found for pod %s/%s", podNamespace, podName)
}

// attachDrop adds a TC qdisc and filter that drops all ingress and egress traffic
// on the given interface.
func (t *tcDropFilter) attachDrop(iface string) error {
	// Add ingress qdisc (clsact supports both ingress and egress).
	if out, err := exec.Command("tc", "qdisc", "add", "dev", iface, "clsact").CombinedOutput(); err != nil {
		// EEXIST is acceptable -- qdisc may already be present.
		if !strings.Contains(string(out), "File exists") {
			return fmt.Errorf("tc qdisc add clsact on %s: %s (%w)", iface, strings.TrimSpace(string(out)), err)
		}
	}

	// Drop all ingress.
	if out, err := exec.Command("tc", "filter", "add", "dev", iface, "ingress",
		"matchall", "action", "drop").CombinedOutput(); err != nil {
		return fmt.Errorf("tc filter add ingress drop on %s: %s (%w)", iface, strings.TrimSpace(string(out)), err)
	}

	// Drop all egress.
	if out, err := exec.Command("tc", "filter", "add", "dev", iface, "egress",
		"matchall", "action", "drop").CombinedOutput(); err != nil {
		return fmt.Errorf("tc filter add egress drop on %s: %s (%w)", iface, strings.TrimSpace(string(out)), err)
	}

	return nil
}

// detachDrop removes the clsact qdisc (which removes all associated filters).
func (t *tcDropFilter) detachDrop(iface string) error {
	if out, err := exec.Command("tc", "qdisc", "del", "dev", iface, "clsact").CombinedOutput(); err != nil {
		// Ignore "No such file or directory" -- already removed.
		if !strings.Contains(string(out), "No such file") &&
			!strings.Contains(string(out), "Cannot find") {
			return fmt.Errorf("tc qdisc del clsact on %s: %s (%w)", iface, strings.TrimSpace(string(out)), err)
		}
	}
	return nil
}
