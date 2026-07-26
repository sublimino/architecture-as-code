# Signal Loom security release pack

<!-- machine-tag: SIGNALLOOM-SECURITY-RELEASE-PACK-2026-07-26T10:15:00+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- release-pack: candidate-only-template -->
<!-- release-decision: no-go-until-complete -->

This is a candidate-only, repository-local release-pack template. It defines
what a future authorised release decision must contain; it records no scan,
approval, cloud action, production credential, production data, or release.
All evidence is bound to one immutable candidate digest. A tag, branch, local
demo result, fake provider, or a mutable report URL is not an acceptable
substitute for that binding.

## Candidate identity

Record the immutable `repository@sha256:<64 lowercase hex characters>`, the
source revision, build identity, environment classification, and collection
timestamp with ISO-8601 offset. Resolve tags before collection. The candidate
digest must exactly match the signature, SBOM, provenance, all gate reports,
rollback artifact, and final approval record. Any mismatch is `digest-mismatch`
and is a no-go.

## Evidence ledger

For every entry record: gate, immutable candidate digest, source revision,
tool and version, exact command or approved test procedure, execution
environment, ISO-offset timestamp, durable evidence reference and checksum,
owner, result, and disposition. The ledger is append-only for the candidate;
a replacement report supersedes but does not erase a rejected result.

| Gate | Minimum evidence | Accepted disposition | No-go condition |
| --- | --- | --- | --- |
| sast (SAST) | Versioned ruleset, source revision, complete report, findings and triage record from an approved isolated build environment. | `pass`, `risk-accepted-exception`, or `not-applicable` with owner and rationale. | A blocking finding, incomplete coverage, unbound report, expired exception, or `not-run`. |
| dast (DAST) | Authorised scope, target inventory, authentication mode, rate/safety limits, complete report, and remediation/retest record from an isolated non-production target. | `pass`, `risk-accepted-exception`, or `not-applicable` only when the attack surface is documented. | Any unapproved target, external/production scan, blocking finding, incomplete scope, or `not-run`. |
| sca (SCA) | Locked dependency inventory, advisories/ruleset version, complete report, VEX or remediation evidence, and source revision. | `pass`, `risk-accepted-exception`, or `not-applicable` with owner and expiry. | A policy-severity finding without a current exception, unresolved dependency identity, or `not-run`. |
| secret-scan (secret scan) | Versioned scanner policy, full revision/range coverage, detector report, and, if a credential is found, revocation/rotation and re-scan evidence. | `pass` or `not-applicable` only for a documented scanner exclusion; exceptions cannot accept a live secret. | Any verified secret, untriaged detection, incomplete coverage, or `not-run`. |
| sbom (SBOM) | SPDX JSON, provenance reference, signature verification, and subject/digest comparison to the candidate. | `pass` only. | Missing, malformed, unverifiable, stale, or digest-mismatched SBOM/provenance. |
| pentest (penetration test) | Written authorisation, scope and rules of engagement, tester independence/competence record, report, finding disposition, and retest evidence where required. | `pass`, `risk-accepted-exception`, or `not-applicable` with documented rationale. | An unauthorised or production/external test, unremediated blocking finding, missing retest, or `not-run`. |

`risk-accepted-exception` is valid only when it names the accountable owner,
finding identifier, candidate digest, compensating controls, explicit expiry,
and approving authority. An exception is invalid after its expiry or when its
digest changes. `warning-only`, `unverified`, `digest-mismatch`,
`expired-exception`, and `not-run` are never accepted dispositions.

## Gate dispositions and acceptance criteria

Populate one disposition per required gate: `sast`, `dast`, `sca`,
`secret-scan`, `sbom`, and `pentest`. A gate is current only if its evidence was
collected for the exact candidate digest after its source/build context was
finalised. Every required gate must have an accepted disposition, a durable
ledger entry, and a named owner before the release decision may be changed.

The DAST and pentest rows deliberately require authorised isolated
non-production scope. This template neither authorises nor initiates them.
The existing static checks and demonstration fixtures may validate this
template, but cannot be cited as DAST, pentest, or production acceptance.

## Exceptions

List each exception with its finding ID, gate, candidate digest, risk statement,
compensating controls, accountable owner, approving authority, approval
timestamp with offset, expiry, and planned remediation/retest. Absence of an
exception is not a waiver. A changed digest requires renewed review.

## Approvals

Record the application, security, platform/SRE, and release-manager approvals
required by the hosted-readiness authority model. Each approval identifies the
candidate digest, reviewed ledger version, disposition summary, approver role,
delegation evidence if any, timestamp with offset, and signature or durable
approval reference. No individual local test operator is release authority.

## Rollback reference

Record the prior approved immutable digest, rollback procedure reference,
verification of its signature/SBOM/provenance, rollback owner, and the
post-rollback validation criteria. A tag-only rollback target is insufficient.

## Release decision

**Current decision: NO-GO.** This template contains no candidate evidence and
does not authorise a release. A future authorised release manager may record
`go` only after every required gate has a current accepted disposition bound to
one candidate digest, all exceptions are current and approved, rollback is
verified, and the required approvals are durable. Otherwise retain `no-go` and
identify the missing or rejected evidence in the ledger.

## ISO-offset errata

<!-- machine-tag: SIGNALLOOM-SECURITY-RELEASE-PACK-ERRATA-2026-07-26T10:15:00+01:00 -->
<!-- kanban-check: status=pass proceed=no blocking_drift=yes scope=static-template-only -->

This erratum corrects the prior absence of a single release-pack definition
covering SAST, DAST, SCA, secret scanning, SBOM and penetration-test evidence,
their dispositions, and their acceptance criteria. The static template and
contract check pass; `proceed=no` is intentional because no candidate evidence
or authorised release decision exists. No external scan, provisioning,
production access, or release was performed.
