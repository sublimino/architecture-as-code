# SLDP-P5-PRE — Phase 5 Preflight Proof

**Card:** SLDP-P5-PRE (preflight) · **Depends on:** P4-GOV · **Status:** pass
**Worktree:** `/home/andy/.cline/worktrees/a0208/osramp-demo` (detached, base `integration/sldp-v0.1.0`)
**Base commit at start of run:** `8264303581c548f5d1be49a0f4f4d57dceb9a4f4`
**Executed:** 2026-09-14

Phase 5 is the one preflight carrying a genuine unknown: whether Witness accepts a
KMS-backed signer at all. P5-1 is planned on the assumption that it does. This card
prototyped it before the phase starts, because a negative answer changes the design
rather than the estimate.

**The headline: the answer is YES, and P5-1's premise survives — but three of the
card's own stated assumptions are refuted by evidence, and each one changes P5-1's
shape.** They are set out in §2, §4 and §5 below.

---

## 1. Baseline and worktree gate

| Check | Command | Result |
| :--- | :--- | :--- |
| Worktree clean | `git status --porcelain \| wc -l` | `0` |
| Derives from integration branch | `git merge-base --is-ancestor integration/sldp-v0.1.0 HEAD` | exit 0 |
| Required store suite | `cd d2-signalloom/apps/signal-ingest && go test ./store/...` | `ok … 4.397s`, exit 0 |
| Go toolchain | `go version` | `go1.26.2 linux/amd64` |
| Module proxy reachable | `curl … proxy.golang.org` | `http=200` |

`store/verify` reports `[no test files]`. The package is exercised indirectly through
`store` and through `cmd/segment-verify/main_test.go`, but it carries no direct unit
tests of its own. Recorded, not fixed — it is outside this card's boundary.

**Concurrency note.** `integration/sldp-v0.1.0` advanced during this run, from
`8264303581c548f5d1be49a0f4f4d57dceb9a4f4` to
`300adb49cad80f5b3f82e3e8b0e37ce69855a341`, a fast-forward of one commit
(`300adb49 chore(signalloom): record controller tick 88 in governor log`). This
worktree's HEAD remains an ancestor of the new tip, so there is no divergence and no
conflict. Recorded because a preflight that reports a base SHA without checking
whether it still holds is reporting a guess.

---

## 2. The KMS signer prototype — verdict and evidence

### 2.1 What "Witness" actually means in this repository

The card's phrasing assumes one Witness. There are two, and they do not overlap.

| Surface | What signs | What verifies | Witness involved? |
| :--- | :--- | :--- | :--- |
| **Container promotion policy** | `witness` CLI, pinned `WITNESS_VERSION="0.9.1"` (`scripts/setup.sh:33`) | `witness verify` (`scripts/promotion-demo.sh:30`) | **Yes** — the real CLI |
| **FrostDB Parquet segment attestation** | hand-rolled `ed25519Signer` (`store/segment_attestor.go:182-224`) | in-repo `store/verify.VerifyCorpus`, driven by `cmd/segment-verify` | **No** |

`go-witness` is **absent from `d2-signalloom/apps/signal-ingest/go.mod`** — verified
directly. The segment attestor builds its own DSSE envelope from `crypto/ed25519`,
`encoding/pem` and `crypto/x509`. Nothing in the segment path imports or shells out
to Witness.

> **This contradicts a claim in an earlier proposal.** `docs/Proposal — Signal Fusion
> Actor-Resolution Spine (2026-Q3).md:93` states each segment is signed "via the
> in-process `go-witness` SDK". It is not. P5-1 must be sized as *adding* a
> dependency, not configuring an existing one.

`witness` is also **not on `PATH`** in this environment, so the CLI could not be
exercised end to end. The prototype therefore targets **`go-witness v0.8.4`, which is
the library `witness v0.9.1` is built from** — confirmed by reading
`https://raw.githubusercontent.com/in-toto/witness/v0.9.1/go.mod`, line 9:
`github.com/in-toto/go-witness v0.8.4`. This is the closest honest approximation to
"end to end"; §7 states the limit explicitly.

