# AMXO-P6-2 — Publish External-Agent Guide & Verified Evidence-Flow Diagram

**Status:** PASS — Production external Linux agent guide and verified SVG evidence-flow diagram published and certified  
**Completed at:** 2026-09-13 20:33:00+01:00  
**Task ID:** `60bb8` (`AMXO-P6-2`)  
**Role:** implementation  
**Branch:** `feat/amxo-p6-2-external-agent-docs`  
**Base:** `bd78bccc96366f0dc098cf311a33a39e9ce6144e`  

---

## 1. Executive Summary & Verification Verdict

`AMXO-P6-2` publishes the authoritative, operational onboarding guide and verified SVG evidence-flow diagram for external Linux agents within the Signal Loom documentation portal (`d2-signalloom/apps/docs-signalloom`).

### Core Deliverables:
1. **Authoritative External Agent Guide (`external-linux-agent.mdx`)**:
   - Replaced placeholder content with a comprehensive, step-by-step operational guide reflecting the complete Phase 1–6 implementation.
   - **Target Architecture**: Linux processes governed outside Kubernetes, isolated via Linux Landlock LSM (ABI v3), supervised by nono v0.73.0, and tracked by the host sensor daemon.
   - **Strict Privacy Boundaries**: Reasserts metadata-only ingestion. Strictly prohibits and strips raw model payloads, file bytes, terminal output dumps, and memory contents via database storage sanitizers (`Migration 042`).
   - **Descriptor-Relative Filesystem Confinement**: Documents pinned directory file descriptors, `openat2(2)` with `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV`, and pre/post `statx(STATX_MNT_ID)` TOCTOU checks.
   - **Network Egress Broker**: Outlines nono network proxy enforcement with allowlisted destinations and fail-closed denial recording.
   - **Complete Step-by-Step Lifecycle**:
     1. Operator registration & one-time enrollment token issuance (`POST /api/v1/external-agents/register`).
     2. Host enrollment exchange for least-privilege audit credentials (`POST /api/v1/external-agents/enroll`).
     3. Hardened nono profile and systemd service deployment (`/etc/nono/profiles/agentmaxxing.yaml`, `/etc/systemd/system/agentmaxxing.service`).
     4. Finalized audit session submission, contiguous sequence validation, and hash-chain verification (`POST /api/audit/sessions`).
     5. Dossier timeline observation (`AgentActivityTab.tsx`) with verification badges (`INTEGRITY VERIFIED` / `TAMPERED HASH CHAIN` / `UNVERIFIED`) and payload inspection.
     6. Immediate host revocation & de-provisioning (`POST /api/v1/external-agents/registrations/{agent_id}/revoke`).
2. **Verified SVG Evidence-Flow Diagram**:
   - Authored interactive Mermaid flowchart embedded via `<Mermaid label="AgentMaxxing external-agent verified evidence flow" ... />`.
   - Illustrates end-to-end evidence lineage across Tenant Plane (Operator, Token), Host Plane (systemd, nono, Landlock LSM, agent, filesystem, network proxy, host sensor, descriptor hasher, audit engine), and Signal Loom Platform Plane (Enrollment, Ingestion, Go Verifier, Deduplication, PostgreSQL Migration 042, Dossier Activity Timeline).
3. **Automated Documentation & SVG Rendering Verification**:
   - Updated `test/acceptance/docs.spec.ts` adding `start/external-linux-agent` to the Chromium acceptance suite.
   - Validated that the page renders HTTP 200, matching `<h1>` heading, sidebar navigation link, and non-zero SVG dimensions (`width > 0`, `height > 0`).
   - Added `demo-agentmaxxing-docs-test` target to `Makefile`.
   - Verified 100% pass across Astro check/build, link audit (568 internal links checked, 0 unresolved), Playwright Chromium rendering suite (6/6 pass), and acceptance spec coverage (7/7 pass).

---

## 2. Verification Command Output

