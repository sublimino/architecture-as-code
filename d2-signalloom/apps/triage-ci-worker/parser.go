package main

import (
	"fmt"
	"regexp"
	"strings"
)

// TestFailure represents a single test failure extracted from CI logs.
type TestFailure struct {
	Name   string `json:"name"`
	Detail string `json:"detail"`
}

var (
	// Go test output: --- FAIL: TestName (duration)
	goFailRe = regexp.MustCompile(`^--- FAIL: (\S+)`)
	// Go test detail line: indented file:line: message
	goDetailRe = regexp.MustCompile(`^\s+(\S+\.go:\d+: .+)`)
	// Pytest output: FAILED path::test_name - reason
	pytestFailRe = regexp.MustCompile(`^FAILED (\S+)\s*-\s*(.+)`)
)

// ParseFailures extracts test failures from CI build log output.
// Supports Go test and pytest formats.
func ParseFailures(log string) []TestFailure {
	if log == "" {
		return nil
	}

	var failures []TestFailure
	lines := strings.Split(log, "\n")

	for i := 0; i < len(lines); i++ {
		line := lines[i]

		// Go test failure
		if m := goFailRe.FindStringSubmatch(line); m != nil {
			f := TestFailure{Name: m[1]}
			// Look ahead for detail
			if i+1 < len(lines) {
				if d := goDetailRe.FindStringSubmatch(lines[i+1]); d != nil {
					f.Detail = strings.TrimSpace(d[1])
				}
			}
			failures = append(failures, f)
			continue
		}

		// Pytest failure
		if m := pytestFailRe.FindStringSubmatch(line); m != nil {
			failures = append(failures, TestFailure{
				Name:   m[1],
				Detail: strings.TrimSpace(m[2]),
			})
			continue
		}
	}

	return failures
}

// DeduplicateFlaky separates known flaky tests from real failures.
func DeduplicateFlaky(failures []TestFailure, knownFlaky []string) (real, flaky []TestFailure) {
	flakySet := make(map[string]bool, len(knownFlaky))
	for _, name := range knownFlaky {
		flakySet[name] = true
	}

	for _, f := range failures {
		if flakySet[f.Name] {
			flaky = append(flaky, f)
		} else {
			real = append(real, f)
		}
	}
	return
}

const (
	maxDisplayedFailures = 50
	maxCommentLength     = 60000
)

// FormatTriageComment builds a GitHub-flavored markdown triage comment with bounded output.
func FormatTriageComment(real, flaky []TestFailure) string {
	var b strings.Builder

	b.WriteString("## CI Triage Report\n\n")

	if len(real) > 0 {
		b.WriteString(fmt.Sprintf("### %d Real Failure(s)\n\n", len(real)))
		limit := len(real)
		if limit > maxDisplayedFailures {
			limit = maxDisplayedFailures
		}
		for i := 0; i < limit; i++ {
			f := real[i]
			b.WriteString(fmt.Sprintf("- **%s**", f.Name))
			if f.Detail != "" {
				b.WriteString(fmt.Sprintf(": `%s`", f.Detail))
			}
			b.WriteString("\n")
		}
		if len(real) > limit {
			b.WriteString(fmt.Sprintf("\n> ... and %d more real failure(s) omitted\n", len(real)-limit))
		}
		b.WriteString("\n")
	}

	if len(flaky) > 0 {
		b.WriteString(fmt.Sprintf("### %d Known Flaky Test(s) (suppressed)\n\n", len(flaky)))
		limit := len(flaky)
		if limit > maxDisplayedFailures {
			limit = maxDisplayedFailures
		}
		for i := 0; i < limit; i++ {
			f := flaky[i]
			b.WriteString(fmt.Sprintf("- ~%s~", f.Name))
			if f.Detail != "" {
				b.WriteString(fmt.Sprintf(": `%s`", f.Detail))
			}
			b.WriteString("\n")
		}
		if len(flaky) > limit {
			b.WriteString(fmt.Sprintf("\n> ... and %d more flaky test(s) omitted\n", len(flaky)-limit))
		}
		b.WriteString("\n")
	}

	if len(real) == 0 && len(flaky) > 0 {
		b.WriteString("> All failures are known flaky tests. No action required.\n")
	}

	res := b.String()
	if len(res) > maxCommentLength {
		truncBanner := "\n\n> [!NOTE]\n> Triage report truncated to fit GitHub comment length constraints.\n"
		cut := maxCommentLength - len(truncBanner)
		if cut > 0 && cut < len(res) {
			res = res[:cut] + truncBanner
		}
	}

	return res
}

// SuggestLabels returns triage labels based on failure analysis.
func SuggestLabels(real, flaky []TestFailure) []string {
	var labels []string

	labels = append(labels, "triage:ci-failure")

	if len(real) > 0 {
		labels = append(labels, "triage:real-failure")
	}
	if len(flaky) > 0 {
		labels = append(labels, "triage:known-flaky")
	}
	if len(real) == 0 && len(flaky) > 0 {
		labels = append(labels, "triage:flaky-only")
	}

	return labels
}