### 2.2 Prototype

Source: `docs/signalloom/sldp-p5-pre-kms-probe/main.go` (committed alongside this
proof). Compiles and runs against `go-witness v0.8.4`.

### 2.3 Verdict — **Witness DOES accept a KMS-backed signer**

```
## A. Does go-witness expose a KMS signer provider at all?
A1 gcpkms provider registered = true
A2 gcpkms algorithms  = [rsa-pkcs1v15-2048-sha256 rsa-pkcs1v15-3072-sha256
                         rsa-pkcs1v15-4096-sha256 rsa-pkcs1v15-4096-sha512
                         rsa-pss-2048-sha256 rsa-pss-3072-sha256
                         rsa-pss-4096-sha256 ecdsa-p256-sha256
                         ecdsa-p384-sha384 rsa-pss-4096-sha512]
A3 gcpkms contains ed25519 = false
A4 awskms provider registered = true
A5 awskms algorithms  = [RSA_2048 RSA_3072 RSA_4096
                         ECC_NIST_P256 ECC_NIST_P384 ECC_NIST_P521]
A6 awskms contains ed25519 = false

## B. Is the KMS signer code path reachable without cloud credentials?
B2 gcpkms Signer(ctx) err=new gcp kms client: credentials: could not find
   default credentials.
B4 awskms Signer(ctx) err=kms specification should be in the format
   awskms://[ENDPOINT]/[ID/ALIAS/ARN] (endpoint optional)

## C. Unknown-scheme behaviour (fail-closed check)
C1 azurekeyvault Signer(ctx) err=no kms provider found for key reference:
   azurekeyvault://vault/key
```

`go-witness/signer/kms/` ships `aws` and `gcp` sub-providers plus
`signerprovider.go`. Both register with the provider registry and both are reachable;
they fail only at the credential boundary, which is the expected behaviour for an
uncredentialed probe. **P5-1 is not blocked. This is not a stop-and-report.**

**C1 also clears a constitutional check.** An unrecognised KMS reference returns
`ProviderNotFoundError`, not a passthrough signer. The provider registry fails
closed, matching the phase constitution's "controls fail closed" rule.

### 2.4 Three findings that change P5-1's design

**Finding 1 — no KMS backend offers Ed25519, and Signal Loom is Ed25519 everywhere.**

Neither backend list contains `ed25519` or `eddsa` (A3, A6 both `false`). GCP KMS
offers RSA and ECDSA P-256/P-384; AWS KMS offers RSA and ECC NIST P-256/P-384/P-521.
Meanwhile the in-repo verifier is *typed* to Ed25519, not merely configured for it:

| Location | Code | Consequence |
| :--- | :--- | :--- |
| `store/verify/verify.go:79` | `type Keyring map[string]ed25519.PublicKey` | the trust store cannot hold a non-Ed25519 key |
| `store/verify/verify.go:270` | `key, ok := parsed.(ed25519.PublicKey)` | a KMS public key PEM is rejected at load |
| `store/verify/verify.go:517` | `ed25519.Verify(key, pae, sig)` | the only signature check in the corpus verifier |
| `cmd/segment-verify/main.go:35` | `-public-key "trusted Ed25519 public key PEM"` | the CLI contract names the algorithm |

So a KMS-backed signer produces signatures the current verifier is structurally
incapable of checking, and every already-attested segment is Ed25519. **P5-1 is a
dual-algorithm change — a new `Signer`/`Verifier` interface pair with algorithm
negotiation and a mixed keyring — not a signer swap.** Sizing `L` is right; sizing it
as a refactor is not. This also engages the phase's hard blocker directly: a naive
swap *would* make existing attested segments fail verification, so P5-1 must add an
algorithm, never replace one.

**Finding 2 — adopting go-witness's signer wholesale silently invalidates every
existing attestation.**

