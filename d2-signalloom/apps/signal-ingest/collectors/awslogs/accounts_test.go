// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestAccountsFromEnv_ThreeEntries(t *testing.T) {
	raw := `[
		{
			"account_id": "111111111111",
			"role_arn": "arn:aws:iam::111111111111:role/read-telemetry",
			"external_id": "ext-1",
			"queue_url": "https://sqs.us-east-1.amazonaws.com/111111111111/q1",
			"tenant_id": "tenant-alpha",
			"region": "us-east-1"
		},
		{
			"account_id": "222222222222",
			"role_arn": "arn:aws:iam::222222222222:role/read-telemetry",
			"external_id": "ext-2",
			"queue_url": "https://sqs.eu-west-1.amazonaws.com/222222222222/q2",
			"tenant_id": "tenant-beta",
			"region": "eu-west-1"
		},
		{
			"account_id": "333333333333",
			"role_arn": "arn:aws:iam::333333333333:role/read-telemetry",
			"external_id": "ext-3",
			"queue_url": "https://sqs.us-west-2.amazonaws.com/333333333333/q3",
			"tenant_id": "tenant-gamma",
			"region": "us-west-2"
		}
	]`
	t.Setenv(EnvAccounts, raw)

	cfgs, err := AccountsFromEnv()
	if err != nil {
		t.Fatalf("AccountsFromEnv: unexpected error %v", err)
	}
	if len(cfgs) != 3 {
		t.Fatalf("AccountsFromEnv returned %d configs, want 3", len(cfgs))
	}

	tenants := make(map[string]bool)
	bufferDirs := make(map[string]bool)

	for i, cfg := range cfgs {
		if cfg.TenantID == "" {
			t.Errorf("config %d has empty TenantID", i)
		}
		if tenants[cfg.TenantID] {
			t.Errorf("duplicate TenantID %q at config %d", cfg.TenantID, i)
		}
		tenants[cfg.TenantID] = true

		if bufferDirs[cfg.BufferDir] {
			t.Errorf("duplicate BufferDir %q at config %d", cfg.BufferDir, i)
		}
		bufferDirs[cfg.BufferDir] = true

		expectedSuffix := filepath.Join("awslogs", cfg.AccountID)
		if !strings.HasSuffix(cfg.BufferDir, expectedSuffix) && !strings.HasSuffix(cfg.BufferDir, cfg.AccountID) {
			t.Errorf("config %d BufferDir %q does not contain account_id %q", i, cfg.BufferDir, cfg.AccountID)
		}
	}
}

func TestAccountsFromEnv_MissingQueueURL(t *testing.T) {
	raw := `[
		{
			"account_id": "111111111111",
			"role_arn": "arn:aws:iam::111111111111:role/read-telemetry",
			"external_id": "ext-1",
			"queue_url": "https://sqs.us-east-1.amazonaws.com/111111111111/q1",
			"tenant_id": "tenant-alpha"
		},
		{
			"account_id": "222222222222",
			"role_arn": "arn:aws:iam::222222222222:role/read-telemetry",
			"external_id": "ext-2",
			"tenant_id": "tenant-beta"
		}
	]`
	t.Setenv(EnvAccounts, raw)

	_, err := AccountsFromEnv()
	if err == nil {
		t.Fatal("AccountsFromEnv with missing queue_url expected error, got nil")
	}
	want := "COLLECTOR_AWSLOGS_ACCOUNTS[1]: queue_url is required"
	if !strings.Contains(err.Error(), want) {
		t.Errorf("error = %q, want it to contain %q", err.Error(), want)
	}
}

func TestAccountsFromEnv_MissingExternalID(t *testing.T) {
	raw := `[
		{
			"account_id": "111111111111",
			"role_arn": "arn:aws:iam::111111111111:role/read-telemetry",
			"external_id": "ext-1",
			"queue_url": "https://sqs.us-east-1.amazonaws.com/111111111111/q1",
			"tenant_id": "tenant-alpha"
		},
		{
			"account_id": "222222222222",
			"role_arn": "arn:aws:iam::222222222222:role/read-telemetry",
			"queue_url": "https://sqs.us-east-1.amazonaws.com/222222222222/q2",
			"tenant_id": "tenant-beta"
		}
	]`
	t.Setenv(EnvAccounts, raw)

	_, err := AccountsFromEnv()
	if err == nil {
		t.Fatal("AccountsFromEnv with missing external_id expected error, got nil")
	}
	want := "COLLECTOR_AWSLOGS_ACCOUNTS[1]: external_id is required"
	if !strings.Contains(err.Error(), want) {
		t.Errorf("error = %q, want it to contain %q", err.Error(), want)
	}
}

