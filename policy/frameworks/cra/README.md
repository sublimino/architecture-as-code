# cra

One version of a Cyber Resilience Act pack over agent context. Three real
checks, all priced.

| Version | Checks | Priced | Divisions cited | Anchored |
|---------|-------:|-------:|----------------:|----------|
| v1.0    | 3      | 3      | 3               | yes |

## Ground truth

**Regulation (EU) 2024/2847** of the European Parliament and of the Council of
23 October 2024 on horizontal cybersecurity requirements for products with
digital elements and amending Regulations (EU) No 168/2013 and (EU)
No 2019/1020 and Directive (EU) 2020/1828 (Cyber Resilience Act).
OJ L, 2024/2847, 20.11.2024. ELI:
`http://data.europa.eu/eli/reg/2024/2847/oj`.

Read from the publisher's own XHTML, not from memory:

- `catalogue/eu-2024-2847-cra.tsv` — 85 divisions (71 articles, 8 annexes,
  6 annex parts) with headings exactly as published. Provenance and
  regeneration: `catalogue/PROVENANCE.md`.
- `catalogue/anchor-test.sh` — every citation resolves against the right act,
  every stated heading matches exactly, and the table below and the pack data
  agree in both directions.
- `catalogue/pricing-test.sh` — every check is priced or explicitly declared
  unpriced in `catalogue/unpriced.tsv`.
- `catalogue/run-tests.sh` — both of the above.

The catalogue also anchors the `dora` and `nis2` packs, which cite the two
other acts in the same family. It lives here because `policy/frameworks/` is
outside this work's ownership; it should be hoisted to a shared location.

### Verified citations

Every claim this pack makes, the division it rests on, and whether the
division says what the control needs it to say. **No citation was found to be
fabricated — because before this work the pack carried no citations at all.**
That is the finding, not a clean bill of health: there was nothing for a gate
to disagree with, so the risk was undetectable rather than absent.

| Control | Citation | Heading as published | Verdict |
|---------|----------|----------------------|---------|
| `cra-sec-design`, `CRA-1.1`, `cra-integrity`, `CRA-3.1` | `Annex I Part I` | Cybersecurity requirements relating to the properties of products with digital elements | correct |
| `cra-vuln-handling`, `CRA-2.1`, `cra-integrity`, `CRA-3.1` | `Annex I Part II` | Vulnerability handling requirements | correct |
| `cra-sec-design`, `cra-vuln-handling`, `CRA-2.1` | `Article 13` | Obligations of manufacturers | correct |

Point-level citations are quoted verbatim below. The extract has no row for a
point, so `anchor-test.sh` anchors them as far as the Part; the quotes are how
a reviewer checks the rest.

- **Annex I Part I point (2)(b)** — products shall "be made available on the
  market with a secure by default configuration, unless otherwise agreed
  between manufacturer and business user in relation to a tailor-made product
  with digital elements, including the possibility to reset the product to its
  original state".
- **Annex I Part I point (2)(f)** — products shall "protect the integrity of
  stored, transmitted or otherwise processed data, personal or other, commands,
  programs and configuration against any manipulation or modification not
  authorised by the user, and report on corruptions".
- **Annex I Part II point (1)** — manufacturers shall "identify and document
  vulnerabilities and components contained in products with digital elements,
  including by drawing up a software bill of materials in a commonly used and
  machine-readable format covering at the very least the top-level dependencies
  of the products".
- **Annex I Part II point (7)** — manufacturers shall "provide for mechanisms
  to securely distribute updates for products with digital elements to ensure
  that vulnerabilities are fixed or mitigated in a timely manner and, where
  applicable for security updates, in an automatic manner".
- **Article 13(24)** — "The Commission may, by means of implementing acts
  taking into account European or international standards and best practices,
  specify the format and elements of the software bill of materials referred to
  in Part II, point (1), of Annex I."

## Evidence or proxy

All three checks read a value the assessed subject supplies about itself. None
of them inspects an artefact. What follows is what each one actually evidences
and where it is only a proxy.

### `default-secure-configuration` — closest to evidence of the three

Reads `agent.security_profile.secure_by_default`.

Annex I Part I point (2)(b) is the obligation and the mapping is tight: this
is the one CRA requirement that is literally a configuration default. Two
gaps, both narrow:

- The obligation has a second limb — "the possibility to reset the product to
  its original state" — which nothing in the pack evidences.
- The requirement carries an exception for a tailor-made product where the
  manufacturer and a business user have agreed otherwise. A scanner cannot see
  such an agreement, so the check is stricter than the law for that case.

Still a proxy, because a boolean saying a profile is hardened is not the
hardened profile. It is distinguishable from evidence by the fact that a
workload can set it to `true` and change nothing else.

### `sbom-verified-provenance` — the obligation is real, the test is not it

Reads `agent.sbom.format` (must be `CycloneDX` or `SPDX`) and
`agent.sbom.verified`.

Annex I Part II point (1) genuinely requires an SBOM, so this is the most
CRA-adjacent of the three. But the check and the obligation diverge in three
ways that all point the same direction:

1. **The format allow-list is this pack's choice, not the law.** The CRA says
   "a commonly used and machine-readable format" and names no format.
   Article 13(24) empowers the Commission to specify format and elements by
   implementing act; **no such act is in force**. So a manufacturer shipping a
   commonly-used machine-readable SBOM in a third format complies with the CRA
   and fails this check. The `format-lowercase` fixture shows the edge is
   sharper still: `cyclonedx` fails where `CycloneDX` passes.
2. **The CRA requires no SBOM verification at all.** `verified == true` has no
   counterpart in Annex I Part II point (1). It is a stricter house rule
   wearing a CRA label.
