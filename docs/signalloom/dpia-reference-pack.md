---
title: Signal Loom — Article 28(3)(f) DPIA Assistance Pack and Article 6(1)(f) Legitimate Interest Assessment
instrument: Article 28(3)(f) processor assistance artefact — NOT a completed Article 35 DPIA
status: draft — NOT APPROVED. Completeness checklist §12 currently FAILS on 19 of 45 rows.
verdict: THIS PACK DOES NOT SUPPORT DEPLOYMENT as at 2026-09-14.
owner: unassigned — see §11, no named controller has adopted this pack
author: SLDP-P5-2 (engineering evidence assembly; NOT legal advice)
card: SLDP-P5-2
updated: 2026-09-14
review_due: on any §10 flip condition, otherwise 12 months from controller adoption
---

# Signal Loom — Article 28(3)(f) DPIA Assistance Pack and Article 6(1)(f) Legitimate Interest Assessment

> ## Top-line disposition
>
> **This pack does not support deployment as at 2026-09-14.** Nineteen of forty-five completeness
> rows fail, eight risks carry a HIGH residual, Article 36 prior consultation is **required** on the
> current evidence (§11.1), no controller has adopted the pack, no DPO has advised on it, and no
> employee-representative instrument has been started in any jurisdiction that requires one. A
> reader who cherry-picks the twenty-six passing rows has misread the document.

> **What this document is — and the label matters.** **Article 35 is a *controller* obligation and a
> processor cannot discharge it.** Per §3, ControlPlane is most likely the *processor* for
> workstation telemetry. This document is therefore the **Article 28(3)(f) assistance artefact** —
> the processor's duty to assist the controller with Articles 35 and 36 — supplying the evidence,
> the data-flow inventory, the risk register and a Legitimate Interest Assessment *template* that
> the controller completes, adopts and signs. Calling it "the DPIA" would assert an obligation
> ControlPlane cannot perform and would make the blank LIA outcome at §6.6 read as a gap rather
> than as the correct state of a template.
>
> Every factual claim about the system resolves to a repository path, a test name, or an executed
> command. Claims that could not be evidenced are marked `OPEN` with a named owner rather than
> asserted.
>
> **What this document is not.** It is not legal advice, it is not a completed or signed DPIA, and
> it is not a statement that Signal Loom is compliant. §12 is a checklist a reviewer is expected to
> *fail* where the pack is incomplete, and it is delivered failing.
>
> **A caution on how this pack was verified.** Its acceptance probes are overwhelmingly presence
> checks. A `grep` for `35(7)(a)` proves a heading exists, not that the description beneath it is
> adequate. **A fully green probe run is the start of review, not the end of it** — the substance
> lives in prose that no automated check reads.

---

## 1. Why this pack exists, and the honesty contract it operates under

Before this card, Signal Loom's data-protection position existed only as engineering artefacts: a
storage-copy inventory (`docs/signalloom/sldp-p0-boundary-map.md`), a hosted-promotion threat model
(`docs/signalloom/demo-to-hosted-threat-model.md`), and four phases of control proofs. No DPIA
existed. More seriously, the processing that most obviously requires one — continuous telemetry
from external developer workstations — had **no Article 6(1)(f) Legitimate Interest Assessment
anywhere in the repository**.

Three rules govern every statement below.

1. **Evidence over intent.** A control is described as shipped only where a phase proof records it
   as shipped. Where a phase proof records something as residual, it is listed in §9, not §7.
2. **Absence is a claim that needs positive evidence.** Where this pack says a control does not
   exist, a probe was run and its command and result are recorded. A search that merely returned
   nothing is not written up as an absence.
3. **`Signal Fusion — Architecture and GDPR Reference.md` §7.4 is NOT cited as authority anywhere
   in this pack.** That table contains three claims this card falsified by probe (§8). Citing it
   would import those errors into a document a regulator may read.

---

## 2. Article 35(1) and 35(3) — why a DPIA is required

Article 35(1) requires a DPIA where processing is "likely to result in a high risk to the rights
and freedoms of natural persons". The triggers are worked below rather than merely cited.

| Art. 35(3) trigger | Engaged? | Reasoning |
|---|---|---|
| **(a)** systematic and extensive evaluation of personal aspects based on automated processing, including profiling, producing legal or similarly significant effects | **Partially — and this is the contested one** | Signal Loom performs automated *actor resolution* across delegation graphs, producing confidence-scored attributions of action to person (`d2-signalloom/apps/signal-ingest/model/signal.go:99-119`; `FidelityTier` scoring at `:80-96`). Whether an attribution produces "similarly significant effects" depends on what the customer does with it. Where the customer uses it in a disciplinary or containment decision — and SLER is proposed to add containment (`docs/Signal Loom Workstation Sensor — Architecture, Verification, and Distribution Strategy.md:142`) — (a) is engaged. **OPEN-1**, owner: adopting controller. |
| **(b)** processing on a large scale of Art. 9 special categories or Art. 10 criminal-offence data | **No, by design** | The sensor's export schema is closed (`additionalProperties: false`, twice) and carries no content fields at all — `d2-signalloom/apps/agentmaxxing-host-sensor/schemas/process-lifecycle-telemetry.v1.schema.json:7,70`. No special-category field can be represented. |
| **(c)** systematic monitoring of a publicly accessible area on a large scale | **No** | Processing is on enrolled corporate hosts and in-cluster planes, not public areas. |

**Beyond Art. 35(3), the WP29/EDPB criteria in WP248 rev.01 that are met:** *systematic monitoring*
(continuous process-lifecycle telemetry), *data concerning vulnerable data subjects* (employees, by
reason of the employment power imbalance — see §6.4), *innovative use of technology* (eBPF/Landlock
kernel-level host sensing), and *data processed on a large scale* at fleet deployment (the
distribution roadmap targets 500+ machines,
`docs/Signal Loom Workstation Sensor — Architecture, Verification, and Distribution Strategy.md:153`).

**Four criteria met. WP248 treats two or more as indicative of high risk. A DPIA is required.**

---

## 3. Controller / processor allocation — read this before §6

This allocation is load-bearing and is stated first because the LIA in §6 is void if it is wrong.