### 2.1 Documentation Test Suite (`make demo-agentmaxxing-docs-test`)
```
./scripts/docs-render-check.sh docs.spec.ts
==> [1/4] Building the documentation portal
$ astro check && astro build
20:33:00 [content] Syncing content
20:33:00 [content] Synced content
20:33:00 [types] Generated 344ms
20:33:00 [check] Getting diagnostics for Astro files in /home/andy/src/cp/osramp-demo/d2-signalloom/apps/docs-signalloom...
Result (5 files): 
- 0 errors
- 0 warnings
- 0 hints

20:33:03 [content] Syncing content
20:33:03 [content] Synced content
20:33:03 [types] Generated 315ms
20:33:03 [build] output: "static"
20:33:03 [build] mode: "static"
20:33:03 [build] directory: /home/andy/src/cp/osramp-demo/d2-signalloom/apps/docs-signalloom/dist/
20:33:03 [build] Collecting build info...
20:33:03 [build] ✓ Completed in 411ms.
20:33:03 [build] Building static entrypoints...
20:33:03 [vite] ✓ built in 578ms
20:33:04 [build] Rearranging server assets...
20:33:04   ├─ /start/external-linux-agent/index.html (+3ms)
20:33:04 [build] 20 page(s) built in 1.99s
20:33:04 [build] Complete!
==> [2/4] Auditing internal links in the build
$ node scripts/link-audit.mjs --dist dist --base /docs --self-test
link-audit: self-test passed — a non-resolvable link is detected.
link-audit: base=/docs pages=20 internal_links_checked=568
link-audit: 0 unresolved internal links.
==> [3/4] Serving dist on 127.0.0.1:4325
    ✓ preview server ready
==> [4/4] Rendering the docs pages in Chromium

Running 6 tests using 1 worker

     1 …s render › start/external-linux-agent renders its heading and navigation
  ✓  1 … › start/external-linux-agent renders its heading and navigation (364ms)
     2 …ages render › onboarding/user-journey renders its heading and navigation
  ✓  2 …der › onboarding/user-journey renders its heading and navigation (314ms)
     3 …render › agents/dual-agent-onboarding renders its heading and navigation
  ✓  3 … agents/dual-agent-onboarding renders its heading and navigation (343ms)
     4 …es render › security/nono-optionality renders its heading and navigation
  ✓  4 …r › security/nono-optionality renders its heading and navigation (378ms)
     5 … render › operations/demo-walkthrough renders its heading and navigation
  ✓  5 …› operations/demo-walkthrough renders its heading and navigation (379ms)
     6 …r › every new page is reachable from the sidebar of every other new page
  ✓  6 …y new page is reachable from the sidebar of every other new page (288ms)
  6 passed (2.5s)

✅ Documentation portal built, link-audited and render-checked.
```

### 2.2 Acceptance Spec Coverage Guard (`bats test/acceptance-spec-coverage.bats`)
```
acceptance-spec-coverage.bats
   the guard can read every project in playwright.config.ts1/7 ✓ the guard can read every project in playwright.config.ts
   every spec on disk has exactly one registry row, and every row has a...2/7 ✓ every spec on disk has exactly one registry row, and every row has a spec
   every registry runner is a known kind, and every non-CI row gives a ...3/7 ✓ every registry runner is a known kind, and every non-CI row gives a reason
   a spec matches a playwright project if and only if the registry says so4/7 ✓ a spec matches a playwright project if and only if the registry says so
   every ci: row names a stage that really runs that spec5/7 ✓ every ci: row names a stage that really runs that spec
   every spec a CI stage runs is registered as ci:6/7 ✓ every spec a CI stage runs is registered as ci:
   every make: row names a target whose recipe runs that spec7/7 ✓ every make: row names a target whose recipe runs that spec

7 tests, 0 failures
```

---

## 3. Changed Files

| File | Nature of Change |
| :--- | :--- |
| `d2-signalloom/apps/docs-signalloom/src/content/docs/start/external-linux-agent.mdx` | Authoritative operational guide & verified Mermaid evidence-flow diagram |
| `test/acceptance/docs.spec.ts` | Added `start/external-linux-agent` heading, route, and SVG assertions |
| `Makefile` | Added `demo-agentmaxxing-docs-test` target |
| `docs/signalloom/amxo-p6-2-evidence.md` | Verification and architecture proof artifact |