3. **Coverage is the actual substance of the obligation and is unevidenced.**
   The requirement is an SBOM "covering at the very least the top-level
   dependencies". The check never parses the SBOM, so it cannot tell a
   complete one from an empty document that declares itself CycloneDX.

Net: the control evidences that *a manifest claims an SBOM exists in one of two
formats*. It does not evidence Annex I Part II point (1).

### `signed-cryptographic-updates` — proxy, and the label overclaims

Reads `agent.provenance.slsa_level` and requires exactly `SLSA_LEVEL_3`.

**SLSA is named nowhere in the Cyber Resilience Act.** The obligations in the
neighbourhood are Annex I Part II point (7), secure distribution of updates,
and Annex I Part I point (2)(f), integrity against unauthorised modification.
A build-provenance level is evidence about how an artefact was *built*; the
obligation is about how updates are *distributed*. Those are different
properties, and a product can satisfy either without the other.

The check's own id and former description were the sharper problem. It
promised "SLSA Level 3 provenance and cosign signatures for all deployed
binaries" and verifies **no signature and no cosign material** — only string
equality against a self-asserted label. A report line reading
`signed-cryptographic-updates: pass` was readable as "updates are signed", and
nothing in the pack evidences that. The description has been corrected to say
what the CEL does.

Two pinned semantics, left as they are because changing either changes what
the pack claims to an auditor:

- `slsa-level-4`: the comparison is equality, not a threshold, so a stated
  `SLSA_LEVEL_4` **fails** a control it exceeds.
- `slsa-level-numeric`: the number `3` fails rather than erroring.

## Open findings

Not this pack's to decide. Recorded because the numbers and the labels a
customer reads depend on them.

### 1. The CRA does not apply yet, and the pack prices it as if it does

Article 71(2): the Regulation "shall apply from 11 December 2027", with
Article 14 from 11 September 2026 and Chapter IV from 11 June 2026. All three
checks carry a `riskTriple` and a `freqTriple` and price today — the pack
contributes real money to a scan total for obligations that bind nobody for
another two years. The figures are not wrong as a forecast; they are
undated, and a scan does not say so.

**Decision needed:** date the CRA exposure, or state in the product that the
CRA line is a 2027 forecast.

### 2. Who the CRA binds is not who is being scanned

The CRA binds **manufacturers placing a product with digital elements on the
Union market** (Article 13(1)). This pack scans a running agent workload. The
two are not the same party, and conformity under the CRA is established by a
conformity assessment procedure (Article 32), technical documentation
(Article 31 and Annex VII) and an EU declaration of conformity (Article 28) —
none of which a cluster scan can observe. Three passing checks are evidence
about a manifest's assertions, never evidence of CRA conformity, and the pack
now says so in its own `description`.

### 3. Annex I Part I point (2) is conditional, and the pack is flat

Part I point (2) applies "on the basis of the cybersecurity risk assessment
referred to in Article 13(2) and where applicable". Article 13(4) expressly
contemplates requirements that are not applicable, with a justification
recorded in the technical documentation. So a `fail` on
`default-secure-configuration` may be a correct state of affairs with a
documented justification, and the pack cannot tell that case from
non-compliance.

### 4. Article 14 is unevidenced

`Article 14` — "Reporting obligations of manufacturers" — requires notifying an
actively exploited vulnerability to the coordinating CSIRT and ENISA within
24 hours (early warning), 72 hours (vulnerability notification) and 14 days of
a fix (final report). It is the first CRA obligation to bite, on
11 September 2026, and **nothing in this pack evidences any part of it.**
Stated so the gap is explicit rather than inferred from the absence of a
check.

### 5. Three checks is not the Annex

Annex I Part I point (2) has thirteen sub-points (a) to (m) and Part II has
eight. The pack covers one of Part I's and, loosely, two of Part II's. The
unevidenced majority includes known-exploitable-vulnerability freedom (I.2(a)),
security update capability (I.2(c)), access control (I.2(d)), confidentiality
(I.2(e)), data minimisation (I.2(g)), availability and DoS resilience (I.2(h)),
attack-surface limitation (I.2(j)), exploit mitigation (I.2(k)), security
logging (I.2(l)), secure data erasure (I.2(m)), coordinated vulnerability
disclosure policy (II.5) and the free-of-charge dissemination of security
updates (II.8). No checks have been invented to close this: the honest state is
a three-check pack that says which three.

## Agent context

Every check reads `agent` only; no check reads `object`, so this pack is out of
scope for the Pod Security Admission oracle. Paths, types and absent-field
semantics: `v1.0/AGENT-CONTEXT.md`.

## Pricing coverage

The table below is produced from `framework.json`. It is not typed by hand.
`make policy-pricing-counts` fails if it drifts from the packs.

A check is priced when its `freqTriple` has a non-zero `min`, `mode`, or `max`.
A check with no frequency triple, or an all-zero one, is unpriced. An unpriced
check contributes GBP 0.00 to every reported total however often it fails. That
state is allowed, because a loss magnitude with no calibrated frequency is not a
price. It is not a small-print detail, because a reader who adds up a scan gets
a total over the priced checks only.

Read [the calibration statement](../README.md#the-calibration-statement) before
you quote any figure in this table or any figure the engine produces from this
pack.

<!-- pricing-counts:begin -->
| Version | Checks | Priced | Unpriced | Placeholder |
| :--- | ---: | ---: | ---: | ---: |
| `v1.0.0` | 3 | 3 | 0 | 0 |
| **Pack total** | **3** | **3** | **0** | **0** |

An unpriced check contributes GBP 0.00 to every total however often it
fails. Of 3 check(s) on this page, 3 are priced and 0 are not.
Written by `policy/frameworks/pricing-counts-test.sh`. Do not edit by hand.
<!-- pricing-counts:end -->