func TestAccountsFromEnv_MissingAccountID(t *testing.T) {
	raw := `[
		{
			"role_arn": "arn:aws:iam::111111111111:role/read-telemetry",
			"external_id": "ext-1",
			"queue_url": "https://sqs.us-east-1.amazonaws.com/111111111111/q1",
			"tenant_id": "tenant-alpha"
		}
	]`
	t.Setenv(EnvAccounts, raw)

	_, err := AccountsFromEnv()
	if err == nil {
		t.Fatal("AccountsFromEnv with missing account_id expected error, got nil")
	}
	want := "COLLECTOR_AWSLOGS_ACCOUNTS[0]: account_id is required"
	if !strings.Contains(err.Error(), want) {
		t.Errorf("error = %q, want it to contain %q", err.Error(), want)
	}
}

func TestAccountsFromEnv_MissingRoleARN(t *testing.T) {
	raw := `[
		{
			"account_id": "111111111111",
			"external_id": "ext-1",
			"queue_url": "https://sqs.us-east-1.amazonaws.com/111111111111/q1",
			"tenant_id": "tenant-alpha"
		}
	]`
	t.Setenv(EnvAccounts, raw)

	_, err := AccountsFromEnv()
	if err == nil {
		t.Fatal("AccountsFromEnv with missing role_arn expected error, got nil")
	}
	want := "COLLECTOR_AWSLOGS_ACCOUNTS[0]: role_arn is required"
	if !strings.Contains(err.Error(), want) {
		t.Errorf("error = %q, want it to contain %q", err.Error(), want)
	}
}

func TestAccountsFromEnv_MissingTenantID(t *testing.T) {
	raw := `[
		{
			"account_id": "111111111111",
			"role_arn": "arn:aws:iam::111111111111:role/read-telemetry",
			"external_id": "ext-1",
			"queue_url": "https://sqs.us-east-1.amazonaws.com/111111111111/q1"
		}
	]`
	t.Setenv(EnvAccounts, raw)

	_, err := AccountsFromEnv()
	if err == nil {
		t.Fatal("AccountsFromEnv with missing tenant_id expected error, got nil")
	}
	want := "COLLECTOR_AWSLOGS_ACCOUNTS[0]: tenant_id is required"
	if !strings.Contains(err.Error(), want) {
		t.Errorf("error = %q, want it to contain %q", err.Error(), want)
	}
}

func TestAccountsFromEnv_DuplicateAccountID(t *testing.T) {
	raw := `[
		{
			"account_id": "111111111111",
			"role_arn": "arn:aws:iam::111111111111:role/read-telemetry-1",
			"external_id": "ext-1",
			"queue_url": "https://sqs.us-east-1.amazonaws.com/111111111111/q1",
			"tenant_id": "tenant-alpha"
		},
		{
			"account_id": "111111111111",
			"role_arn": "arn:aws:iam::111111111111:role/read-telemetry-2",
			"external_id": "ext-2",
			"queue_url": "https://sqs.us-east-1.amazonaws.com/111111111111/q2",
			"tenant_id": "tenant-beta"
		}
	]`
	t.Setenv(EnvAccounts, raw)

	_, err := AccountsFromEnv()
	if err == nil {
		t.Fatal("AccountsFromEnv with duplicate account_id expected error, got nil")
	}
	msg := err.Error()
	if !strings.Contains(msg, "COLLECTOR_AWSLOGS_ACCOUNTS") || !strings.Contains(msg, "[0]") || !strings.Contains(msg, "[1]") || !strings.Contains(msg, "111111111111") {
		t.Errorf("error = %q, want it to name COLLECTOR_AWSLOGS_ACCOUNTS and indexes [0] and [1] and account_id", msg)
	}
}