The prototype signed an identical Signal Loom segment statement two ways:

```
## D. Envelope compatibility: go-witness ed25519 signer vs Signal Loom's hand-rolled DSSE
D1 signalloom keyid  = a6792ad6fc345511e5ce33d93aa6bb2d8eca51662f2f43d8c374db72b0245fe8
D2 signalloom keyid len = 64 (verify.go validDigest requires 64 hex)
D4 go-witness keyid  = de5ca6dd791334496ee10f4951988ff176b2df620462a8d7295f322627e1740c
D5 go-witness keyid len = 64
D6 KEYIDS MATCH        = false
D7 SIGNATURES MATCH    = true (ed25519 is deterministic, so equality proves identical PAE)
D8 go-witness payloadType = "application/vnd.in-toto+json"
D9 repo verify.go would accept go-witness envelope = false (keyid known=false)
```

Read D7 and D6 together, because that pairing is the whole finding:

- **D7 is good news.** The signatures are byte-identical. Ed25519 is deterministic, so
  equal signatures prove the two implementations produced the *same* DSSE PAE over the
  *same* payload bytes. The envelope wire format is interoperable; `payloadType`
  matches too (D8). P5-1 does not need to renegotiate DSSE.
- **D6/D9 are the trap.** The two `keyid` derivations differ. Signal Loom uses
  `hex(sha256(MarshalPKIXPublicKey(pub)))` — an SPKI DER digest
  (`segment_attestor.go:206-211`). go-witness uses its own `cryptoutil` key ID. Both
  are 64 hex characters, so `verify.go:330`'s `validDigest` check **passes on both**.
  The mismatch is not caught by shape validation; it surfaces one layer deeper at
  `verify.go:526` as `DSSE signature references untrusted key`.

**A well-formed, correctly-signed envelope that fails as "untrusted key" is exactly
the failure mode that reads as a key-distribution problem rather than a code change.**
P5-1 must pin the keyid derivation explicitly and carry a regression test that signs
with the new abstraction and verifies with the *existing* verifier against a *pre-
existing* keyring. That test must be able to fail: assert on the keyid value, not on
its length.

**Finding 3 — Azure Key Vault is not supported by `go-witness v0.8.4`.**

`signer/kms/` contains `aws` and `gcp` only (C1 confirms Azure resolves to
`ProviderNotFoundError`). If the residency story for a customer requires Azure, P5-1
either upgrades go-witness — `v0.12.0` is the current published tip, four minors past
the pinned CLI's `v0.8.4` — or writes a provider. Neither is in the current estimate.

---

## 3. Current signer: key material constraint — **CONFIRMED**

Required test: `rg -n 'ed25519|PrivateKey' d2-signalloom/apps/signal-ingest/store/segment_attestor.go` — exit 0, 15 matches.

The signer requires a **local, raw, unencrypted PKCS#8 Ed25519 private key read from
the filesystem**:

| Line | Evidence |
| :--- | :--- |
| `segment_attestor.go:51` | `PrivateKeyPath string` — config takes a path, not an interface |
| `:190` | `os.ReadFile(path)` |
| `:194` | `pem.Decode(raw)` |
| `:198` | `x509.ParsePKCS8PrivateKey(block.Bytes)` — no password parameter |
| `:201` | `parsed.(ed25519.PrivateKey)` — hard type assertion |
| `:219` | `ed25519.Sign(s.privateKey, …)` — in-process, in-memory |
| `:234` | `NewSegmentAttestor` errors unless `cfg.PrivateKeyPath != ""` |

`ed25519Signer` is a **concrete unexported struct**, not an interface. `SegmentAttestor.signer`
is typed `*ed25519Signer` (`:82`). There is no seam to substitute a KMS signer into —
introducing one is the first task of P5-1, and it is a genuine (if small) API change
across `store`.

