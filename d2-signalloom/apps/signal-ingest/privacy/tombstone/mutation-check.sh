#!/usr/bin/env bash
# Mutation check for the tombstone package.
#
# Every control in this package claims to prevent something. This script breaks each control in
# turn and requires a NAMED test to go red. A control whose deletion changes nothing is not a
# control, and a green suite full of them reads exactly like a green suite full of real ones.
#
# Two failure modes this script is written to avoid:
#   - A `go test -run` pattern that matches no test exits 0 and would read as "the mutation
#     survived" — or, worse, as "the mutation was caught". Every expectation therefore asserts the
#     number of tests that actually ran.
#   - A harness killed mid-run leaves the working tree mutated. The trap restores on any exit.
#
# Usage: ./mutation-check.sh        (from the package directory)
set -eo pipefail

cd "$(dirname "$0")"
BACKUP="$(mktemp -d)"
cp tombstone.go signer.go "$BACKUP/"
restore() { cp "$BACKUP/tombstone.go" "$BACKUP/signer.go" ./; }
trap 'restore; rm -rf "$BACKUP"' EXIT INT TERM

GOFLAGS_ENV=(env "GOCACHE=${GOCACHE:-/tmp/gocache}" "GOMODCACHE=${GOMODCACHE:-/tmp/gomodcache}" CGO_ENABLED=0)

pass=0
fail=0

# apply <file> <old> <new> — asserts the pattern is present before replacing it, so a mutation that
# silently no-ops (because the code moved) cannot be scored as "survived".
apply() {
  local file="$1" old="$2" new="$3"
  python3 - "$file" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("MUTATION PATTERN MATCHED %d TIMES (want 1) in %s: %r\n" % (n, path, old[:80]))
    sys.exit(1)
open(path, "w").write(s.replace(old, new))
PY
}

# expect_red <label> <test-regex> <min-tests-that-must-run>
expect_red() {
  local label="$1" pattern="$2" want_min="$3" out rc ran
  set +e
  out="$("${GOFLAGS_ENV[@]}" go test . -count=1 -v -run "$pattern" 2>&1)"
  rc=$?
  set -e
  ran="$(printf '%s\n' "$out" | grep -c '^=== RUN   Test' || true)"
  if [ "$ran" -lt "$want_min" ]; then
    printf 'INCONCLUSIVE  %-52s (only %s tests matched %s; expected >= %s)\n' "$label" "$ran" "$pattern" "$want_min"
    fail=$((fail + 1))
    return
  fi
  if [ "$rc" -eq 0 ]; then
    printf 'SURVIVED      %-52s (%s tests ran, all passed)\n' "$label" "$ran"
    fail=$((fail + 1))
  else
    printf 'killed        %-52s (%s tests ran, %s failed)\n' "$label" "$ran" \
      "$(printf '%s\n' "$out" | grep -c -- '--- FAIL' || true)"
    pass=$((pass + 1))
  fi
}

# expect_survives <label> <reason> — for a defence that is genuinely redundant against the current
# type system and therefore CANNOT be killed by a test. Recording it as an expected survivor is
# honest; deleting it from the script would hide a known gap, and asserting it dies would be a lie.
expect_survives() {
  printf 'expected-survivor %-44s %s\n' "$1" "$2"
}

mutate() {
  local label="$1" file="$2" old="$3" new="$4" pattern="$5" want_min="$6"
  restore
  apply "$file" "$old" "$new"
  expect_red "$label" "$pattern" "$want_min"
  restore
}

echo "== tombstone mutation check =="

mutate "delete the k-anonymity threshold check" tombstone.go \
  'if req.BucketPopulation < MinAnonymitySet {' \
  'if false {' \
  'TestTombstonePopulationCheck' 1

mutate "relax the threshold comparison to <=" tombstone.go \
  'if req.BucketPopulation < MinAnonymitySet {' \
  'if req.BucketPopulation <= MinAnonymitySet {' \
  'TestTombstonePopulationCheck' 1

mutate "treat an unset population as checked" tombstone.go \
  'if req.BucketPopulation == 0 {' \
  'if false {' \
  'TestTombstonePopulationCheck' 1

