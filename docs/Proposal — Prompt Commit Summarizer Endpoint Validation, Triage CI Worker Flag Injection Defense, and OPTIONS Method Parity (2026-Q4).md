# Proposal: Prompt Commit Summarizer Endpoint Validation, Triage CI Worker Flag Injection Defense, and OPTIONS Method Parity

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/prompt-commit-summarizer/main.go`, `d2-signalloom/apps/triage-ci-worker/main.go`

## Executive Summary

This proposal hardens the prompt commit summarizer and the triage CI worker microservices.
It prevents server-side request forgery by validating language model endpoint URL schemes and hostnames.
It drains HTTP response bodies to enable reliable connection reuse.
It eliminates command line flag injection vulnerabilities in external tool invocations.
It adds complete RFC 9110 Section 9.3.7 OPTIONS method handling across both services.

## Problem Statement

Automated security sweeps identified four implementation issues across `prompt-commit-summarizer` and `triage-ci-worker`:

1. `prompt-commit-summarizer` passed unvalidated language model endpoints to HTTP requests.
Arbitrary schemes such as file or ftp could trigger unexpected local operations.
2. The summarizer did not drain HTTP response bodies before closing connections.
Undrained streams prevent HTTP connection reuse and exhaust socket descriptors under load.
3. `triage-ci-worker` invoked the GitHub command line tool with unvalidated repository names and labels.
Values with leading hyphens could be interpreted as command line flags.
Non-positive pull request numbers were processed without validation.
4. Both services rejected RFC 9110 Section 9.3.7 OPTIONS requests with HTTP 405 Method Not Allowed.

## Proposed Changes

### 1. Prompt Commit Summarizer Endpoint Validation

In `d2-signalloom/apps/prompt-commit-summarizer/main.go`:
- Validate language model endpoints using `url.Parse`.
- Require the scheme to be `http` or `https`.
- Require a non-empty hostname.
- Reject unparseable or disallowed URLs with a descriptive error.

### 2. HTTP Connection Body Draining

In `d2-signalloom/apps/prompt-commit-summarizer/main.go`:
- In `callLLM`, read and discard remaining response bytes up to 4096 bytes before closing the response body.
- Ensure socket descriptors return to the connection pool cleanly.

### 3. Triage CI Worker Flag Injection Defense

In `d2-signalloom/apps/triage-ci-worker/main.go`:
- Validate that the pull request number is strictly positive.
- Validate that the repository identifier contains an owner and repository name separated by a single slash.
- Reject repository names or label strings that begin with a hyphen or dash.
- Filter invalid labels before constructing arguments for command execution.

### 4. RFC 9110 OPTIONS Method Handling

Across both microservices:
- In `prompt-commit-summarizer`, handle OPTIONS requests on `/` by returning HTTP 204 No Content with `Allow: POST, OPTIONS`.
- In `prompt-commit-summarizer`, handle OPTIONS requests on probe routes by returning HTTP 204 with `Allow: GET, HEAD, OPTIONS`.
- In `triage-ci-worker`, handle OPTIONS requests on `/` by returning HTTP 204 with `Allow: POST, OPTIONS`.
- In `triage-ci-worker`, handle OPTIONS requests on probe routes by returning HTTP 204 with `Allow: GET, HEAD, OPTIONS`.
- Preserve existing Allow header values on HTTP 405 Method Not Allowed responses to maintain test suite compatibility.

## Verification Plan

Verify the changes with automated test suites:
- Run `go test -v .` in `d2-signalloom/apps/prompt-commit-summarizer`.
- Run `go test -v .` in `d2-signalloom/apps/triage-ci-worker`.
- Validate documentation sync using `bats test/docs-index-sync.bats`.
- Validate documentation style using `scripts/docs-lint.sh`.