The same constraint holds on the Python side: `audit_anchor/anchor.py:137-140`
`load_private_key` calls `load_pem_private_key(..., password=None)` and
`anchor.py:162` signs in-process. A KMS-backed checkpoint signer is a *second*
implementation in a *second* language. **This is not in the P5-1 row and should be
surfaced to the Governor before the phase opens.**

## 4. Current signer: synchronicity — **REFUTED**

The card states the attestor "signs synchronously inside the upload loop". **Evidence
says otherwise, and the correction matters.**

```go
// store/frostdb.go — attestingBucket.Upload
if err := b.Bucket.Upload(ctx, name, io.TeeReader(reader, counting)); err != nil {
    return err
}
if strings.HasPrefix(…, segmentScope+"/") && strings.HasSuffix(name, "/data.parquet") {
    b.attestor.enqueue(segmentUpload{…})
}
return nil
```

`enqueue` (`segment_attestor.go:520-536`) performs a **non-blocking** channel send with
a `default:` arm. Signing happens later, on the `a.run()` goroutine draining `a.queue`
(`:601-618`), which is where `a.signer.sign(statement)` is finally called (`:697` for
segments, `:756` for checkpoints). `Upload` returns without waiting.

**Why this changes the P5-1 risk model rather than merely correcting a sentence.**
The intuitive objection to KMS — "a network round trip per segment will blow the flush
latency budget" — **does not apply to the upload path**. KMS latency lands somewhere
else, and somewhere worse:

1. **Queue overflow becomes the real failure mode.** `QueueSize` defaults to **16**
   (`:242`). On overflow, `enqueue` takes the `default:` arm, increments `a.overflows`
   and calls `reportError("queue_overflow", …, errAttestationQueueFull)` — **the
   segment is uploaded and left unattested, and `Upload` still returns `nil`.** A
   50–200 ms KMS round trip in place of a ~50 µs local Ed25519 sign is a three-to-four
   order of magnitude increase in drain time per item against a 16-deep queue. P5-1
   must size the queue against measured KMS latency and decide, explicitly, whether
   overflow should stay non-fatal. Under the phase constitution's fail-closed rule it
   arguably should not.
2. **`Wait(ctx)` is where the latency surfaces** (`:538-560`) — it enqueues a barrier
   and blocks until the queue drains. Any caller of `FrostDBStore.Wait`, including
   flush and shutdown paths (`frostdb.go:745-748`), absorbs the full KMS cost of every
   queued item.

The 2.75 ms p95 Signal Fusion query budget is **not** on this path and is not at risk
from KMS. Say so plainly in P5-1 rather than re-deriving it.

---

## 5. Data-subject-rights surfaces — claimed versus actual

Required test: `rg -n 'export' d2-signalloom/apps/signal-ingest/api/handlers.go` — **exit 1, zero matches. The export endpoint is absent, confirmed.**

The absence is broader than `handlers.go`. The complete production route table is
`routeDefinitions` at `api/auth.go:297`; no pattern in it contains `export`, and
`rg -i 'portab' … --glob '*.go'` returns nothing across the whole service.
`api/export_test.go` exists but is **not** a test of an export handler — it defines a
test-only `RegisterRoutes` helper. That filename is a trap for anyone grepping for
evidence that export exists.

Claims are from `docs/Signal Fusion — Architecture and GDPR Reference.md` §7.4
(lines 376–380) and §8 (line 514).

