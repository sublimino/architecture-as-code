// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"

	tetragon "github.com/cilium/tetragon/api/v1/tetragon"
	"google.golang.org/protobuf/encoding/protojson"
)

// maxJSONLine caps a single NDJSON record. Tetragon's exporter emits one JSON
// object per line; a line above this is not a Tetragon event, it is a corrupted
// or concatenated file. Without the cap, bufio.Scanner's default 64 KiB limit
// would silently truncate legitimate large events (a deep ancestor chain with
// long argv), and the decode failure would be reported as malformed JSON —
// pointing the operator at the wrong problem entirely.
const maxJSONLine = 4 * 1024 * 1024 // 4 MiB

// jsonUnmarshaler tolerates fields the pinned v1.1.0 schema does not know
// about. This is the forward-compatibility hinge: a Tetragon agent one minor
// version ahead adds fields, and DiscardUnknown means those events still decode
// into everything we DO understand instead of the whole stream erroring out.
// It does not paper over a genuine format change — a renamed or retyped field
// still fails.
var jsonUnmarshaler = protojson.UnmarshalOptions{DiscardUnknown: true}

// DecodeJSONEvent parses a single line of Tetragon JSON export into a
// GetEventsResponse.
func DecodeJSONEvent(line []byte) (*tetragon.GetEventsResponse, error) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return nil, nil
	}

	var resp tetragon.GetEventsResponse
	if err := jsonUnmarshaler.Unmarshal(line, &resp); err != nil {
		return nil, fmt.Errorf("decode tetragon json event: %w", err)
	}
	return &resp, nil
}

// StreamJSON reads newline-delimited Tetragon JSON from r and ingests each
// event through the same accounting path the gRPC stream uses.
//
// A malformed line increments tetragon_stream_errors_total and the stream
// CONTINUES. Aborting on one bad line would let a single truncated write — the
// normal consequence of log rotation racing the exporter — silently terminate
// telemetry ingestion for the rest of the process lifetime. The error counter
// is how that becomes visible without becoming fatal.
//
// It returns the number of lines successfully decoded, and an error only if the
// underlying reader itself failed.
func (s *StreamClient) StreamJSON(ctx context.Context, r io.Reader) (int, error) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), maxJSONLine)

	decoded := 0
	for scanner.Scan() {
		if ctx.Err() != nil {
			return decoded, ctx.Err()
		}

		resp, err := DecodeJSONEvent(scanner.Bytes())
		if err != nil {
			s.metrics.incErrors()
			s.cfg.Logger.Warn("skipping malformed tetragon json line", "error", err)
			continue
		}
		if resp == nil {
			continue // blank line
		}

		s.Ingest(ctx, resp)
		decoded++
	}

	if err := scanner.Err(); err != nil {
		s.metrics.incErrors()
		return decoded, fmt.Errorf("read tetragon json stream: %w", err)
	}
	return decoded, nil
}
