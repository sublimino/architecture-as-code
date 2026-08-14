# Adversarial Critique: Tooltip and Documentation Platform

## Review Scope

This review attacks `tooltip-docs-platform-plan.md` before implementation. It
covers security, interaction design, React integration, static-site delivery,
verification, documentation governance, and long-term operating cost.

## Decision

**Do not implement the plan unchanged.**

The central idea is sound. A route-owned `docId`, docs-owned help content, and
parity checks are stronger than manually duplicated tooltip strings. The plan
is not yet safe to build because it leaves interaction semantics, build
ownership, path behavior, release compatibility, and content governance
unspecified.

## What Survives Review

- The dashboard should own the list of renderable page routes.
- Page-help metadata should come from documentation content, not duplicate UI
  strings.
- The checker should reject missing, duplicate, and orphaned mappings.
- Existing local-control `HelpHint` content should stay separate from page help.
- A direct Gateway route is preferable to proxying documentation through the
  dashboard server.
- Starlight is acceptable if content remains portable Markdown and adapters are
  isolated.

## Release Blockers

### B1. Treat page help as an interactive popover

**Severity:** Blocker  
**Plan sections:** User Experience; Canonical Content Contract  
**Evidence:** `HelpHint.tsx` sets `pointerEvents: none` and closes on trigger
blur. It cannot contain a clickable `More help` link.

The planned control is not a tooltip once it includes a link. It needs a
durable click, tap, and keyboard interaction model.

**Change:** Create a new `PageHelpPopover`. Do not reuse `HelpHint` beyond its
geometry utility. The control must use `aria-expanded` and `aria-controls`,
open through click, Enter, and Space, keep a focusable link, close through
Escape and outside click, restore focus to the trigger, close on route change,
and work without hover.

**Owner:** Dashboard engineering and design.

### B2. Define generated help artifact ownership

**Severity:** Blocker  
**Plan sections:** Canonical Content Contract; Drift Prevention; Delivery
Sequence  
**Evidence:** The dashboard Docker build context is
`apps/dashboard-signalloom`. A generator under the proposed sibling docs app is
not available during that build.

The dashboard cannot safely import an artifact that only a sibling image build
creates. A clean build will fail or use a stale committed copy.

**Change:** Add a root-owned deterministic `page-help` contract command. It
reads framework-neutral Markdown frontmatter and writes a committed
`apps/dashboard-signalloom/src/generated/pageHelp.ts`. Dashboard typecheck,
test, and image build must run the command first. CI must regenerate into a
temporary location and fail when the committed output differs. Put the schema,
generator, and checker under root `scripts/` or a neutral shared package.

**Owner:** Platform engineering.

### B3. Preserve complete route behavior in the catalogue

**Severity:** Blocker  
**Plan sections:** Canonical Content Contract; Delivery Sequence  
**Evidence:** `/onboarding` and `/help/connectors/:provider` require
`ProtectedRoute` exemptions. `/fleet/audience` passes `audience` to its page.

A catalogue that stores only a lazy component loses protected-route flags and
page props. This can cause onboarding loops or render the wrong Fleet view.

**Change:** Make each catalogue entry contain the complete existing route
element, not only a component constructor. Add route behavior tests for
onboarding, connector help, both Fleet modes, and authentication boundaries
before moving routes.

**Owner:** Dashboard engineering.

### B4. Specify one end-to-end `/docs` path contract

**Severity:** Blocker  
**Plan sections:** Container and Delivery Design; Verification Plan  
**Evidence:** Existing Gateway routing includes dashboard `PathPrefix: /`.
Gateway forwards paths unchanged. The plan does not choose Astro base-path,
nginx filesystem layout, or rewrite behavior.

Without one contract, `/docs/current/pages/agents/` can return the dashboard
SPA or a static-file `404` while local builds pass.