| Article | Documentation claims | Actual state | Verdict |
| :--- | :--- | :--- | :--- |
| **15 — Access** | "Built into `GET /api/v1/actors/{id}/authorization` **and export endpoint**" | `/api/v1/actors/{id}/authorization` **exists** (`auth.go:297` route table). The **export endpoint does not exist** — zero matches in `handlers.go`, zero in the route table, no handler anywhere in the service. | **Half true.** The authorization read is real; a subject-scoped Art. 15 "all personal data concerning them" response is not. |
| **20 — Portability** | **No row. Art. 20 is absent from §7.4 and from the §8 regulation list.** | No structured-export mechanism, no machine-readable subject bundle, no `portab*` symbol anywhere. | **Not claimed and not built.** The documentation gap is itself a finding: a DPO reading §7.4 sees five rights addressed and will ask why 20 is missing. |
| **21 — Objection** | "Host sensor allowlist/denylist filter evaluated at the workstation level" | No such filter. The only `allowlist` in the service is `store/label_allowlist.go`, a **FrostDB column allowlist** — a schema-shaping control, not a per-subject telemetry opt-out. No collector consults a subject-level exclusion list. | **False.** The named mechanism does not exist, and the nearest-named artefact is a different control that a reviewer could easily mistake for it. |

Two adjacent rows checked while the file was open, because P5-3 will be read against
the whole table:

| Article | Documentation claims | Actual state | Verdict |
| :--- | :--- | :--- | :--- |
| **17 — Erasure** | "Crypto-shredding subject data key in KMS + logging attested tombstone" | **Built.** `api/erasure.go` serves `POST /api/v1/privacy/erasure/{id}`; the route is in the table; `privacy/` carries `destroyer.go`, `hold.go`, `exception.go`, `grounds.go`, `retention.go`, `operator.go` and `privacy/tombstone/`. Delivered by P4. | **True** (the "in KMS" qualifier is aspirational — see §2). |
| **18 — Restriction** | "Setting actor resolution status to `frozen` in the PostgreSQL graph" | No such status. Every `frozen` match in the service is unrelated — cgroup freeze (`pkg/fair/telemetry.go:31`), a STUN client field (`correlation/stun_client.go:43`), "frozen sorted-key JSON" (`collectors/agentnono/external_contract.go:464`). | **False.** |

**This is why P5-3 is a build, not a correction.** Three of the five rights §7.4
claims as implemented (15-partial, 18, 21) have no code behind them, and the one right
the table omits entirely (20) is squarely in P5-3's scope. Treating §7.4 as a
statement of current state — which is what produced this gap — would have P5-3
verifying mechanisms that were never written.

**A specific warning for P5-3's acceptance criteria.** An Article 15 test that asserts
"the endpoint returns 200 with the subject's data" will pass against a handler that
returns the subject's data *from one store*. The identity graph spans PostgreSQL
(actors, aliases, delegations) **and** FrostDB (observations). A criterion that cannot
distinguish a complete subject bundle from a partial one would pass whether or not the
control works, which the phase constitution forbids. Assert on cross-store
completeness, and include a negative fixture — a subject with rows in FrostDB but not
in PostgreSQL — that fails the partial implementation.

---

## 6. Evidence index

| # | Claim | Probe | Result |
| :--- | :--- | :--- | :--- |
| E1 | Worktree clean, derives from integration | `git status`, `git merge-base --is-ancestor` | pass |
| E2 | Store suite green | `go test ./store/...` | `ok`, exit 0 |
| E3 | Segment signer is Ed25519, local file | `rg 'ed25519\|PrivateKey' store/segment_attestor.go` | exit 0, 15 matches |
| E4 | Export endpoint absent | `rg 'export' api/handlers.go` | **exit 1** |
| E5 | go-witness absent from signal-ingest | `rg 'go-witness' …/go.mod` | no match |
| E6 | witness CLI pinned at 0.9.1 | `scripts/setup.sh:33` | `WITNESS_VERSION="0.9.1"` |
| E7 | witness 0.9.1 → go-witness v0.8.4 | upstream `go.mod` line 9 | `go-witness v0.8.4` |
| E8 | Witness accepts KMS signers | prototype §A, §B | aws + gcp providers registered and reachable |
| E9 | No KMS backend offers Ed25519 | prototype A3, A6 | both `false` |
| E10 | Verifier is typed to Ed25519 | `store/verify/verify.go:79,270,517` | `map[string]ed25519.PublicKey` |
| E11 | DSSE envelope bytes interoperable | prototype D7, D8 | signatures identical |
| E12 | keyid derivations differ, silently | prototype D6, D9 | mismatch, both 64 hex |
| E13 | Unknown KMS scheme fails closed | prototype C1 | `ProviderNotFoundError` |
| E14 | Signing is asynchronous | `store/frostdb.go` `attestingBucket.Upload`, `segment_attestor.go:520-536,601-618` | non-blocking enqueue |
| E15 | Queue overflow is non-fatal | `segment_attestor.go:528-534` | `default:` arm, `Upload` returns nil |
| E16 | Art. 21 mechanism absent | `rg -i 'allowlist\|denylist\|opt.?out'` | only `store/label_allowlist.go`, a column allowlist |
| E17 | Art. 18 `frozen` status absent | `rg 'frozen'` | three unrelated matches |
| E18 | Art. 20 absent from code and doc | `rg -i 'portab'`; §7.4 table | no match; no row |

