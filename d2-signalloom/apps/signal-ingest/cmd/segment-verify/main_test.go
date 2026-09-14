package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

func TestVerifyCLIRequiresExplicitCorpusPaths(t *testing.T) {
	var stdout, stderr bytes.Buffer
	err := run(context.Background(), nil, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "requires evidence directory") {
		t.Fatalf("expected explicit-path error, got %v", err)
	}
	if stdout.Len() != 0 {
		t.Fatalf("unexpected output: %s", stdout.String())
	}
}

func TestVerifyCLIRejectsPositionalRepositoryPath(t *testing.T) {
	var stdout, stderr bytes.Buffer
	err := run(context.Background(), []string{"."}, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "flags only") {
		t.Fatalf("expected flags-only error, got %v", err)
	}
}