**Change:** Set Astro `base: '/docs/current/'`. Copy the generated site to
`/usr/share/nginx/html/docs/current/`. Use no Gateway rewrite. Add explicit
redirects from `/docs` and `/docs/` to `/docs/current/`. Keep docs `404`
responses in the docs workload. Test HTML, deep pages, assets, search data,
canonical links, trailing slashes, encoded paths, and an unknown path through
the TLS Gateway.

**Owner:** Platform engineering.

### B5. Define release compatibility and rollback

**Severity:** Blocker  
**Plan sections:** URL and versions; Container and Delivery Design; Delivery
Sequence; Explicit Deferrals  
**Evidence:** `/docs/current/` is presented as canonical while history and
rollback are deferred. Same tags do not create atomic multi-image releases.

Dashboard help can link to documentation from a different release after a
partial deployment, cache issue, or rollback.

**Change:** Use a signed release manifest that names immutable dashboard and
docs image digests plus the generated help-manifest hash. Promote and roll back
that manifest as one Git change. Embed release identity in both outputs and
check compatibility after deployment. Initially use `/docs/` as the stable
entry point. Add immutable `/docs/<release>/` before calling `current`
canonical. Define retention and backport policy.

**Owner:** Release engineering and product owner.

### B6. Classify documentation exposure before publishing

**Severity:** Blocker  
**Plan sections:** Scope; Container and Delivery Design; Explicit Deferrals  
**Evidence:** Planned coverage includes protected administrative, connector,
network-test, SuperCredential, and Fleet routes. Authentication is deferred.

Public page documentation can disclose capability topology, unfinished demos,
or operational assumptions.

**Change:** Add `visibility: public | customer | operator | demo` to document
metadata. Build public and authenticated documentation sets separately. Do not
publish operator or demo content by default. Add unauthenticated Gateway tests
for each visibility class. Treat robots controls as indexing help, not access
control.

**Owner:** Product security and product owner.

## High-Priority Changes

| ID | Change | Failure prevented | Owner |
|---|---|---|---|
| H1 | Use a strict lower-case slug grammar for `docId`. Construct hrefs from fixed path segments and encoded values. | Link traversal, invalid paths, ambiguous URLs. | Dashboard engineering |
| H2 | Validate frontmatter through a typed schema. Treat tooltip content as text. Generate TypeScript with a serializer. Disallow unsafe MDX and HTML by default. | Stored XSS and generated-code injection. | Docs platform |
| H3 | Update route-collision tests to read the catalogue. Add static-over-dynamic overlap tests using `matchPath` and `end: true`. | Wrong help on overlapping routes. | Dashboard engineering |
| H4 | Make the dashboard image run generation, contract check, and TypeScript before Vite. | A dashboard image bypasses contract failure. | Build engineering |
| H5 | Pin deployments to verified immutable digests. Compare pod image IDs to attested digests. | Signed tags run different bytes. | Release engineering |
| H6 | Put `/docs` and dashboard `/` matching behavior under one explicit Gateway precedence contract. | Docs fall through to SPA. | Platform engineering |
| H7 | Use ingress-only docs NetworkPolicy unless a server-side caller exists. Select only Gateway proxy identity and docs port. | Unneeded lateral access or 504 failures. | Security engineering |
| H8 | Add a shared `PageHeader` contract with one `h1` and one page-help trigger. | Inconsistent placement and duplicate controls. | Design systems |
| H9 | Add local documentation search in the first release. Keep it telemetry-free. | Canonical help becomes undiscoverable as content grows. | Docs platform |
| H10 | Add ownership, review date, product version, and evidence references to security-sensitive documents. | Structurally valid but false or stale guidance. | Product, security, docs |

## Medium-Priority Changes

### Interaction and Accessibility

- Use visible `Page help` text at compact breakpoints or otherwise improve the
  discoverability of a lone question icon.
- Set bounded popover height, internal scrolling, safe-area margins, zoom
  checks, visual-viewport repositioning, and no nonessential motion.
- Open `More help` in the same tab. Give docs a contextual safe return link.
  Move focus to the documentation `main` landmark or `h1` after navigation.
