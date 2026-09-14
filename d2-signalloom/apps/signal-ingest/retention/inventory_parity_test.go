// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package retention

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

// This file is the answer to the one way this whole control could ship green and useless.
//
// The sink set is the DENOMINATOR of every coverage figure and every overdue count. An authored set
// that drifts from the inventory documents does not present as a hole — it presents as HIGHER
// coverage, because a forgotten copy lowers the denominator. And the overdue gauge iterates the
// outstanding set, which is built from the enumeration, so a copy never enumerated can never go
// overdue: the strongest correcting loop in the design is blind to exactly the failure that defeats it.
//
// So the expectation here is DERIVED BY PARSING the upstream documents, never copied from the Go
// table. If either document gains a row AllSinkSpecs does not carry, these tests fail. An earlier
// draft of this package read "15" from a windowed extract of a document that has 23 numbered rows and
// would have shipped with twenty copies unevaluated and the gauge reading zero.

// stripSQLComments removes `--` line comments, leaving only statement text.
func stripSQLComments(sql string) string {
	var b strings.Builder
	for _, line := range strings.Split(sql, "\n") {
		if idx := strings.Index(line, "--"); idx >= 0 {
			line = line[:idx]
		}
		b.WriteString(line)
		b.WriteString("\n")
	}
	return b.String()
}

// docRoot locates docs/signalloom relative to the package directory.
func docRoot(t *testing.T) string {
	t.Helper()
	root := filepath.Join("..", "..", "..", "..", "docs", "signalloom")
	if _, err := os.Stat(root); err != nil {
		t.Fatalf("cannot locate docs/signalloom from the package directory: %v", err)
	}
	return root
}

var numberedRowRe = regexp.MustCompile(`^\|\s*\*{0,2}(\d+)\*{0,2}\s*\|\s*` + "`?" + `([^|` + "`" + `]+)`)

// parseP6PRERows parses the numbered rows of SLDP-P6-PRE §3.
func parseP6PRERows(t *testing.T) map[int]string {
	t.Helper()
	path := filepath.Join(docRoot(t), "sldp-p6-pre-proof.md")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	rows := make(map[int]string)
	for _, line := range strings.Split(string(raw), "\n") {
		m := numberedRowRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		n, err := strconv.Atoi(m[1])
		if err != nil {
			continue
		}
		if _, seen := rows[n]; !seen {
			rows[n] = strings.TrimSpace(m[2])
		}
	}
	return rows
}

// p0SectionHeading is the exact heading of the P0 storage-copy inventory.
const p0SectionHeading = "## Personal-data storage-copy inventory"

// parseP0Rows parses the leading cell of every row in the P0 inventory table.
func parseP0Rows(t *testing.T) []string {
	t.Helper()
	path := filepath.Join(docRoot(t), "sldp-p0-boundary-map.md")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	lines := strings.Split(string(raw), "\n")
	start := -1
	for i, l := range lines {
		if strings.TrimSpace(l) == p0SectionHeading {
			start = i
			break
		}
	}
	if start < 0 {
		t.Fatalf("%s no longer contains the heading %q; the parity check has lost its source of truth", path, p0SectionHeading)
	}
	var out []string
	for _, l := range lines[start+1:] {
		trimmed := strings.TrimSpace(l)
		if strings.HasPrefix(trimmed, "## ") {
			break
		}
		if !strings.HasPrefix(trimmed, "|") {
			continue
		}
		cells := strings.Split(trimmed, "|")
		if len(cells) < 3 {
			continue
		}
		first := strings.TrimSpace(cells[1])
		if first == "" || first == "Sink or copy" || strings.HasPrefix(first, "---") {
			continue
		}
		out = append(out, first)
	}
	return out
}

// TestRetentionInventory_P6PRERowCountIsDerivedNotAsserted proves the pinned constant matches the
// document.
//
// Two independently-derived numbers, which is the point: comparing AllSinkSpecs against a `required`
// list built from AllSinkSpecs is a tautology that passes while blind. This compares the Go constant
// against a count obtained by parsing the markdown.
func TestRetentionInventory_P6PRERowCountIsDerivedNotAsserted(t *testing.T) {
	rows := parseP6PRERows(t)
	if len(rows) != P6PREInventoryRows {
		t.Fatalf("SLDP-P6-PRE §3 has %d numbered rows, P6PREInventoryRows says %d. "+
			"If the document gained a row, AllSinkSpecs needs a matching sink; the denominator is the control.",
			len(rows), P6PREInventoryRows)
	}
	if len(rows) == 15 {
		t.Fatalf("parsed exactly 15 rows, which is the count an earlier draft read from a windowed extract; " +
			"re-check the parser before trusting this")
	}
}

