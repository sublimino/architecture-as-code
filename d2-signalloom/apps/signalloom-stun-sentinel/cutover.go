// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"context"
	"fmt"
	"os"
	"sync/atomic"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

const (
	defaultPredecessorSelector = "app.kubernetes.io/name=stun-sentinel"
	cutoverPollInterval        = 5 * time.Second
)

// cutoverGate ensures two probes never arm simultaneously on the same node (ADR-07).
// It polls for predecessor pods on $NODE_NAME and blocks correlator/reconciler arming
// until all predecessor probe pods have terminated.
type cutoverGate struct {
	clientset           kubernetes.Interface
	namespace           string
	nodeName            string
	predecessorSelector string
	armed               atomic.Bool
	pollInterval        time.Duration
}

func newCutoverGate(clientset kubernetes.Interface, namespace string) *cutoverGate {
	selector := defaultPredecessorSelector
	if val, ok := os.LookupEnv("WARDEN_PREDECESSOR_SELECTOR"); ok {
		selector = val
	}
	nodeName := os.Getenv("NODE_NAME")
	return &cutoverGate{
		clientset:           clientset,
		namespace:           namespace,
		nodeName:            nodeName,
		predecessorSelector: selector,
		pollInterval:        cutoverPollInterval,
	}
}

func (c *cutoverGate) isArmed() bool {
	return c.armed.Load()
}

// wait blocks until all predecessor pods on the local node are terminated, then arms the gate.
func (c *cutoverGate) wait(ctx context.Context) error {
	if c.predecessorSelector == "" || c.clientset == nil || c.nodeName == "" {
		c.armed.Store(true)
		logEvent(stunEvent{
			Timestamp: now(),
			Event:     "cutover_armed",
			Details: map[string]interface{}{
				"node_name": c.nodeName,
				"reason":    "selector_disabled_or_standalone",
			},
		})
		return nil
	}

	ticker := time.NewTicker(c.pollInterval)
	defer ticker.Stop()

	// Initial check before waiting for tick
	for {
		pods, err := c.clientset.CoreV1().Pods(c.namespace).List(ctx, metav1.ListOptions{
			LabelSelector: c.predecessorSelector,
			FieldSelector: "spec.nodeName=" + c.nodeName,
		})
		if err != nil {
			logEvent(stunEvent{
				Timestamp: now(),
				Event:     "cutover_error",
				Error:     fmt.Sprintf("list predecessor pods on node %s: %v", c.nodeName, err),
			})
		} else {
			active := 0
			for _, p := range pods.Items {
				if c.nodeName != "" && p.Spec.NodeName != "" && p.Spec.NodeName != c.nodeName {
					continue
				}
				if p.Status.Phase != corev1.PodSucceeded && p.Status.Phase != corev1.PodFailed {
					active++
				}
			}
			if active == 0 {
				c.armed.Store(true)
				logEvent(stunEvent{
					Timestamp: now(),
					Event:     "cutover_armed",
					Details: map[string]interface{}{
						"node_name":            c.nodeName,
						"predecessor_selector": c.predecessorSelector,
					},
				})
				return nil
			}
			logEvent(stunEvent{
				Timestamp: now(),
				Event:     "cutover_waiting",
				Details: map[string]interface{}{
					"node_name":            c.nodeName,
					"predecessor_selector": c.predecessorSelector,
					"predecessor_count":    active,
				},
			})
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}