func TestAccountsFromEnv_DuplicateQueueURL(t *testing.T) {
	raw := `[
		{
			"account_id": "111111111111",
			"role_arn": "arn:aws:iam::111111111111:role/read-telemetry-1",
			"external_id": "ext-1",
			"queue_url": "https://sqs.us-east-1.amazonaws.com/123456789012/shared-q",
			"tenant_id": "tenant-alpha"
		},
		{
			"account_id": "222222222222",
			"role_arn": "arn:aws:iam::222222222222:role/read-telemetry-2",
			"external_id": "ext-2",
			"queue_url": "https://sqs.us-east-1.amazonaws.com/123456789012/shared-q",
			"tenant_id": "tenant-beta"
		}
	]`
	t.Setenv(EnvAccounts, raw)

	_, err := AccountsFromEnv()
	if err == nil {
		t.Fatal("AccountsFromEnv with duplicate queue_url expected error, got nil")
	}
	msg := err.Error()
	if !strings.Contains(msg, "COLLECTOR_AWSLOGS_ACCOUNTS") || !strings.Contains(msg, "[0]") || !strings.Contains(msg, "[1]") || !strings.Contains(msg, "shared-q") {
		t.Errorf("error = %q, want it to name COLLECTOR_AWSLOGS_ACCOUNTS and indexes [0] and [1] and queue_url", msg)
	}
}

func TestAccountsFromEnv_EmptyEnv(t *testing.T) {
	t.Setenv(EnvAccounts, "")
	cfgs, err := AccountsFromEnv()
	if err != nil {
		t.Fatalf("AccountsFromEnv with empty env: unexpected error %v", err)
	}
	if cfgs != nil {
		t.Fatalf("AccountsFromEnv with empty env returned %v, want nil", cfgs)
	}
}

func TestAccountsFromEnv_RegionFallback(t *testing.T) {
	raw := `[
		{
			"account_id": "111111111111",
			"role_arn": "arn:aws:iam::111111111111:role/read-telemetry",
			"external_id": "ext-1",
			"queue_url": "https://sqs.us-east-1.amazonaws.com/111111111111/q1",
			"tenant_id": "tenant-alpha"
		}
	]`
	t.Setenv(EnvAccounts, raw)

	// Fallback to AWSLOGS_REGION when entry has no region.
	t.Setenv(EnvRegion, "eu-central-1")
	cfgs, err := AccountsFromEnv()
	if err != nil {
		t.Fatalf("AccountsFromEnv: %v", err)
	}
	if len(cfgs) != 1 || cfgs[0].Region != "eu-central-1" {
		t.Errorf("Region = %q, want eu-central-1 (from AWSLOGS_REGION)", cfgs[0].Region)
	}

	// Fallback to DefaultRegion when AWSLOGS_REGION is unset.
	t.Setenv(EnvRegion, "")
	cfgs, err = AccountsFromEnv()
	if err != nil {
		t.Fatalf("AccountsFromEnv: %v", err)
	}
	if len(cfgs) != 1 || cfgs[0].Region != DefaultRegion {
		t.Errorf("Region = %q, want %q (DefaultRegion)", cfgs[0].Region, DefaultRegion)
	}
}

func TestAccountsFromEnv_PerAccountBufferDir(t *testing.T) {
	raw := `[
		{
			"account_id": "111111111111",
			"role_arn": "arn:aws:iam::111111111111:role/read-telemetry",
			"external_id": "ext-1",
			"queue_url": "https://sqs.us-east-1.amazonaws.com/111111111111/q1",
			"tenant_id": "tenant-alpha"
		}
	]`
	t.Setenv(EnvAccounts, raw)
	t.Setenv(EnvBufferDir, "/tmp/custom-buffer")

	cfgs, err := AccountsFromEnv()
	if err != nil {
		t.Fatalf("AccountsFromEnv: %v", err)
	}
	want := filepath.Join("/tmp/custom-buffer", "111111111111")
	if cfgs[0].BufferDir != want {
		t.Errorf("BufferDir = %q, want %q", cfgs[0].BufferDir, want)
	}
}

func TestParseAccounts_InvalidJSON(t *testing.T) {
	_, err := ParseAccounts(`{ not valid json }`)
	if err == nil {
		t.Fatal("ParseAccounts on invalid JSON expected error, got nil")
	}
	if !strings.Contains(err.Error(), "COLLECTOR_AWSLOGS_ACCOUNTS") {
		t.Errorf("error = %q, want COLLECTOR_AWSLOGS_ACCOUNTS in message", err.Error())
	}
}