- Define page-help behavior during loading, errors, not-found states, and
  dynamic detail routes.

### Documentation Information Architecture

- Keep route documents concise, but do not limit task guidance to 250 words.
  Add distinct task guides for setup, investigation, remediation, evidence
  export, and limitations where the work is consequential.
- Organize global navigation by reader task: Evaluate, Deploy, Operate,
  Investigate, Govern, and Reference. Keep page documents in Reference.
- Establish a governed glossary for agent, identity, policy, evidence, trust,
  posture, and credential. Define excluded synonyms and named owners.
- Separate philosophy, verified product behavior, and roadmap. Do not make
  regulated-industry claims without product evidence.
- Define user personas and top tasks before drafting all page documents.

### Delivery and Operations

- Reuse the existing hardened workload pattern fully: non-root user,
  read-only filesystem, writable temporary mount where nginx needs it,
  probes, resource bounds, and `/readyz`.
- Add CSP, `X-Content-Type-Options`, frame protection, referrer policy, and
  path-specific cache policy. Cache fingerprinted assets only. Do not cache
  HTML, the help manifest, search data, or mutable entry points as immutable.
- Expose docs availability, route 4xx and 5xx, latency, rollout state, and
  cache-header signals. Define an operational owner and a maintenance budget.
- Keep content framework-neutral. Isolate Starlight adapters and document a
  static-export replacement path.

## Verification Amendments

The release gate needs the following additions:

1. Table-driven checker fixtures for missing, duplicate, malformed, unsafe,
   orphaned, stale, static-over-dynamic, and reserved-path cases.
2. Stable checker diagnostics that include source path, route, `docId`, and a
   specific fix action.
3. A clean-checkout command that generates help, builds Starlight, typechecks
   the dashboard, and builds both images.
4. Reproducibility testing that runs the generator twice and byte-compares
   output.
5. Image checks for non-root execution, deep pages, 404 behavior, correct
   content types, and docs identity markers.
6. TLS Gateway checks for `/docs`, `/docs/`, `/docs/current/`, deep pages,
   assets, invalid paths, and dashboard separation. Reject dashboard `id=root`
   in docs responses.
7. Fail-closed docs tests. A missing port-forward, missing tool, or BATS skip
   must fail the release gate.
8. Browser checks for click, touch, keyboard, Escape, focus return, focusable
   links, screen-reader semantics, zoom, reduced motion, one trigger per page,
   dynamic routes, and docs return navigation.
9. Runtime network checks for Gateway-to-docs allowed and unrelated pod-to-docs
   denied.
10. Post-deploy smoke checks for Flux readiness, Deployment availability,
    Service endpoints, HTTPRoute `Accepted` and `ResolvedRefs`, image digests,
    release manifest identity, and rollback recovery.

## Strategic Adjustment

The plan should use two gates.

**Gate one, prove page help value.** Run a reversible three-route experiment on
high-confusion routes. Measure task completion, help engagement, follow-through,
and support reduction. Use concise human-reviewed content. Do not add a
separate workload before this gate passes.

**Gate two, build the documentation platform.** Proceed only after the release,
security, content-ownership, and operating-cost contracts above are accepted.

This preserves the philosophy. Governance should guide action. The help system
must itself be governed by evidence, bounded exposure, accountable ownership,
and reversible delivery.

## Explicit Deferrals

Decide these before or at the relevant gate, not silently during implementation:

- public versus authenticated documentation scope
- immutable version and retention policy
- release manifest format and promotion workflow
- content owner matrix and review expiry period
- docs search engine and telemetry posture
- localization URL and glossary model
- future AI documentation generation controls
- three-year maintenance budget and retirement trigger

## Review Evidence

Independent security, design, engineering, architecture, documentation,
verification, and long-horizon reviewers converged on the release blockers.
The exact evidence and source references are recorded in the critique tasks and
the accompanying work PRD.
