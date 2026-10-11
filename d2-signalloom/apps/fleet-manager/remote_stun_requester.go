// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import "log/slog"

// RemoteStunRequesterAdapter exposes RemoteStunStore through signal-ingest's decoupled requester shape.
type RemoteStunRequesterAdapter struct {
	store               *RemoteStunStore
	requestedByOverride string
}

// NewRemoteStunRequester constructs an adapter for a fleet-manager remote stun store.
func NewRemoteStunRequester(store *RemoteStunStore) *RemoteStunRequesterAdapter {
	return &RemoteStunRequesterAdapter{store: store}
}

// RequestRemoteStun forwards to RemoteStunStore.Request and discards the record.
// It lets a caller in another module request a remote stun without importing fleet-manager.
func (a *RemoteStunRequesterAdapter) RequestRemoteStun(
	clusterID, namespace, name, reason, requestedBy string,
) {
	if a == nil || a.store == nil {
		slog.Warn(
			"remote stun request skipped because the fleet-manager store is unavailable",
			"cluster_id", clusterID,
			"namespace", namespace,
			"name", name,
			"reason", reason,
		)
		return
	}
	if a.requestedByOverride != "" {
		requestedBy = a.requestedByOverride
	}
	a.store.Request(clusterID, namespace, name, reason, requestedBy)
}
