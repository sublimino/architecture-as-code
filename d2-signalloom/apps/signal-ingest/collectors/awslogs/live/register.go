// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package live

import (
	"context"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
)

// Factory builds the live seams for one collector configuration.
//
// It matches awslogs.LiveClientFactory. The SQS client is bound to the configured
// queue URL here, which is the only place that knows it: NewClients takes the trust
// parameters, the collector config carries the queue.
func Factory(ctx context.Context, cfg awslogs.AWSCollectorConfig) (awslogs.SQSClient, awslogs.S3Fetcher, awslogs.STSAssumer, awslogs.NotificationParser, error) {
	clients, err := NewClients(ctx, cfg.Region, cfg.RoleARN, cfg.ExternalID)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	return clients.SQS.BoundTo(cfg.QueueURL), clients.S3, clients.STS, parserAdapter, nil
}

// parserAdapter adapts ParseS3Notification to awslogs.NotificationParser, which
// takes the body as a string because that is what awslogs.Message.Body is.
func parserAdapter(body string) ([]awslogs.ObjectRef, error) {
	return ParseS3Notification([]byte(body))
}

// Importing this package wires live mode. The core awslogs package cannot import it
// — live imports awslogs for the shared value types, so the dependency only runs
// one way — which is why the wiring is a registration rather than a direct call from
// Collector.Start.
//
// The consequence is worth stating plainly: a binary that does not import this
// package has no live mode, and Collector.Start says so with
// ErrLiveClientsNotWired rather than pretending. The blank import that links it in
// lives next to the collector's registry adapter.
func init() {
	awslogs.SetLiveClientFactory(Factory)
}