mutate "publish the observed population, not the threshold" tombstone.go \
  'AnonymitySetMin:        MinAnonymitySet,' \
  'AnonymitySetMin:        req.BucketPopulation,' \
  'TestTombstonePublishesThresholdNotMeasurement|TestTombstoneSignAndVerify' 2

mutate "coarsen to the nanosecond instead of the day" tombstone.go \
  'return t.UTC().Format("2006-01-02")' \
  'return t.UTC().Format(time.RFC3339Nano)' \
  'TestTombstoneCoarsenDay|TestTombstoneNonJoinability|TestTombstoneProjectReceiptDropsSubject' 3

mutate "coarsen in local time rather than UTC" tombstone.go \
  'return t.UTC().Format("2006-01-02")' \
  'return t.Format("2006-01-02")' \
  'TestTombstoneCoarsenDay' 1

restore
apply tombstone.go \
  '		ReceiptCommitment:      ReceiptCommitment(nonce, projection),' \
  '		ReceiptCommitment:      hexOfSubjectOracle(nonce, req.TenantID, req.SubjectID, projection.KeysDestroyedBand, day),'
cat >> tombstone.go <<'GO'

// hexOfSubjectOracle is a MUTATION-ONLY construction reproducing SLDP-P4-PRE §6.2's receipt_digest.
func hexOfSubjectOracle(nonce []byte, tenant, subject, keys, day string) string {
	_ = nonce
	d := sha256.Sum256([]byte(fmt.Sprintf(`{"subject_id":%q,"tenant_id":%q,"keys_removed":%q,"destroyed_at":%q}`, subject, tenant, keys, day)))
	return hex.EncodeToString(d[:])
}
GO
expect_red "reinstate the P4-PRE subject-oracle digest" \
  'TestTombstoneNonJoinability|TestTombstoneReceiptCommitmentIsNotASubjectOracle|TestTombstoneLinkageProbeSurvivesRepeatedMints|TestTombstoneAdversaryHoldingEverythingLearnsOnlyTheCohort' 4
restore

mutate "make the confirmation commitment unkeyed" tombstone.go \
  '	mac := hmac.New(sha256.New, k[:])' \
  '	mac := hmac.New(sha256.New, []byte("static"))' \
  'TestTombstoneConfirmSpecificErasure|TestTombstoneCommitmentsAreFreshPerMint' 2

mutate "derive the tombstone id from the request id" tombstone.go \
  '		TombstoneID:            hex.EncodeToString(idBytes),' \
  '		TombstoneID:            hex.EncodeToString([]byte(req.RequestID))[:32],' \
  'TestTombstoneCommitmentsAreFreshPerMint' 1

mutate "let the confirmation key marshal" tombstone.go \
  'func (ConfirmationKey) MarshalJSON() ([]byte, error) { return nil, ErrConfirmationKeyNotSerialisable }' \
  'func (k ConfirmationKey) MarshalJSON() ([]byte, error) { return json.Marshal(hex.EncodeToString(k[:])) }' \
  'TestTombstoneConfirmationKeyIsNotSerialisable' 1

mutate "let the confirmation key print itself" tombstone.go \
  'func (ConfirmationKey) String() string { return "ConfirmationKey(redacted)" }' \
  'func (k ConfirmationKey) String() string { return hex.EncodeToString(k[:]) }' \
  'TestTombstoneConfirmationKeyIsNotSerialisable' 1

mutate "accept unknown fields in a document" tombstone.go \
  '			return fmt.Errorf("%w: %q", ErrForbiddenField, key)' \
  '			_ = key' \
  'TestTombstoneValidateDocumentRejectsExtraField|TestTombstoneSigningCannotLaunderAForbiddenField' 2

mutate "accept documents missing an allow-listed field" tombstone.go \
  '			return fmt.Errorf("%w: %q", ErrMissingField, f)' \
  '			_ = f' \
  'TestTombstoneValidateDocumentRejectsMissingField' 1

