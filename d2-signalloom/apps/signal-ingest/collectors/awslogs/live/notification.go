// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package live

import (
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
)

// ParseS3Notification extracts the object references from an SQS message body.
//
// It is a one-line delegation to awslogs.ParseS3Notification, which is the single
// implementation. The parser used to live here, and the core package carried a
// second, weaker copy that did not percent-decode the object key — so a key with a
// space in it resolved in live mode and 404'd in any path wired to the core default.
// Keeping the function exported here preserves the live package's surface (and the
// factory's parser adapter) without preserving the duplicate.
//
// The outcome contract — refs/nil to fetch, nil/nil for "nothing to do", nil/err for
// "cannot understand, leave it in flight" — is documented on
// awslogs.ParseS3Notification and is the collector's dispatch table, not a detail.
//
// The parser is deliberately SDK-free and therefore lives in the core package: it is
// pure body-shape decoding, it is the thing the fixture path needs most, and nothing
// about it requires aws-sdk-go-v2 to be in the import graph.
func ParseS3Notification(body []byte) ([]awslogs.ObjectRef, error) {
	return awslogs.ParseS3Notification(body)
}