---

## 7. What was NOT reached — unconfirmed assumptions

Stated explicitly, because an unconfirmed assumption carried silently into P5 is what
this preflight exists to catch.

1. **The `witness` CLI itself was never executed.** It is not on `PATH`. The
   prototype exercised `go-witness v0.8.4`, the library `witness v0.9.1` is built
   from. A CLI flag surface may differ from the library surface; if P5-1 drives KMS
   through `witness sign --signer-kms-ref`, that flag path is **unverified**.
2. **No KMS signature was ever produced.** There are no AWS or GCP credentials in this
   environment (prototype B2, B4). The finding "Witness accepts a KMS signer" is a
   finding about *reachable, registered code paths and declared algorithm support*,
   not about a signature that came back from a real HSM. **P5-1 should begin by
   producing one real KMS signature against a scratch key before building on top.**
3. **KMS round-trip latency was not measured.** The queue-overflow analysis in §4 uses
   an assumed 50–200 ms. That number is an assumption, not a measurement, and P5-1's
   queue sizing must not inherit it uncritically.
4. **Archivista's acceptance of a non-Ed25519 envelope was not tested.**
   `SegmentAttestorConfig.ArchivistaURL` publishes attestations; whether Archivista
   accepts an ECDSA- or RSA-signed DSSE with the repo's predicate type is unverified
   and is a second place Finding 1 could bite.
5. **`store/verify` has no direct unit tests** (`[no test files]`). P5-1 changes this
   package; the coverage it will be changed under is indirect.
6. **`/goal` was not invoked.** The card instructs `/goal with token budget of 100000
   and 100 auto-retries`. No `goal` skill is registered in this harness, so the
   instruction could not be executed. The 180-minute ceiling was respected regardless;
   the run completed well inside it.

## 8. Recommendations to the P5 Governor

1. **P5-1 is not blocked — proceed.** But re-scope it as *dual-algorithm signing with
   a pinned keyid derivation*, not as a signer abstraction. Findings 1 and 2.
2. **Add a P5-1 acceptance criterion that can fail:** sign with the new abstraction,
   verify with the *unmodified* `store/verify` against a keyring built *before* the
   change, and assert on the keyid **value**. Length assertions pass on the broken
   case (D2/D5 are both 64).
3. **Decide the queue-overflow posture explicitly.** Today a KMS-induced overflow
   leaves a segment silently unattested with `Upload` returning `nil`. Under
   "controls fail closed" that is the wrong default, and it is pre-existing rather
   than introduced by P5-1 — so it needs a decision, not a drive-by fix.
4. **Surface the Python checkpoint signer.** `audit_anchor` has the same local-key
   constraint in a second language and is not in the P5-1 row.
5. **Correct §7.4 of the GDPR reference as part of P5-2 or P5-3.** Three rows claim
   mechanisms that do not exist. Shipping a DPIA pack that cites an inaccurate rights
   table is a worse outcome than shipping no pack.
6. **Confirm whether Azure is in the residency scope.** If yes, P5-1 grows by a
   go-witness upgrade or a new provider.