// TestRetentionInventory_EveryP6PRERowHasASink fails when the document carries a row the Go table does
// not.
func TestRetentionInventory_EveryP6PRERowHasASink(t *testing.T) {
	rows := parseP6PRERows(t)
	specs := AllSinkSpecs()

	covered := make(map[int]string)
	for _, s := range specs {
		if s.P6PRERow == 0 {
			continue
		}
		if prior, dup := covered[s.P6PRERow]; dup {
			t.Errorf("P6-PRE row %d is claimed by both %q and %q", s.P6PRERow, prior, s.ID)
		}
		covered[s.P6PRERow] = s.ID
	}
	for n, name := range rows {
		if _, ok := covered[n]; !ok {
			t.Errorf("SLDP-P6-PRE §3 row %d (%q) has no sink in AllSinkSpecs; it would never be swept and never go overdue", n, name)
		}
	}
	for n, id := range covered {
		if _, ok := rows[n]; !ok {
			t.Errorf("sink %q claims P6-PRE row %d, which the document does not have", id, n)
		}
	}
	if len(covered) != P6PREInventoryRows {
		t.Errorf("AllSinkSpecs covers %d of %d P6-PRE rows", len(covered), P6PREInventoryRows)
	}
}

// TestRetentionInventory_EveryP0RowHasASink fails when the P0 boundary map carries a copy the Go table
// does not.
//
// This is the test that would have caught the real defect. The P6-PRE reconciliation dropped nine P0
// rows — the portal audit_events table, audit-anchor local output, Rekor, the segment-attestor queues,
// the identity event bus, Redis, MinIO, backups/snapshots and application/container logs. Building
// against P6-PRE alone would have left all nine with a gauge reading zero.
func TestRetentionInventory_EveryP0RowHasASink(t *testing.T) {
	rows := parseP0Rows(t)
	if len(rows) != P0InventoryRows {
		t.Fatalf("P0 inventory has %d rows, P0InventoryRows says %d", len(rows), P0InventoryRows)
	}
	claimed := make(map[string]string)
	for _, s := range AllSinkSpecs() {
		if s.P0Row == "" {
			continue
		}
		if prior, dup := claimed[s.P0Row]; dup {
			t.Errorf("P0 row %q is claimed by both %q and %q", s.P0Row, prior, s.ID)
		}
		claimed[s.P0Row] = s.ID
	}
	for _, row := range rows {
		if _, ok := claimed[row]; !ok {
			t.Errorf("SLDP-P0 storage-copy inventory row %q has no sink in AllSinkSpecs; "+
				"a copy nobody enumerates is a copy the overdue gauge reports as zero", row)
		}
	}
	for row, id := range claimed {
		found := false
		for _, r := range rows {
			if r == row {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("sink %q claims P0 row %q, which the document does not have (verbatim match required)", id, row)
		}
	}
}

// TestRetentionInventory_UnionIsStrictlyLargerThanEitherDocument records the finding structurally.
func TestRetentionInventory_UnionIsStrictlyLargerThanEitherDocument(t *testing.T) {
	specs := AllSinkSpecs()
	var p6Only, p0Only, both, cardOnly int
	for _, s := range specs {
		switch {
		case s.P6PRERow > 0 && s.P0Row != "":
			both++
		case s.P6PRERow > 0:
			p6Only++
		case s.P0Row != "":
			p0Only++
		case s.CardNamed:
			cardOnly++
		default:
			t.Errorf("sink %q has no provenance: it is in neither document and is not CardNamed", s.ID)
		}
	}
	if p0Only == 0 {
		t.Error("no sink is P0-only, which would mean the P6-PRE reconciliation dropped nothing; it dropped nine rows")
	}
	if cardOnly == 0 {
		t.Error("no sink is CardNamed, so the card's queue/snapshot/backup/export classes are unrepresented")
	}
	if len(specs) <= P6PREInventoryRows {
		t.Errorf("union has %d sinks, no larger than P6-PRE's %d; the union is the honest denominator", len(specs), P6PREInventoryRows)
	}
	t.Logf("inventory provenance: %d in both documents, %d P6-PRE-only, %d P0-only (dropped by the reconciliation), %d card-named, %d total",
		both, p6Only, p0Only, cardOnly, len(specs))
}

// TestRetentionInventory_SpecsAreWellFormed asserts every spec is complete, unique and bounded.
func TestRetentionInventory_SpecsAreWellFormed(t *testing.T) {
	seen := make(map[string]struct{})
	for _, s := range AllSinkSpecs() {
		if s.ID == "" {
			t.Fatal("a sink spec has an empty ID")
		}
		if _, dup := seen[s.ID]; dup {
			t.Errorf("duplicate sink ID %q", s.ID)
		}
		seen[s.ID] = struct{}{}

		if !s.Class.Valid() {
			t.Errorf("sink %q has invalid class %q", s.ID, s.Class)
		}
		switch s.Reach {
		case ReachInProcess, ReachExternalAttestation, ReachContinuityBearing:
		default:
			t.Errorf("sink %q has invalid reach %q", s.ID, s.Reach)
		}
		if s.DefaultPeriod <= 0 {
			t.Errorf("sink %q has a non-positive default period %s; that is unlimited retention with a number attached", s.ID, s.DefaultPeriod)
		}
		if s.DefaultPeriod > MaxRetentionPeriod {
			t.Errorf("sink %q default period %s exceeds MaxRetentionPeriod %s", s.ID, s.DefaultPeriod, MaxRetentionPeriod)
		}
		if s.DefaultPeriod < MinRetentionPeriod {
			t.Errorf("sink %q default period %s is below MinRetentionPeriod %s", s.ID, s.DefaultPeriod, MinRetentionPeriod)
		}
		if s.Residual == "" {
			t.Errorf("sink %q declares no residual; silence about residue reads as 'nothing survives', which is false for every Postgres row", s.ID)
		}
		if s.Notes == "" {
			t.Errorf("sink %q has no notes explaining its classification", s.ID)
		}
	}
}

// TestRetentionInventory_EveryClassIsRepresented asserts the card's named copy classes all appear.
func TestRetentionInventory_EveryClassIsRepresented(t *testing.T) {
	present := make(map[SinkClass]int)
	for _, s := range AllSinkSpecs() {
		present[s.Class]++
	}
	// The card's approach names "primary stores, transparency artefacts, queues, caches, snapshots,
	// backups and exports". All seven must be represented or the inventory does not cover what was asked.
	for _, class := range allClasses {
		if present[class] == 0 {
			t.Errorf("no sink has class %q; the card names it explicitly", class)
		}
	}
}

// TestRetentionInventory_LinkageSinksExistAndAreShortest asserts the continuity resolution's premise.
//
// The whole retention-versus-continuity argument rests on the linkage copies expiring sooner than the
// attested bytes they make resolvable. If a linkage period were the longer one, a retained token would
// stay linkable for years after its segment's own period elapsed and the receipt's claim would be false.
func TestRetentionInventory_LinkageSinksExistAndAreShortest(t *testing.T) {
	linkage := LinkageSinksFor("parquet_segment_objects")
	if len(linkage) != 2 {
		t.Fatalf("expected 2 linkage sinks, got %d: %v", len(linkage), linkage)
	}
	for _, id := range linkage {
		spec, ok := SpecByID(id)
		if !ok {
			t.Fatalf("linkage sink %q is not in the inventory", id)
		}
		if spec.Reach != ReachInProcess {
			t.Errorf("linkage sink %q has reach %q; it must be purgeable in-process or the continuity resolution is unenforceable", id, spec.Reach)
		}
		if spec.DefaultPeriod != DefaultLinkagePeriod {
			t.Errorf("linkage sink %q period is %s, want DefaultLinkagePeriod %s", id, spec.DefaultPeriod, DefaultLinkagePeriod)
		}
	}
	segment, ok := SpecByID("parquet_segment_objects")
	if !ok {
		t.Fatal("parquet_segment_objects missing from the inventory")
	}
	if DefaultLinkagePeriod >= segment.DefaultPeriod {
		t.Fatalf("linkage period %s is not shorter than the segment period %s; a retained token would stay linkable after its own period elapsed",
			DefaultLinkagePeriod, segment.DefaultPeriod)
	}
}

// TestRetentionInventory_ContinuitySinksNeverUnlinkAnything is the anti-criterion for the hard blocker.
//
// The declared hard blocker is any change that would make an existing attested segment or checkpoint
// fail verification. verify.go:203 re-reads each segment's bytes and verify.go:650-656 demands
// set-equality of the on-disk inventory against journal ∪ historical, so unlinking one expired segment
// turns VerifyCorpus into a hard error. This asserts structurally that no continuity-bearing sink can
// delete: its Purge takes no filesystem dependency at all, and the only way it reports success is by
// finding completed linkage receipts.
func TestRetentionInventory_ContinuitySinksNeverUnlinkAnything(t *testing.T) {
	source, err := os.ReadFile("sink.go")
	if err != nil {
		t.Fatalf("read sink.go: %v", err)
	}
	body := string(source)
	start := strings.Index(body, "func (s *continuitySink) Purge(")
	if start < 0 {
		t.Fatal("continuitySink.Purge not found; this guard has lost its subject and would pass vacuously")
	}
	end := strings.Index(body[start:], "\n}\n")
	if end < 0 {
		t.Fatal("cannot delimit continuitySink.Purge")
	}
	purgeBody := body[start : start+end]
	for _, forbidden := range []string{"os.Remove", "os.RemoveAll", "os.Truncate", "os.WriteFile", "os.Create", "os.Rename"} {
		if strings.Contains(purgeBody, forbidden) {
			t.Errorf("continuitySink.Purge references %s; deleting attested bytes fails VerifyCorpus at verify.go:203 and verify.go:654", forbidden)
		}
	}

	// And behaviourally: with no completed linkage receipts, it must report unreachable rather than a
	// disposition it has not earned.
	ledger := NewMemoryLedger()
	spec, _ := SpecByID("parquet_segment_objects")
	sink, err := NewContinuitySink(spec, LinkageSinksFor(spec.ID), LinkageLookup(ledger))
	if err != nil {
		t.Fatalf("NewContinuitySink: %v", err)
	}
	if _, err := sink.Purge(t.Context(), PurgeRequest{TenantID: "t1", Before: time.Now()}); err == nil {
		t.Fatal("continuity sink reported success with no completed linkage purges; that is indefinite retention with a compliant label")
	} else if !strings.Contains(err.Error(), "unreachable") {
		t.Errorf("expected an unreachable error, got %v", err)
	}
}

// TestRetentionInventory_MigrationIsAdditiveAndCarriesRLS checks migration 010 statically.
func TestRetentionInventory_MigrationIsAdditiveAndCarriesRLS(t *testing.T) {
	path := filepath.Join("..", "identity", "migrations", "010_retention_receipts.sql")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	sql := string(raw)

	required := []string{
		"CREATE TABLE IF NOT EXISTS retention_deletion_receipts",
		"ENABLE ROW LEVEL SECURITY",
		"FORCE ROW LEVEL SECURITY",
		"CREATE POLICY retention_deletion_receipts_tenant_isolation",
		"app_current_tenant()",
		"operation_id         TEXT        PRIMARY KEY",
		"TIMESTAMPTZ",
		"retention_receipts_disposition_enumerated",
		"retention_receipts_no_removal_without_purge",
		"retention_receipts_completion_matches_disposition",
		"retention_receipts_retained_token_names_linkage",
	}
	for _, want := range required {
		if !strings.Contains(sql, want) {
			t.Errorf("migration 010 is missing %q", want)
		}
	}
	// Additive: no destructive statement against anything that pre-existed.
	//
	// Scanned against the STATEMENTS, not the file. The first version of this guard scanned the raw
	// text and failed on the word "truncates" inside a comment explaining microsecond truncation — a
	// guard reading prose as data. Stripping `--` comments first is the fix; rewording the comment to
	// appease the guard would have left the guard wrong.
	for _, forbidden := range []string{"DROP TABLE", "DROP COLUMN", "ALTER COLUMN", "TRUNCATE"} {
		if strings.Contains(strings.ToUpper(stripSQLComments(sql)), forbidden) {
			t.Errorf("migration 010 contains %q; this card is additive-only", forbidden)
		}
	}
	// Prove the stripper has not eaten the statements it is meant to leave behind. Without this, a
	// stripper that returned "" would silently make every forbidden-token check pass.
	if !strings.Contains(strings.ToUpper(stripSQLComments(sql)), "CREATE TABLE IF NOT EXISTS RETENTION_DELETION_RECEIPTS") {
		t.Fatal("stripSQLComments removed the CREATE TABLE statement; the additive check above would pass vacuously")
	}
	// Every disposition the Go enum knows must be admitted by the CHECK constraint, or a legal receipt
	// would be rejected at the boundary at runtime and only there.
	for _, d := range allDispositions {
		if !strings.Contains(sql, fmt.Sprintf("'%s'", string(d))) {
			t.Errorf("migration 010's disposition CHECK does not admit %q", d)
		}
	}
}
