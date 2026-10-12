// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// EnvAccounts is the environment variable containing the multi-account JSON list
// (SLAWS D11).
const EnvAccounts = "COLLECTOR_AWSLOGS_ACCOUNTS"

// AccountEntry is one customer account's declaration in COLLECTOR_AWSLOGS_ACCOUNTS.
type AccountEntry struct {
	AccountID  string `json:"account_id"`
	RoleARN    string `json:"role_arn"`
	ExternalID string `json:"external_id"`
	QueueURL   string `json:"queue_url"`
	TenantID   string `json:"tenant_id"`
	Region     string `json:"region,omitempty"`
}

// ParseAccounts parses raw JSON into a slice of AWSCollectorConfig (SLAWS D11).
//
// Validation is fail-closed: an empty or missing required field, unparseable JSON,
// or duplicate account_id / queue_url refuses boot naming the offending index.
// Empty raw input returns nil, nil.
func ParseAccounts(raw string) ([]AWSCollectorConfig, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, nil
	}

	var entries []AccountEntry
	if err := json.Unmarshal([]byte(trimmed), &entries); err != nil {
		return nil, fmt.Errorf("awslogs: %s: invalid JSON: %w", EnvAccounts, err)
	}
	if len(entries) == 0 {
		return nil, nil
	}

	seenAccountIDs := make(map[string]int, len(entries))
	seenQueueURLs := make(map[string]int, len(entries))
	configs := make([]AWSCollectorConfig, len(entries))

	baseBuffer := os.Getenv(EnvBufferDir)
	if baseBuffer == "" {
		baseBuffer = DefaultBufferDir
	}

	for i, entry := range entries {
		if entry.AccountID == "" {
			return nil, fmt.Errorf("awslogs: %s[%d]: account_id is required", EnvAccounts, i)
		}
		if entry.RoleARN == "" {
			return nil, fmt.Errorf("awslogs: %s[%d]: role_arn is required", EnvAccounts, i)
		}
		if entry.ExternalID == "" {
			return nil, fmt.Errorf("awslogs: %s[%d]: external_id is required", EnvAccounts, i)
		}
		if entry.QueueURL == "" {
			return nil, fmt.Errorf("awslogs: %s[%d]: queue_url is required", EnvAccounts, i)
		}
		if entry.TenantID == "" {
			return nil, fmt.Errorf("awslogs: %s[%d]: tenant_id is required", EnvAccounts, i)
		}

		if firstIdx, ok := seenAccountIDs[entry.AccountID]; ok {
			return nil, fmt.Errorf("awslogs: %s: duplicate account_id %q at [%d] and [%d]",
				EnvAccounts, entry.AccountID, firstIdx, i)
		}
		seenAccountIDs[entry.AccountID] = i

		if firstIdx, ok := seenQueueURLs[entry.QueueURL]; ok {
			return nil, fmt.Errorf("awslogs: %s: duplicate queue_url %q at [%d] and [%d]",
				EnvAccounts, entry.QueueURL, firstIdx, i)
		}
		seenQueueURLs[entry.QueueURL] = i

		region := entry.Region
		if region == "" {
			region = os.Getenv(EnvRegion)
		}
		if region == "" {
			region = DefaultRegion
		}

		bufferDir := filepath.Join(baseBuffer, entry.AccountID)

		cfg := AWSCollectorConfig{
			AccountID:  entry.AccountID,
			TenantID:   entry.TenantID,
			RoleARN:    entry.RoleARN,
			ExternalID: entry.ExternalID,
			QueueURL:   entry.QueueURL,
			Region:     region,
			BufferDir:  bufferDir,
		}.WithDefaults()

		configs[i] = cfg
	}

	return configs, nil
}

// AccountsFromEnv parses COLLECTOR_AWSLOGS_ACCOUNTS from the environment.
func AccountsFromEnv() ([]AWSCollectorConfig, error) {
	return ParseAccounts(os.Getenv(EnvAccounts))
}