mutate "neuter the forbidden-name guard" tombstone.go \
  '	var bad []string
	for _, n := range names {' \
  '	var bad []string
	for _, n := range []string{} {
		_ = n
	}
	for _, n := range []string{} {' \
  'TestTombstoneForbiddenFieldGuardActuallyFires' 1

expect_survives "skip the allow-list check before signing" \
  "Statement marshals a Tombstone, which by construction emits only allow-listed keys, so this check is defence-in-depth against a future struct/allow-list divergence that TestTombstoneAllowListMatchesStruct already catches at test time. Not test-killable; kept for runtime."

mutate "skip the content check on a verified envelope" signer.go \
  '	if err := ValidateDocument(statement.Predicate); err != nil {
		return Tombstone{}, fmt.Errorf("verified envelope carries an invalid tombstone: %w", err)
	}' \
  '	_ = statement.Predicate' \
  'TestTombstoneSigningCannotLaunderAForbiddenField' 1

mutate "accept any keyid" signer.go \
  '	if expectKeyID != "" && env.Signatures[0].KeyID != expectKeyID {' \
  '	if false {' \
  'TestTombstoneVerifyEnvelopeRejections' 1

mutate "accept a non-Ed25519 signing key" signer.go \
  '	priv, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("%w: got %T", ErrNotEd25519, parsed)
	}' \
  '	priv, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		priv = ed25519.NewKeyFromSeed(make([]byte, 32))
	}' \
  'TestTombstoneSignerRefusesBadKeys' 1

mutate "skip the generation range check" tombstone.go \
  '	if req.KeyGenerationFirst > req.KeyGenerationLast {' \
  '	if false {' \
  'TestTombstoneMintRefusesInvalidRequests' 1

mutate "return a populated tombstone alongside a refusal" tombstone.go \
  '		return Tombstone{}, zeroKey, fmt.Errorf("%w: bucket population is %d, below the minimum anonymity set of %d; publishing would identify the subject by elimination",
			ErrAnonymitySetTooSmall, req.BucketPopulation, MinAnonymitySet)' \
  '		return Tombstone{SchemaVersion: SchemaVersion, TenantID: req.TenantID}, zeroKey, fmt.Errorf("%w: bucket population is %d, below the minimum anonymity set of %d; publishing would identify the subject by elimination",
			ErrAnonymitySetTooSmall, req.BucketPopulation, MinAnonymitySet)' \
  'TestTombstonePopulationCheck' 1

mutate "publish the exact key count instead of its band" tombstone.go \
  'band := BandKeysDestroyed(req.KeysDestroyed)' \
  'band := fmt.Sprintf("%d", req.KeysDestroyed)' \
  'TestTombstoneKeysDestroyedIsBanded|TestTombstoneSignAndVerify|TestTombstoneNonJoinability' 3

mutate "collapse two bands into one" tombstone.go \
  '	case n <= 5:
		return "2-5"' \
  '	case n <= 5:
		return "1"' \
  'TestTombstoneKeysDestroyedIsBanded' 1

mutate "publish the raw generation range instead of its epoch band" tombstone.go \
  'genLo, genHi := CoarsenGenerationRange(req.KeyGenerationFirst, req.KeyGenerationLast)' \
  'genLo, genHi := req.KeyGenerationFirst, req.KeyGenerationLast' \
  'TestTombstoneGenerationRangeIsEpochCoarsened|TestTombstoneSignAndVerify|TestTombstoneMintAcceptsASingleGeneration' 3

mutate "drop the epoch-alignment check from Validate" tombstone.go \
  'if t.KeyGenerationFirst%GenerationEpochSize != 1 || t.KeyGenerationLast%GenerationEpochSize != 0 {' \
  'if false {' \
  'TestTombstoneGenerationRangeIsEpochCoarsened' 1

mutate "let an unpublished field into the receipt projection" tombstone.go \
  '	DestroyedDay       string `json:"erased_day"`' \
  '	DestroyedDay       string `json:"destroyed_day_internal"`' \
  'TestTombstoneProjectionIsASubsetOfPublishedFields' 1

echo
echo "killed=$pass survived_or_inconclusive=$fail"
[ "$fail" -eq 0 ]