| Processing | Likely controller | Likely role of ControlPlane | Basis |
|---|---|---|---|
| Developer-workstation telemetry from enrolled hosts | **The employing organisation** (Signal Loom's customer) | **Processor** | The customer takes **the decision to deploy**: whether to monitor at all, which engineers, for what purpose, and what is done with the output. That decision is the determination of purpose and is the core of controllership. Enrolment mechanics are corroborating, not constitutive — the one-time token is redeemed by a *customer operator* (`docs/Signal Loom Workstation Sensor — Architecture, Verification, and Distribution Strategy.md:63-67,126-127`). **OPEN-18**: the identity of "operator" must be pinned down. If the operator is the individual developer enrolling their own laptop, that does **not** transfer controllership by delegation and it smuggles in a consent flavour that cannot survive the power imbalance at §6.4. |
| In-cluster identity graph and audit planes in a customer deployment | **The customer** | **Processor** | Default topology is self-hosted inside the customer boundary. |
| ControlPlane's own demo / development estate | **ControlPlane** | **Controller** | ControlPlane determines purpose and means for its own instance. |

**Consequence, and it is the single most important sentence in this pack: the Article 6(1)(f)
balancing test for workstation telemetry is the *customer's* to make, not ControlPlane's.** §6 is
therefore written as a **template LIA for the adopting controller to complete and own**, with
ControlPlane's evidence supplied against each limb. Any version of this pack that presents §6 as
ControlPlane's own concluded assessment is asserting an authority ControlPlane does not have.

### 3.1 Three facts that push toward vendor controllership, stated rather than omitted

The conclusion above is defensible but it is not safe. Under EDPB Guidelines 07/2020 a processor may
fix only **non-essential** means; categories of data and duration of processing are *essential*
means. Three facts bear on this and a reviewer will find all three.

| Fact | Why it cuts against pure processorship | Disposition |
|---|---|---|
| **The vendor fixes the data categories.** The export schema is closed and the customer cannot add or remove a field (§4.2) | Categories of data are an essential means | **Not fatal, but must be declared.** A take-it-or-leave-it model is permissible where the customer can *assess the fixed model and accept it*. The fixed categories are therefore published in full at §4.2 precisely so the controller can assess them. **The controller must record that it finds them adequate** — checklist row C-10 |
| **The vendor may fix duration.** At least two sinks have **no retention control at all** (§4.4) | Duration of processing is an essential means. A vendor-imposed indefinite retention is the vendor determining duration | **Live issue.** Owner: SLDP-P6-1. Until a retention controller exists and is customer-configurable, this argument is open |
| **Key custody is the tripwire.** If ControlPlane holds the P2 HMAC pseudonymisation key or the P4 per-subject key hierarchy, ControlPlane **can re-identify**, and the data is pseudonymous rather than anonymous *in ControlPlane's hands* | Key custody is an essential means and is the strongest available argument against pure processorship | **OPEN-19 — UNRESOLVED AND NOT ASSESSED BY THIS CARD.** Owner: ControlPlane legal + engineering. Who holds the root pseudonymisation key and the per-subject KEKs in a hosted deployment? SLDP-P5-1's non-exportable-KMS-key work bears directly on this |

### 3.2 The inversion this pack does not currently rule out

**Does ControlPlane process any of this telemetry for its own purposes** — product analytics,
debugging, support, benchmarking, security research, or model training?

If yes, for *any* slice, **ControlPlane is a separate controller for that purpose** — not a joint
controller, a separate one — and it needs its own lawful basis, its own LIA, and its own notice.
This is the most common real-world controllership inversion in this product category, and nothing in
this pack currently excludes it.

**OPEN-20 — owner: ControlPlane legal + product.** Enumerate every vendor-side use of customer
telemetry and state for each whether it is instructed processing under the DPA or a vendor purpose.
A nil return is a valid answer but it has to be given.

Joint controllership (C-210/16 *Wirtschaftsakademie*, C-40/17 *Fashion ID*) would require jointly
determined purposes and is not made out on these facts. **Separate controllership for vendor-own
purposes is the live risk.**

**OPEN-2 — owner: ControlPlane legal (Andy Martin / Fieldfisher).** Confirm the allocation above
against the executed customer contract and DPA. **The whole pack rests on "ControlPlane is a
processor" and cites no Article 28(3) contract that would make that true — as written the position
is circular.** The allocation here is inferred from the deployment decision and the enrolment
architecture, not read from an executed agreement.

---

## 4. Article 35(7)(a) — systematic description of the processing

### 4.1 Processing activities and purposes

| # | Processing activity | Purpose | Lawful basis (proposed) | Data subjects |
|---|---|---|---|---|
| PA-1 | Continuous process-lifecycle telemetry from enrolled developer hosts | Detect and attribute autonomous-agent activity that a network- or proxy-only control cannot see | **Art. 6(1)(f)** — see §6 | Developers / engineers on enrolled hosts |
| PA-2 | Identity-graph construction (actors, aliases, delegations) | Resolve "who authorised this action?" across human, service and agent identities | Art. 6(1)(f), or Art. 6(1)(c) where the customer is under DORA/NIS2 obligation | Employees, contractors, service principals |
| PA-3 | Observation ingestion from in-cluster planes (K8s audit, SPIRE, OpenBao, GCP audit, network eBPF) | Security monitoring of the customer's own estate | Art. 6(1)(f) / 6(1)(c) | Anyone whose identity appears in cluster audit records |
| PA-4 | Tamper-evident evidence retention (attested Parquet segments, checkpoint chain) | Produce audit evidence that survives adversarial modification | Art. 6(1)(c) where a retention obligation applies; otherwise Art. 6(1)(f) | As PA-2, PA-3 |
| PA-5 | SaaS/workspace activity ingestion | Security monitoring across the application plane | Art. 6(1)(f) | Workspace users |

**PA-5 is implemented but deliberately inert in live mode** — `ModeLive` returns `ErrLiveDeferred`
rather than silently passing (`d2-signalloom/apps/signal-ingest/collectors/workspacesaas/`, live
provider integration deferred under SFDP-P2-6). It is inventoried because enabling it is a
configuration change, not a build.

### 4.2 Workstation plane — the exact fields, taken from the schema

This list is read from the machine-enforced JSON Schema, **not** from prose. Both objects declare
`additionalProperties: false`, so the wire format cannot carry a field not listed here.

**Envelope** (`schemas/process-lifecycle-telemetry.v1.schema.json:21-65`):
`schema_version`, `session_id`, `sequence`, `observed_at`, `source`, `evidence_type`,
`observation_state`, `integrity_state`, `tenant_id`, `agent_id`, `host_id`, `attributes`.

**Attributes** (`:68-114`) — required: `health_state`, `cpu_time_ms`, `resident_memory_bytes`,
`exit_code`, `restart_count`; optional: `cpu_percent`, `pid`, `ppid`.

The same partition appears in code as `ALLOWLISTED_PROCESS_ATTRIBUTES` (five fields) and
`EXTENDED_PROCESS_ATTRIBUTES` (plus `cpu_percent`, `pid`, `ppid`) at
`d2-signalloom/apps/agentmaxxing-host-sensor/filter.py:33-48`, with a nesting-recursive prohibited-key
check at `:96-111`.

> **Correction to an internal reference document.**
> `docs/Signal Loom Workstation Sensor — Architecture, Verification, and Distribution Strategy.md:102`
> states that `comm` (the process name) is "strictly collected". **It is not in the v1 export.**
> Probe: `grep -rn "comm" .../models.py .../filter.py .../schemas/*.json | grep -vi 'command\|comment'`
> → zero matches. The shipped schema carries no process name, no path, and no argv. This pack uses
> the schema, and the correction is logged as **OPEN-3**, owner: document author.

### 4.3 What the sensor is structurally prevented from collecting

| Prohibited | Enforcement | Evidence |
|---|---|---|
| `/proc/<pid>/mem`, `/proc/<pid>/maps`, `/proc/<pid>/stack`, registers | Raises `SecurityException` | `test_negative_security.py:48` |
| `/proc/<pid>/environ` | Raises `SecurityException` | `test_negative_security.py:58` |
| `/proc/<pid>/cmdline` parsing | Raises `SecurityException` | `test_negative_security.py:68` |
| Source code contents, prompt text, model generations | No field exists to carry them | Closed schema, `:7` and `:70` |
| Arbitrary nested fields | Rejected | `test_negative_security.py:152` |
| Credential environment variables (`AWS_*`, `SSH_*`, `GITHUB_*`, `KUBECONFIG`, `VAULT_TOKEN`) | Stripped by the `nono` Landlock profile | Workstation Sensor doc `:82` |

These are **test-asserted negative controls**, not documentation claims. That distinction is the
whole basis of the necessity argument in §6.3.

> **What these tests prove, and four things they do not.** They prove that **the build under test**
> refuses those reads. They do **not** prove (1) that the shipped binary is the tested binary;
> (2) that a future version will keep the guarantee; (3) that no equivalent data reaches the wire by
> some other path the tests do not model; or (4) that crash dumps, core files and local sensor logs
> are free of payload.
>
> Point (1) is partly answered: `scripts/digest_gate.sh` pins the SHA-256 of both the `nono`
> supervisor and the agent binary and **fails closed** on modification before execution. That proves
> *a* pinned digest ran — it does not by itself prove the pinned digest is the one these tests ran
> against. **The guarantee should be bound to a version and an attestation**, so a controller can
> state which build it assessed. Carried as **R-14**, **OPEN-21**.
>
> Point (2) is the sensor-update problem and is carried separately as **R-15** / **OPEN-22**: a DPIA
> assesses a fixed data model, and an auto-updating sensor can change that model without anyone
> re-running this assessment. The robust fix is for the **ingest plane to reject unknown schema
> versions**, which makes re-review enforced rather than promised — the `schema_version` const is
> already in the envelope (`:22-24`), so the mechanism is cheap.

### 4.4 Storage-copy inventory — every sink from SLDP-P0

Reproduced from `docs/signalloom/sldp-p0-boundary-map.md` § Personal-data storage-copy inventory.
"Status" is P0's verdict about the *checked deployment*, not an aspiration.

| Sink | Status | Personal or linkable content | Retention control |
|---|---|---|---|
| Identity PostgreSQL `actors` | Implementation present; active with usable `DATABASE_URL` | Actor identifier, metadata, status, timestamps | Per-subject crypto-shred (P4-1); no time-based retention controller — **SLDP-P6-1** |
| Identity PostgreSQL `aliases` | As above | Actor ID, alias type, alias value, alias hash, fidelity, validity | Envelope-encrypted + keyed pseudonym since migration `005`; erasure as above |
| Identity PostgreSQL `delegations` | As above | Principal, delegate, authorization reference, metadata, validity, revocation state | As above |
| Signal audit PostgreSQL | As above | Tenant, optional actor, event type, arbitrary detail JSON, timestamp | **No retention control exists** — SLDP-P6-1 |
| Portal `audit_events` PostgreSQL | Configured external input to anchor plane | Tenant, actor, agent, event type, arbitrary detail JSON | **No retention control exists** — SLDP-P6-1 |
| Observation memory store | Active in shipped signal-ingest | Complete `Observation` incl. identifiers, descriptions, references, labels | Process-local; lost on restart |
| Identity memory repository | Fallback path | Actors, plaintext aliases, delegations, metadata | Process-local |
| FrostDB / Parquet segments | Implemented; inactive in the shipped image | Since schema `signalloom.observations/v2`: keyed pseudonyms only, no cleartext identifier columns (P3-1) | **Immutable.** Erasure is crypto-shred, never rewrite — see §9-R1 |
| Segment evidence directory (DSSE) | Implemented; inactive unless attestation enabled | Segment path, digest, size, signer identity, checkpoint chain, signed envelopes | Immutable; linkable metadata may survive source pseudonymisation |
| Segment protected high-water file | As above | Sequence, journal size, evidence counts, segment inventory | Rollback-detection state; mode-0600 atomic replace |
| Audit-anchor output + verifier | CLI capability; no deployed scheduler found | Tenant scope, time window, row count, chained hashes, Merkle root, DSSE envelope | Raw rows not embedded |
| Archivista | Optional; no Signal Loom URL configured | DSSE envelopes (hashes and metadata) | Immutable by design |
| Rekor | **Not implemented** — publication actively rejected | No current copy | Treat future publication as a new sink requiring re-assessment |
| Kubernetes-audit receiver channel | Active when receiver runs; process-local | Normalised principal, impersonated user, object names, namespace, URI, user agent, labels | Process-local |
| Segment-attestor queues | Inactive unless attestation enabled; process-local | Segment path, digest, byte count, errors | Process-local |
| **Application / container logs** | **Emission confirmed; retention external and UNPROVEN** | Actor IDs, IPs, reasons, pod names, segment paths, error text | **Outside this repository's boundary.** P0 could not evidence a retention policy. **OPEN-4**, owner: platform operations. |
| Backups / volume snapshots | **Not found for target datasets** | No confirmed copy | P0 searched `pg_dump`, Velero, restic, `VolumeSnapshot`; absence in source does **not** prove operators never snapshot volumes. **OPEN-5**, owner: platform operations. |

**OPEN-4 and OPEN-5 are the two most likely places for an unassessed copy of personal data to be
living right now.** Both are outside the code boundary, which is exactly why a code-derived
inventory cannot close them.

### 4.5 Recipients, sub-processors and Chapter V transfers

Default topology is self-hosted in the customer's own VPC or cluster. Public Rekor transparency-log
publication is rejected in code (`audit_anchor/anchor.py:392-407`), so attestations do not leave the
customer boundary by that route. The sensor's Landlock profile is default-deny on network egress
with a single allowlisted destination (Workstation Sensor doc `:81`).

**OPEN-6**, owner: adopting controller — confirm no telemetry egress beyond that allowlisted
endpoint at the customer's own perimeter.

> **Chapter V is not assessed by this pack and that is a top-three reason DPIAs get rejected.**
> Three questions have no answer here: **where is the hosted plane physically located**; **who are
> the sub-processors** (cloud provider, KMS provider — note SLDP-P5-1 introduces AWS or GCP KMS as a
> signing dependency, and `go-witness v0.8.4` supports only those two); and **is a transfer impact
> assessment required**. The self-hosted default makes this moot for a self-hosting customer and
> makes it decisive for a hosted one.
>
> **OPEN-25 — owner: ControlPlane legal + platform.** Produce the sub-processor list and, for any
> non-adequate-country transfer, the SCC and TIA position. SLDP-P6-2's customer-self-hosted install
> proof bears directly on this.

### 4.6 Device ownership — assessed as a current question, not only a future one

The balancing test at §6.4 assumes **corporate-owned** devices. If any enrolled host is personally
owned, the sensor reaches into private life, the reasonable-expectation argument weakens sharply,
and the balancing outcome for those hosts is likely to fail regardless of how good the content
minimisation is.

Nothing in the enrolment flow establishes or records device ownership. **OPEN-26 — owner: adopting
controller.** Establish whether any BYOD host is in scope, and if so exclude it or assess it
separately. This is carried as flip condition F-2 as well, but it is a **question for today**, not
only a future trigger.

---

## 5. Article 35(7)(b) — necessity and proportionality

Proportionality is argued from three shipped properties, each with a citation.

1. **Data minimisation is structural, not procedural.** The export schema is closed at two levels
   and the allow-list is enumerated in code. A developer adding a field to the sensor must change
   the schema, the allow-list and a test. This is stronger than a documented minimisation policy
   because it fails closed by construction.
2. **Identifiers are pseudonymised before the immutable store.** From segment column-schema
   `signalloom.observations/v2`, six cleartext identifier columns were removed from the writer and
   replaced with keyed HMAC pseudonyms, with the re-identification map relocated to an encrypted,
   RLS-protected PostgreSQL table (`docs/signalloom/sldp-p3-1-proof.md`, migration `007`). The
   pseudonym is domain-, epoch- and tenant-separated with length-prefixed derivation so two tenants
   cannot silently share a correlation domain (`identity/pseudonym.go`; boundary probed by
   `TestPseudonym_TenantBoundaryIsUnambiguous`).
3. **Erasure reaches exactly one subject and is provable.** Per-subject key destruction with an
   idempotent saga; SLDP-P4-GOV mutation-tested it by breaking `PlaintextDEKCache.PurgeSubject`
   and observing `--- FAIL: TestErasureSaga_ErasesOneSubjectOnly`. A green test is not evidence a
   property is asserted; an observed failure is.

**Counter-argument recorded rather than suppressed:** proportionality is weakest on the *continuity*
axis. Process liveness sampled continuously permits reconstruction of an individual's working hours
even with no content field whatsoever. That is a genuine intrusion and it is carried as **R-6** in
§7 rather than argued away.

---

## 6. Article 6(1)(f) — Legitimate Interest Assessment (LIA)

> **Template for the adopting controller.** Per §3 the controller for PA-1 is the employing
> organisation. ControlPlane supplies the evidence below against each limb; **the controller must
> complete the outcome at §6.6 and sign at §11.** An unsigned §6.6 means this LIA has not been made.
>
> **Scope: PA-1, developer-workstation telemetry.** The other processing activities are covered by
> the same three-limb structure but are not employee monitoring and do not carry the §6.4 power
> imbalance; they are not assessed here.

### 6.1 Why this cannot rest on Recital 49

Recital 49 provides that processing to the extent strictly necessary for **network and information
security** — preventing unauthorised access, stopping denial-of-service, detecting malicious code —
constitutes a legitimate interest. It is frequently over-read.

**Recital 49 does not carry this processing, for two reasons.**

First, a recital is interpretive and does not itself create a lawful basis; the balancing test in
Art. 6(1)(f) still has to be performed and documented. Second, and decisively, the *scope* does not
match. Signal Loom's workstation purpose as stated in its own architecture is to observe autonomous
coding agents on developer machines — a **developer-productivity and agent-governance** purpose
adjacent to security, not the network-security purpose Recital 49 addresses. The moment the
telemetry is used to understand *how developers work with agents* rather than *whether the estate is
under attack*, Recital 49 is behind the argument, not in front of it.

**This pack therefore relies on a full three-limb Art. 6(1)(f) assessment and on nothing else.**

### 6.2 Limb 1 — Purpose test

*Is there a legitimate interest, and whose?*

The interest must be named specifically. "Security" is not specific enough to balance against.

| Interest | Party | Why it is legitimate |
|---|---|---|
| Establishing attributable authority for actions taken by autonomous coding agents operating with a developer's delegated credentials | The employing organisation (controller) | Agents execute bash, edit code and invoke compilers under a human's authority (Workstation Sensor doc `:44-45`). Without attribution the organisation cannot answer "who authorised this?" for its own estate. |
| Meeting sector obligations (DORA Art. 11, NIS2) that require demonstrable operational-resilience evidence | The controller, where regulated | A statutory obligation may make Art. 6(1)(c) available instead; where it does, use it — 6(1)(c) does not require balancing |
| Producing evidence that survives adversarial modification | The controller, and third parties relying on its audit | Attested segments and checkpoint chains (P1-3, P3-1) |

**Rejected as a stated interest:** developer performance management, capacity planning, and
attrition prediction. See the purpose-limitation prohibition at §6.5.

### 6.3 Limb 2 — Necessity test

*Is the processing necessary, or is there a less intrusive way?*

Three alternatives were assessed. The first two are named in Signal Loom's own architecture as
rejected; the third is added here because a reviewer will ask.

| Alternative | Verdict | Reason |
|---|---|---|
| **Network-only / proxy monitoring** | Insufficient | Agent traffic is end-to-end TLS. Process ancestry and local filesystem interaction are invisible without MITM interception, which is *more* intrusive than process metadata (Workstation Sensor doc `:45`). |
| **In-band MCP handshake or proxy** | Insufficient and more intrusive | Sits in the data path, so it necessarily sees prompt and code payload — precisely the content this design excludes (`:46`). |
| **Periodic sampling instead of continuous observation** | **Not assessed. OPEN-7**, owner: adopting controller + engineering | Would materially reduce the working-hours inference in R-6. No evidence exists that continuous sampling is necessary rather than convenient. **This is the weakest link in the necessity argument and it is stated as such.** |
| **Aggregate-only reporting (no per-host identifiers)** | Insufficient for the stated purpose | Attribution is the purpose; aggregation destroys it. But see OPEN-7 — reduced *frequency* is not the same as reduced *granularity*. |

**Conclusion on necessity: the *content* minimisation is well evidenced and the alternatives to it
are genuinely worse. The *frequency* minimisation is not evidenced at all.** A controller adopting
this LIA is adopting an unresolved necessity question on the continuity axis.

### 6.4 Limb 3 — Balancing test

*Do the interests of the controller override the interests, rights and freedoms of the data subject?*

**Factors weighing toward the data subject:**

- **Employment power imbalance.** EDPB guidance treats employees as unable to give freely-given
  consent precisely because of this imbalance; it equally means their reasonable expectations
  deserve more weight, not less. Consent is *not available* as a basis here and must not be used.
- **The data subject is not a party to the transaction.** The developer is not the customer, has no
  commercial relationship with ControlPlane, and cannot negotiate the terms of the monitoring.
- **The developer may never encounter a notice surface.** Enrolment is performed by a customer
  *operator* redeeming a one-time token (Workstation Sensor doc `:126-127`); nothing in the
  enrolment flow requires the monitored individual to be informed. Notification is therefore an
  **employer obligation this pack must specify** (§6.5), not a product feature it can assume.
- **Working hours are inferable.** Continuous process liveness plus `host_id` reconstructs when an
  individual was working, regardless of content minimisation. Carried as **R-6**.
- **Home and personal-device blurring.** If the sensor is ever installed on a personally-owned
  device, the balance changes materially. See flip condition F-2 in §10.

**Factors weighing toward the controller:**

- **The content intrusion is structurally bounded and test-asserted**, not merely promised (§4.3).
  A DPO can verify the boundary by reading one schema file and three test assertions.

> **A bound on fields is not a bound on intrusiveness, and this pack must not pretend otherwise.**
> A closed schema bounds *field count*; it does not bound *inferential reach*. Process start and
> stop timestamps from one person's laptop, accumulated over months, yield working hours, break
> patterns, absence, out-of-hours and weekend working, and — where `agent_id` or `host_id` maps to a
> project — what that person was working on and when. WP29 Opinion 2/2017 on data processing at
> work, and the ECtHR line in *Bărbulescu v Romania* and *López Ribalda v Spain*, go directly at
> continuous employee monitoring on exactly this reasoning.
>
> **The "it's only metadata" argument is therefore available to this pack only for the *content*
> dimension, and is a category error if extended to intrusiveness as a whole.** The inferential
> dimension is carried as R-6 and R-13 and is not mitigated.
- **No content, ever.** No source code, no prompt text, no model output, no argv, no environment.
  The most feared category of developer monitoring is architecturally excluded.
- **Pseudonymisation before the immutable store** (§5.2) means the long-lived copy holds keyed
  pseudonyms, and the re-identification map is separately encrypted and RLS-protected.
- **Effective erasure exists and is mutation-proven** (§5.3) — unusual, and it materially improves
  the subject's position relative to a typical monitoring product.
- **Genuine impossibility of the alternative.** The rejected alternatives are more intrusive, not
  less (§6.3).
- **A real and current risk.** Autonomous agents acting under delegated human credentials is not a
  speculative threat model; the organisation carries the consequences of their actions.

**Where the balance sits, on the evidence available:** the *content* dimension balances clearly in
the controller's favour, and does so on unusually strong evidence. The *continuity* dimension does
not yet balance, because OPEN-7 means no one has asked whether continuous observation is necessary
or merely convenient. **A controller can reasonably conclude the balance is met for content and
should treat frequency as an open condition of that conclusion.**

### 6.5 Notification and objection boundary

**Notification (Art. 13/14, and a balancing-test precondition).** Processing that a data subject
does not reasonably expect cannot pass the balancing test. The controller must, before enrolment:

1. Inform each affected individual, in writing, that the sensor runs on their machine.
2. State the **exact field list** — it is short enough to publish in full (§4.2), and publishing it
   is the cheapest thing the controller can do to move reasonable expectations.
3. State explicitly what is **never** collected (§4.3) and that the claim is test-enforced.
4. Name the retention period and the erasure route.
5. Name the objection route and who receives it.
6. State the purpose-limitation prohibition below as a commitment, not an intention.

**Purpose limitation — written as a prohibition.** Telemetry collected under this LIA must **not** be
used for performance management, productivity ranking, capacity planning, attrition prediction, or
any input to a decision about an individual's employment. Note that **nothing in the system
technically prevents this today** — it is a policy control requiring an access-control and
audit-review commitment from the controller. **OPEN-8**, owner: adopting controller.

**Objection (Art. 21(1)).** Where processing rests on Art. 6(1)(f), the data subject has an
unconditional right to object on grounds relating to their particular situation, and the controller
must stop unless it demonstrates compelling legitimate grounds that override.

> **No objection mechanism exists in the product.**
> Probe: `grep -rniE 'object|opt.?out|denylist|exclusion'` over
> `d2-signalloom/apps/agentmaxxing-host-sensor/` and `d2-signalloom/apps/signal-ingest/privacy/`
> returns only Go/Python `object` *type* declarations and an unrelated telemetry-field allow-list.
> There is no per-subject exclusion, no opt-out, and no suppression path.
>
> `Signal Fusion — Architecture and GDPR Reference.md` §7.4 claims Art. 21 is served by a "host
> sensor allowlist/denylist filter evaluated at the workstation level". **That claim is false.**
> The allow-list at `filter.py:33-48` enumerates permitted *telemetry field names*; it has no
> per-subject dimension and cannot exclude a person. It is a different control that a reviewer
> could easily mistake for the one claimed.

**Interim objection route until SLDP-P5-3 ships:** the only mechanism that exists today is
**un-enrolment of the host**, followed by erasure of the subject under the P4 route. The controller
must state this route in its notice and must operate it manually within the Art. 12(3) one-month
deadline. **OPEN-9**, owner: SLDP-P5-3 (build) and adopting controller (interim operation).

### 6.6 LIA outcome — TO BE COMPLETED BY THE CONTROLLER

| Field | Value |
|---|---|
| Purpose test passed? | ☐ Yes ☐ No — *controller to complete* |
| Necessity test passed? | ☐ Yes ☐ No ☐ Yes, subject to OPEN-7 — *controller to complete* |
| Balancing test outcome | ☐ Interests override ☐ Do not override ☐ Override for content, open on frequency — *controller to complete* |
| Reasoning (mandatory free text — a tick with no reasoning is not a balancing test) | |
| Assessed by (name, role) | |
| Date | |

**This section is deliberately unsigned. It is the pack's single largest incompleteness and §12
row C-1 fails until it is filled.**

---

## 7. Article 35(7)(c) — risks to the rights and freedoms of data subjects

Each risk maps to at least one trust boundary from `docs/signalloom/demo-to-hosted-threat-model.md`.
Demo-mode fake integrations are **not** counted as controls anywhere in this table.

| ID | Risk | Threat-model boundary | Severity | Art. 35(7)(d) measures | Residual |
|---|---|---|---|---|---|
| **R-1** | One tenant reads another tenant's identity graph | Session and discovered-agent records | High | Keyed pseudonyms are tenant-separated with length-prefixed derivation; PostgreSQL RLS at migration `006`; tenant-bridge at `api/tenant_bridge.go` | **Medium** — RLS is a backstop; a bare pooled query under FORCE RLS is the known failure shape |
| **R-2** | Re-identification of a pseudonymised subject from retained evidence | Portal to report storage | High | Re-identification map moved out of the segment into encrypted, RLS-protected PostgreSQL (migration `007`); crypto-shred destroys the key | **Medium** — `storage_residual` acknowledged by P4-1: destroying a key does not destroy every physical copy of the ciphertext |
| **R-3** | Erasure request cannot be honoured because evidence is immutable | Portal to report storage | High | Crypto-shred, not rewrite; attested tombstones (P4-2) proven non-joinable across six join strategies with `MinAnonymitySet = 5` | **Low** for Art. 17; **see R-7** for Art. 5(1)(e) |
| **R-4** | Unauthenticated read of the full identity and delegation graph | Browser/client to portal | **Was Critical** | Closed by P1-1: JWT authentication, default-deny routing, `403` plus fail-closed audit event on unregistered or non-canonical paths | **Low** |
| **R-5** | Silent control failure — passthrough encryptor or discarding audit writer | Portal process to PostgreSQL | High | P1-2 made both fail closed: missing key is refused outside an explicit dev opt-in; audit-write failure returns `503` on high-stakes mutations and reddens `/readyz` | **Low** |
| **R-6** | **Working hours and activity patterns inferable from continuous process liveness** | Developer host to ingest | **Medium-High** | Content minimisation does not address this. No frequency control exists | **HIGH — not mitigated.** The principal unmitigated privacy risk in this pack. See OPEN-7 |
| **R-7** | Retention-expiry deletion is irreconcilable with checkpoint continuity | Portal to report storage | Medium | Crypto-shred answers Art. 17 and does **nothing** for Art. 5(1)(e) storage limitation — P4-1 surfaced this explicitly rather than claiming it away | **HIGH — not mitigated.** Owner: SLDP-P6-1 |
| **R-8** | Personal data persists in application/container logs outside the controlled sinks | Portal process to PostgreSQL | Medium | None in this repository | **HIGH — unproven.** OPEN-4 |
| **R-9** | Personal data persists in volume snapshots or backups | Portal to report storage | Medium | None found | **HIGH — unproven.** OPEN-5 |
| **R-10** | Data subject cannot exercise Art. 15, 20 or 21 | All | High | Art. 17 built (P4); Art. 15 partial; Art. 20 and 21 **absent** (§8) | **HIGH.** Owner: SLDP-P5-3 |
| **R-11** | Attestation signing degrades silently — the upload succeeds while signing is dropped | Portal to report storage | Medium | P0 identified the fail-open seam: `Upload` enqueues non-blocking and `Flush` does not await attestation | **Medium.** Evidence may be unattested without a loud failure |
| **R-12** | Telemetry repurposed for employment decisions | Developer host to ingest | **High** | Policy prohibition only (§6.5); **no technical control** | **HIGH.** OPEN-8 |
| **R-13** | **Article 9 special-category data revealed by inference from working-hour patterns** | Developer host to ingest | **High** | **None.** Content minimisation cannot reach this — the inference is in the timing, not the fields | **HIGH — not mitigated.** See below |
| **R-14** | The tested build is not provably the shipped build | Developer host to ingest | Medium | Binary digest preflight gate pins the SHA-256 of the sensor and supervisor binaries before execution (`scripts/digest_gate.sh`) | **Medium.** The gate proves *a* pinned digest ran, not that the pinned digest is the tested one. **OPEN-21** |
| **R-15** | Sensor auto-update silently changes the assessed data model | Developer host to ingest | Medium | None — schema version is declared but the ingest plane is not known to reject unknown versions | **HIGH.** A DPIA assesses a fixed data model; an updatable sensor can change it. **OPEN-22** |

**Article 9 by inference (R-13) — why this is not a stretch.** Regular absence at specific times on
specific days can reveal religious observance; recurring multi-day gaps can reveal health
conditions; attendance patterns can reveal trade-union activity. Following **C-184/20 (*OT v
Vyriausioji tarnybinės etikos komisija*)**, data that *indirectly* reveals a special category falls
within Article 9 **regardless of the controller's intent**. Article 9 requires a condition under
9(2) in addition to the Article 6 basis, and "legitimate interests" is not among them.

**This risk had no entry in this pack until adversarial review at the commitment boundary found it,
and it is the one a German DPO or works council is most likely to raise first.** **OPEN-23**, owner:
adopting controller + DPO.

**Eight risks carry a HIGH residual (R-6, R-7, R-8, R-9, R-10, R-12, R-13, R-15). That is the honest
state of this system and it is why §11 is unsigned.**

---

## 8. Data-subject rights — actual state, by probe

`Signal Fusion — Architecture and GDPR Reference.md` §7.4 presents a rights table. **Three of its
claims are false and one right is missing entirely.** SLDP-P5-PRE found this; this card re-probed
each one. The corrections are recorded here because a DPIA citing an inaccurate rights table is
worse than no DPIA — but §7.4 is **not edited by this card**, because SLDP-P5-3 owns those
mechanisms and is running concurrently.

| Right | §7.4 claim | Actual state | Probe |
|---|---|---|---|
| **Art. 15 Access** | "`GET /api/v1/actors/{id}/authorization` **and export endpoint**" | **Half true.** The authorization endpoint exists. The export endpoint does not | `rg -n 'export' api/handlers.go` exits 1; no route in the production table contains `export`. **Trap:** `api/export_test.go` exists but defines a test-only `RegisterRoutes` helper — it reads as evidence of an export surface to anyone grepping filenames |
| **Art. 16 Rectification** | Mutable delegation graph, new time-valid edge | **True** | Delegation writes at `identity/repository.go:255-300` |
| **Art. 17 Erasure** | Crypto-shred + attested tombstone | **True** | `api/erasure.go`, `privacy/`, P4-1 and P4-2 proofs, mutation-tested by P4-GOV |
| **Art. 18 Restriction** | "Setting actor resolution status to `frozen`" | **FALSE** | `grep -rn 'frozen' d2-signalloom/apps/signal-ingest/identity/` → **zero lines**. No `frozen` status exists |
| **Art. 20 Portability** | *Absent from §7.4 entirely* | **Absent from the system** | `rg -i 'portab'` finds nothing service-wide |
| **Art. 21 Objection** | "Host sensor allowlist/denylist filter at workstation level" | **FALSE** | See §6.5. The allow-list is over field names, not subjects |

**Remediation owner for all four defects: SLDP-P5-3** (Articles 15, 20, 21) and the author of
`Signal Fusion — Architecture and GDPR Reference.md` (the §7.4 text itself, logged as **OPEN-3**).
**Article 18 has no owner on the current board — it is not in any P5 or P6 row. OPEN-10.**

A note for whoever writes the Art. 15 acceptance test: a test asserting "returns 200 with the
subject's data" will pass against a handler that reads **one** store. The identity graph spans
PostgreSQL (actors, aliases, delegations) *and* FrostDB (observations). Assert cross-store
completeness with a negative fixture — a subject having FrostDB rows but no PostgreSQL rows — that
fails a partial implementation.

---

## 9. Immutability, erasure and the reconciliation that is not yet made

**R1 — Attested evidence is never rewritten.** Erasure of a subject destroys the per-subject key;
the ciphertext bytes stay byte-identical, so SHA-256 digests, Merkle roots and DSSE signatures
continue to verify. This is what makes Art. 17 and tamper-evidence co-exist.

**R2 — Crypto-shred does not discharge Art. 5(1)(e).** Storage limitation requires data to be
*deleted* when no longer necessary, and key destruction leaves the ciphertext in place. SLDP-P4-1
recorded this as surfaced-not-resolved; SLDP-P6-1's retention controller owns it. **Until then,
Signal Loom has an erasure control and no retention control.** Any claim that the system "meets
GDPR retention requirements" is unsupportable today.

**R3 — Erasure under legal hold is refused, deliberately.** SLDP-P3-2 gates erasure behind an
Art. 17(3) legal hold that fails closed, overridable only by a dual-operator Ed25519-signed,
time-bounded retention exception naming an enumerated ground. The direction was chosen on the
reasoning that an Art. 17 breach is remediable by re-submission and visible lateness, whereas
evidence destroyed during a live incident is not remediable at all. **The controller must operate
this as a time-bounded Art. 12(3) deferral with a DPO escalation, not as a permanent refusal** —
otherwise a defensible control becomes an Art. 17 breach by operation.

**R4 — Tombstones cannot recreate the link they erase.** SLDP-P4-2 published
`signalloom.tombstone/v1` with no `time.Time` field anywhere in the struct (reflection-asserted),
and refused two fields the preflight had allow-listed because each was itself a linkage mechanism.
Non-joinability is tested by attempting the join across six strategies and requiring every one to
leave at least five candidates.

---

## 10. Flip conditions — what makes this assessment expire

A DPIA that cannot expire is a DPIA nobody re-reads. **Any of the following invalidates §6 and
triggers a fresh assessment under Art. 35(11).**

| ID | Condition | Why it flips the balance |
|---|---|---|
| **F-1** | **SLCD ships.** Coding-agent detective telemetry adds procfs tree inspection, kanban loop watching, **disk transcript metadata**, and inference socket detection; the macOS variant watches `~/.claude/` and `~/.gemini/antigravity-cli/` | Moves the processing from *process liveness* to *records of the subject's work product*. This is a materially different intrusion and §6.4's content argument does not survive it unchanged |
| **F-2** | Sensor deployed to personally-owned devices | Destroys the corporate-device assumption underpinning reasonable expectations |
| **F-3** | Telemetry used for any purpose in §6.5's prohibition | Purpose limitation breached; the stated interest is no longer the actual interest |
| **F-4** | ControlPlane aggregates telemetry across customers | ControlPlane becomes a controller in its own right and needs its own lawful basis and its own LIA |
| **F-5** | **SLER ships** — containment and kill-switch (cgroup freezer) | Automated action against a person's working environment strengthens the Art. 35(3)(a) "similarly significant effects" reading; engages Art. 22 |
| **F-6** | Rekor or any public transparency log is enabled | Creates an external, non-erasable copy — the opposite of the current design |
| **F-7** | Retention controller (SLDP-P6-1) ships | Changes R-7 from unmitigated to mitigated; a *favourable* flip, and the pack should be re-run to claim it |

---

## 11. Approval and residual-risk sign-off — UNSIGNED

### 11.1 Controller approval

| Role | Name | Organisation | Date | Signature |
|---|---|---|---|---|
| Controller representative (accountable for §6.6) | | | | |
| Data Protection Officer (Art. 35(2) advice) | | | | |
| CISO or security owner | | | | |
| Works-council / employee-representative liaison (where §13 requires) | | | | |

**Art. 35(2) — DPO advice:** ☐ sought ☐ not sought. **OPEN-11** — no DPO has reviewed this pack.

**Art. 35(9) — views of data subjects:** ☐ sought ☐ not sought ☐ not appropriate, with reasons.
**OPEN-12** — not sought. Given the employment context and the absence of any objection mechanism
(§6.5), *not seeking them is itself a balancing-test weakness*, not a neutral procedural choice.

> **Art. 35(9) and Art. 88 should be discharged together, not separately.** In the employment
> context the works-council or employee-representative consultation required by §13 **is** the
> natural vehicle for seeking the views of data subjects. Running them as two disconnected
> workstreams duplicates effort and risks the DPIA recording "views not sought" while a works
> council is simultaneously being consulted on the same processing. Owner: legal + HR, to tie
> OPEN-12 to OPEN-13/14/15 or record why they must stay separate.

**Article 36 — prior consultation with the supervisory authority.**

> **Position recorded by this card, as at 2026-09-14: Article 36 prior consultation is REQUIRED.**
> It defaults to required and stays required until specific mitigations are evidenced as *taken*.
>
> **The statutory hinge is the word "taken".** Art. 36(1) triggers where the DPIA indicates high
> risk **"in the absence of measures taken by the controller to mitigate the risk"** — measures
> *taken*, not measures *planned*. A mitigation with an owner and a scheduled card is a plan.
>
> **An earlier draft of this pack got the arithmetic wrong and the error is recorded rather than
> quietly corrected.** It stated that consultation would not be required if the controller closed
> four named risks. §7 carries **eight** HIGH residuals. Closing four leaves **four standing at
> deployment** — so on the face of Art. 36(1) consultation would be required anyway, and the
> conditional was logically incoherent. It read as an escape hatch because it was one.
>
> **Correct formulation.** On the evidence as at **2026-09-14**, residual risk is HIGH in **eight**
> areas: R-6, R-7, R-8, R-9, R-10, R-12, R-13, R-15. **Article 36 consultation is required unless
> and until every one of those eight is evidenced as mitigated — measure taken, not scheduled — and
> that evidence is verified by the DPO named at §11.1.** Re-determination point: the
> deployment-readiness gate. The determination is the controller's; this pack supplies the inputs
> under Art. 28(3)(f).
>
> **The clock is on the critical path.** Art. 36(2) allows the supervisory authority up to **8
> weeks**, extendable by a further **6** — **up to 14 weeks**. §13 correctly places the German
> works-council veto on the deployment critical path. A potential 14-week Art. 36 clock belongs on
> the *same* critical path, and any plan that omits it is internally inconsistent about what gates
> deployment.
>
> **Which authority.** Arts. 55/56 govern competence across DE, FR and NL; the UK ICO is separate
> under UK GDPR. **If the controller has no EU main establishment there is no one-stop-shop and
> several authorities must be consulted in parallel.** **OPEN-24**, owner: legal.

### 11.2 Residual-risk sign-off

Each residual requires an explicit disposition. **Accepting a risk is a decision with a name on it.**

| Risk | Residual severity | Disposition (accept / mitigate / transfer / avoid) | Accepted by | Date |
|---|---|---|---|---|
| R-1 cross-tenant read | Medium | | | |
| R-2 re-identification (`storage_residual`) | Medium | | | |
| R-6 working-hours inference | **HIGH** | | | |
| R-7 no retention control (Art. 5(1)(e)) | **HIGH** | | | |
| R-8 application/container logs | **HIGH (unproven)** | | | |
| R-9 backups / volume snapshots | **HIGH (unproven)** | | | |
| R-10 Art. 15/18/20/21 gaps | **HIGH** | | | |
| R-11 attestation fail-open seam | Medium | | | |
| R-12 repurposing for employment decisions | **HIGH** | | | |
| R-13 **Art. 9 special category by inference** | **HIGH** | | | |
| R-14 tested build ≠ shipped build | Medium | | | |
| R-15 sensor update changes the assessed model | **HIGH** | | | |

---

## 12. Completeness checklist — a reviewer is expected to FAIL rows here

**Status on delivery: 45 rows — 26 PASS, 19 FAIL.** A row fails when the artefact in the third
column does not exist. The reviewer named in the fourth column marks the row; **the author does not
mark legal rows**.

Rows `A-8`, `B-8`, `B-9`, `B-10`, `C-10`–`C-15` and `F-3` were added after adversarial review at the
commitment boundary. **Nine of the eleven additions fail.** That is the expected shape: a review that
adds only passing rows has not reviewed anything.

| # | Requirement | Fails if this artefact is absent | Reviewer | Status |
|---|---|---|---|---|
| A-1 | Art. 35(7)(a) systematic description present | §4 | DPO | **PASS** |
| A-2 | Purposes stated per processing activity | §4.1 table | DPO | **PASS** |
| A-3 | Lawful basis named per activity | §4.1 column 4 | DPO | **PASS** |
| A-4 | Art. 35(7)(b) necessity and proportionality | §5 | DPO | **PASS** |
| A-5 | Art. 35(7)(c) risks enumerated | §7 | DPO | **PASS** |
| A-6 | Art. 35(7)(d) measures listed per risk | §7 column 5 | DPO | **PASS** |
| A-7 | Art. 35(1)/(3) threshold worked, not cited | §2 | DPO | **PASS** |
| B-1 | Every P0 sink appears in the inventory | §4.4 (17 rows) | Engineering | **PASS** |
| B-2 | Every inventory row carries a repository citation | §4.4 | Engineering | **PASS** |
| B-3 | Workstation field list taken from the schema, not prose | §4.2 | Engineering | **PASS** |
| B-4 | Negative controls are test-asserted, not documented | §4.3 test names | Engineering | **PASS** |
| B-5 | Retention position stated per sink | §4.4 column 4 | Engineering | **PASS** |
| B-6 | Log-sink retention evidenced | **No artefact exists — OPEN-4** | Platform ops | **FAIL** |
| B-7 | Backup/snapshot position evidenced | **No artefact exists — OPEN-5** | Platform ops | **FAIL** |
| D-1 | Threat model cited and boundaries mapped to risks | §7 column 3 | Security | **PASS** |
| D-2 | Demo fakes not counted as controls | §7 preamble | Security | **PASS** |
| E-1 | Control claims cite phase proofs | §5, §9 | Engineering | **PASS** |
| E-2 | Mutation-tested controls distinguished from merely-green | §5.3, §9-R4 | Engineering | **PASS** |
| C-1 | **LIA outcome completed and reasoned** | **§6.6 is blank** | Controller | **FAIL** |
| C-2 | Purpose test names a specific interest and party | §6.2 | Controller | **PASS** |
| C-3 | Necessity test names and rejects alternatives | §6.3 | Controller | **PASS (with OPEN-7 noted)** |
| C-4 | **Article 36 consultation decision taken** | **§11.1 states the condition; no decision made** | Controller | **FAIL** |
| C-5 | Balancing test written with reasoning, not a verdict | §6.4 | DPO | **PASS** |
| C-6 | Recital 49 not relied upon | §6.1 | DPO | **PASS** |
| C-7 | Notification mechanism specified | §6.5 | Controller | **PASS (specified; not yet operated)** |
| C-8 | **Objection mechanism exists in the product** | **No code exists — §6.5 probe** | SLDP-P5-3 | **FAIL** |
| C-9 | **Purpose-limitation enforced technically** | **Policy only — OPEN-8** | Controller | **FAIL** |
| F-1 | Art. 88 position recorded per jurisdiction | §13 | Legal | **PASS (as a position; instruments not executed)** |
| F-2 | **Works-council consultation completed where required** | **Not started — §13** | Legal + HR | **FAIL** |
| G-1 | **Controller approval signed** | **§11.1 unsigned** | Controller | **FAIL** |
| G-2 | **Residual-risk dispositions recorded** | **§11.2 blank** | Controller | **FAIL** |
| G-3 | **DPO advice sought (Art. 35(2))** | **OPEN-11** | DPO | **FAIL** |
| H-1 | Flip conditions defined | §10 | DPO | **PASS** |
| H-2 | Review cadence stated | frontmatter `review_due` | DPO | **PASS** |
| C-10 | **Controller records the vendor-fixed essential means as adequate** | **§3.1 — no controller acceptance recorded** | Controller | **FAIL** |
| C-11 | **Key custody established (who can re-identify?)** | **OPEN-19 — not assessed** | ControlPlane legal + engineering | **FAIL** |
| C-12 | **Vendor-own-purpose processing enumerated (or nil return given)** | **OPEN-20 — not enumerated** | ControlPlane legal + product | **FAIL** |
| C-13 | **Article 28(3) DPA cited to substantiate processor status** | **OPEN-2 — no contract cited; position is circular** | ControlPlane legal | **FAIL** |
| A-8 | **Article 9 inference risk assessed with a 9(2) condition** | **R-13 / OPEN-23 — no 9(2) condition identified** | DPO | **FAIL** |
| B-8 | **Chapter V transfer position and sub-processor list** | **OPEN-25 — not assessed** | Legal + platform | **FAIL** |
| B-9 | Zero-payload guarantee bound to a version and attestation | §4.3 limits stated; **OPEN-21** | Engineering | **PASS (limits stated, binding absent)** |
| B-10 | **Ingest rejects unknown sensor schema versions** | **OPEN-22 — mechanism not implemented** | Engineering | **FAIL** |
| C-14 | **Device ownership (BYOD) established** | **OPEN-26 — not established** | Controller | **FAIL** |
| F-3 | Art. 35(9) tied to the Art. 88 instrument, or separation justified | §11.1 note | Legal + HR | **PASS (tie recommended; not executed)** |
| C-15 | **Which supervisory authority / one-stop-shop determined** | **OPEN-24 — not determined** | Legal | **FAIL** |

**This pack is therefore INCOMPLETE by its own definition, and that is the correct state for it to
be delivered in.** Only two of the nineteen failing rows can be closed by engineering alone.

| Who must act | Rows | Count |
|---|---|---:|
| Adopting controller | C-1, C-4, C-9, C-10, C-14, G-1, G-2 | 7 |
| ControlPlane legal (contract, key custody, vendor purposes, authority) | C-11, C-12, C-13, C-15 | 4 |
| DPO | A-8, G-3 | 2 |
| Legal + HR (works-council instrument) | F-2 | 1 |
| Legal + platform (Chapter V, sub-processors) | B-8 | 1 |
| Platform operations (log retention, snapshots) | B-6, B-7 | 2 |
| Engineering | B-10 | 1 |
| SLDP-P5-3 (objection mechanism) | C-8 | 1 |

**The concentration is the finding.** Seventeen of nineteen failures need a decision from a
controller, a lawyer, a DPO or an operations owner. **No amount of further engineering closes this
pack** — which is precisely why it is delivered now, failing, rather than held until it looks
complete.

---

## 13. Article 88 and national employment law — a separate instrument on a separate clock

**Article 6(1)(f) is necessary and not sufficient.** Art. 88(1) permits Member States to provide
"more specific rules" for processing in the employment context, and several have. Those rules are
not discharged by a balancing test, they are discharged by a different instrument — typically a
collective agreement or works-council approval — negotiated with a different body on a different
timeline. **Treating the LIA as covering this is the most expensive single error available here,
because works-council consultation cannot be retro-fitted after deployment.**

| Jurisdiction | Instrument required | Position | Status |
|---|---|---|---|
| **Germany** | **BetrVG §87(1)(6)** — the works council has full **co-determination** over the introduction and use of technical devices suited to monitoring employee behaviour or performance. A workstation sensor is squarely within this. §26 BDSG also applies | A **Betriebsvereinbarung** (works agreement) must be concluded **before** deployment. This is a veto right, not a consultation right — the works council can block | **OPEN-13 — NOT STARTED.** Owner: legal + local HR. Lead time is typically weeks to months and is the critical path for any German deployment |
| **France** | Consultation of the **CSE** (Comité Social et Économique) under Art. L2312-38 before introducing means of monitoring employee activity; declaration in the internal `règlement intérieur`; CNIL guidance on employee monitoring | CSE consultation is mandatory and must precede deployment; individual employees must be informed | **OPEN-14 — NOT STARTED.** Owner: legal + local HR |
| **Netherlands** | **WOR Art. 27(1)(l)** — works-council (OR) consent required for arrangements concerning personnel observation or monitoring | OR consent required before deployment | **OPEN-15 — NOT STARTED.** Owner: legal + local HR |
| **United Kingdom** | **UK GDPR Art. 6(1)(f)** (same three-limb test) and **DPA 2018 Sch. 1 Pt. 2** where an employment-law condition is engaged. **There is no works-council co-determination analogue in UK law.** The ICO is the *regulator*, not an instrument; its **Employment Practices and Data Protection — monitoring workers (2023)** guidance sets the expectation of a documented impact assessment and worker transparency | The LIA at §6 plus the §6.5 notification is the substantive instrument | **OPEN-16 — position stated; ICO monitoring checklist not formally run.** Owner: legal |
| **Ireland, Spain, Italy, Poland, Nordics, US, and all other jurisdictions** | Not assessed | — | **OPEN-17 — NOT ASSESSED.** Owner: legal. Note Italy's Art. 4 Statuto dei Lavoratori is a known hard gate and Spain's LOPDGDD Art. 87–90 sets specific device-monitoring rules; neither has been reviewed |

**The scheduling consequence, stated plainly:** in Germany, France and the Netherlands the
employee-representative instrument is on the **critical path to deployment** and has a lead time
measured in weeks or months. It does not run in parallel with the engineering work — it gates it.
Any deployment plan that assumes the DPIA is the last compliance step is wrong for those three
jurisdictions.

---

## 14. Open items register

| ID | Item | Owner | Blocks |
|---|---|---|---|
| OPEN-1 | Art. 35(3)(a) "similarly significant effects" determination | Adopting controller | §2 |
| OPEN-2 | Confirm controller/processor allocation against the executed DPA | ControlPlane legal | §3, all of §6 |
| OPEN-3 | Correct §7.4 of `Signal Fusion — Architecture and GDPR Reference.md` (4 defects) | Document author / SLDP-P5-3 | §8 |
| OPEN-4 | Application/container-log retention policy | Platform operations | B-6, R-8 |
| OPEN-5 | Backup / volume-snapshot position for identity datasets | Platform operations | B-7, R-9 |
| OPEN-6 | Confirm no telemetry egress beyond the allowlisted endpoint | Adopting controller | §4.5 |
| OPEN-7 | **Is continuous sampling necessary, or is periodic sufficient?** | Controller + engineering | C-3, R-6 — the weakest link in necessity |
| OPEN-8 | Technical enforcement of the purpose-limitation prohibition | Adopting controller | C-9, R-12 |
| OPEN-9 | Objection mechanism; interim manual route documented and operated | SLDP-P5-3 + controller | C-8, R-10 |
| OPEN-10 | **Art. 18 restriction has no owner on the current board** | Programme governance | §8 |
| OPEN-11 | DPO advice under Art. 35(2) | DPO | G-3 |
| OPEN-12 | Art. 35(9) views of data subjects | Controller | §11.1 |
| OPEN-13 | German Betriebsvereinbarung (BetrVG §87(1)(6)) | Legal + HR | F-2, deployment in DE |
| OPEN-14 | French CSE consultation | Legal + HR | F-2, deployment in FR |
| OPEN-15 | Dutch OR consent (WOR Art. 27) | Legal + HR | F-2, deployment in NL |
| OPEN-16 | ICO employment-monitoring checklist run formally | Legal | F-1 |
| OPEN-17 | All unassessed jurisdictions (IT and ES are known hard gates) | Legal | F-1 |
| OPEN-18 | Pin down who "operator" is at enrolment — employer or the developer themselves | Adopting controller | §3 |
| OPEN-19 | **Key custody — who holds the root pseudonymisation key and per-subject KEKs?** | ControlPlane legal + engineering | C-11, §3.1. Strongest argument against pure processorship |
| OPEN-20 | **Enumerate vendor-own-purpose processing, or give a nil return** | ControlPlane legal + product | C-12, §3.2. Separate controllership if any exists |
| OPEN-21 | Bind the zero-payload guarantee to a version and an attestation | Engineering | R-14, B-9 |
| OPEN-22 | Make the ingest plane reject unknown sensor schema versions | Engineering | R-15, B-10 |
| OPEN-23 | **Article 9(2) condition for special categories revealed by inference** | Controller + DPO | R-13, A-8 |
| OPEN-24 | Determine competent supervisory authority; one-stop-shop or parallel consultation | Legal | C-15, §11.1 |
| OPEN-25 | Chapter V transfer position, sub-processor list, TIA where required | ControlPlane legal + platform | B-8, §4.5 |
| OPEN-26 | Establish whether any enrolled host is personally owned (BYOD) | Adopting controller | C-14, §4.6 |

---

## 15. Provenance and limits of this pack

**Sources.** `docs/signalloom/sldp-p0-boundary-map.md`; `docs/signalloom/demo-to-hosted-threat-model.md`;
`docs/signalloom/sldp-p1-1-proof.md`, `sldp-p1-2-proof.md`, `sldp-p1-gov-proof.md`;
`sldp-p2-1-proof.md`, `sldp-p2-gov-proof.md`; `sldp-p3-1-proof.md`, `sldp-p3-2-proof.md`,
`sldp-p3-gov-proof.md`; `sldp-p4-1-proof.md`, `sldp-p4-2-proof.md`, `sldp-p4-governor-proof.md`;
`docs/Signal Loom Workstation Sensor — Architecture, Verification, and Distribution Strategy.md`;
and direct source inspection of `d2-signalloom/apps/agentmaxxing-host-sensor/` and
`d2-signalloom/apps/signal-ingest/`.

**Three limits a reader must know.**

1. **`docs/signalloom/sldp-p5-pre-proof.md` is absent from the worktree this pack was written in.**
   SLDP-P5-PRE committed `a6974f6b` to its own task worktree pending Governor merge, which has not
   occurred. Its seam confirmations were consumed from the errata block in the proposal, which
   carries them in full. Every P5-PRE finding relied on here (§8) was independently re-probed.
2. **No live capture was taken.** The zero-payload invariant is evidenced by a closed schema, an
   enumerated code allow-list, and three negative tests — not by observing a running sensor's wire
   traffic. A DPO wanting runtime assurance should ask for a packet capture.
3. **This pack is engineering evidence, not legal advice.** Every conclusion in §6, §11 and §13 is
   a controller or legal decision. Sections written by engineering state what the code does;
   sections requiring judgement are left blank on purpose.
