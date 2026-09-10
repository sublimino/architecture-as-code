# SFAS-P2-1 Identity Tab Authorization Chain DOM Fixtures & Evidence

**Task ID:** SFAS-P2-1  
**Artifact:** `docs/signalloom/sfas-p2-1-identity-tab-evidence.md`  
**Focus:** DOM Fixtures, Stepped Layout Snapshots, Component Hierarchy & Accessibility  

---

## 1. Tab 2 (Identity & SPIFFE) DOM Architecture & Component Tree

When an operator navigates to `/agents/:id?tab=identity`, `AgentDetailPage` renders `AgentIdentityTab`. Embedded within Tab 2 is `WhoAuthorizedPanel`, bound directly to the active agent ID and rendering the multi-node stepped delegation hierarchy:

```html
<div data-testid="dossier-panel-identity" role="tabpanel" id="dossier-tabpanel-identity">
  <!-- Deep Link Navigation -->
  <div class="identity-deeplink-bar">
    <a data-testid="identity-deeplink-credentials" href="/credential-inventory?actor=...">Credential Inventory ↗</a>
    <a data-testid="identity-deeplink-crypto" href="/cryptography?actor=...">Cryptography ↗</a>
    <a data-testid="identity-deeplink-topology" href="/agent-trust-topology?actor=...">Trust Topology ↗</a>
  </div>

  <!-- 4 StatCards Grid -->
  <div class="identity-statcards-grid">
    <div class="card" data-testid="identity-card-spiffe">...</div>
    <div class="card" data-testid="identity-card-cert">...</div>
    <div class="card" data-testid="identity-card-selectors">...</div>
    <div class="card" data-testid="identity-card-custody">...</div>
  </div>

  <!-- Panel 1: SVID Selectors -->
  <div class="card" data-testid="identity-panel-selectors">...</div>

  <!-- SFAS-P2-1 Embedded 7-Hop Attested Authorization Chain Panel -->
  <div data-testid="identity-tab-who-authorized-wrapper">
    <div class="card" data-testid="who-authorized-panel">
      <!-- Header with completeness badge and resolution fidelity -->
      <div class="panel-header">
        <h3>🛡️ Who Authorized This Action?</h3>
        <span data-testid="chain-completeness-badge">COMPLETE ATTESTED CHAIN</span>
        <span data-testid="kpi-fraction-metric">Resolution Fidelity: 95%</span>
      </div>

      <!-- Hop 1: Observed Action -->
      <div data-testid="hop-action">Invoice batch processing / Outbound TLS</div>

      <!-- Hop 2: Agent Identity -->
      <div data-testid="hop-agent-identity">
        <a data-testid="hop-agent-identity-link" href="/agents/agent-cardvault?tab=overview">
          spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-invoice-bot
        </a>
      </div>

      <!-- Hop 3: Acts-On-Behalf-Of & Stepped Multi-Node Delegation Hierarchy -->
      <div data-testid="hop-acts-on-behalf-of">
        sa/sa-invoice-bot acts-on-behalf-of ops@acme.com via chain [Planner -> Pipeline -> Agent]
      </div>
      <div data-testid="delegation-stepped-path">
        <!-- Node 1: Human Principal -->
        <div data-testid="delegation-node-0" role="button" tabindex="0" aria-label="Delegation hop 1 of 4: Human Principal ops@acme.com">
          <span data-testid="delegation-node-step-0">Hop 1 / 4</span>
          <span class="tag">Human Principal</span>
          <div data-testid="delegation-node-id-0">ops@acme.com</div>
        </div>
        <div aria-hidden="true">➔</div>

        <!-- Node 2: Planner / Orchestrator -->
        <div data-testid="delegation-node-1" role="button" tabindex="0" aria-label="Delegation hop 2 of 4: Planner / Orchestrator agent-planner-service">
          <span data-testid="delegation-node-step-1">Hop 2 / 4</span>
          <span class="tag">Planner / Orchestrator</span>
          <div data-testid="delegation-node-id-1">agent-planner-service</div>
          <span data-testid="delegation-node-landlock-1" class="tag">🔒 Landlock Enforced</span>
        </div>
        <div aria-hidden="true">➔</div>

        <!-- Node 3: Pipeline Agent -->
        <div data-testid="delegation-node-2" role="button" tabindex="0">
          <span data-testid="delegation-node-step-2">Hop 3 / 4</span>
          <span class="tag">Pipeline Agent</span>
          <div data-testid="delegation-node-id-2">pipeline-data-bridge</div>
          <span data-testid="delegation-node-landlock-2" class="tag">🔒 Landlock Enforced</span>
        </div>
        <div aria-hidden="true">➔</div>

        <!-- Node 4: Executing Agent -->
        <div data-testid="delegation-node-3" role="button" tabindex="0">
          <span data-testid="delegation-node-step-3">Hop 4 / 4</span>
          <span class="tag">Executing Agent</span>
          <div data-testid="delegation-node-id-3">spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-invoice-bot</div>
          <span data-testid="delegation-node-spiffe-3" class="tag">SPIFFE SVID</span>
          <span data-testid="delegation-node-landlock-3" class="tag">🔒 Landlock Enforced</span>
        </div>
      </div>

      <!-- Hop 4: Authorizing Principal -->
      <div data-testid="hop-principal">ops@acme.com</div>

      <!-- Hop 5: Policy Decision -->
      <div data-testid="hop-decision">AUTHORIZED:ACTIONABLE</div>

      <!-- Hop 6: Confidence & Evidence References -->
      <div data-testid="hop-confidence">Score: 95.0% confidence</div>
      <div data-testid="hop-evidence-refs">
        <span>obs-id-001</span>
        <span>k8s-audit://default/secrets/vault-token</span>
      </div>

      <!-- Hop 7: Attestation GitOID -->
      <div data-testid="hop-attestation-gitoid">e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855</div>
      <button data-testid="copy-gitoid-button">Copy GitOID</button>
      <a data-testid="rekor-explorer-link" href="https://search.sigstore.dev/?hash=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855">Rekor Attestation ↗</a>
    </div>
  </div>

  <!-- Panel 2: Delegation Chain & Separation of Identity Planes -->
  <div class="card" data-testid="identity-panel-delegation">...</div>
  <!-- Panel 3: OpenBao Integration -->
  <div class="card" data-testid="identity-panel-vault">...</div>
  <!-- Panel 4: Live Origin Verification -->
  <div class="card" data-testid="identity-panel-origin-verification">...</div>
</div>
```

---

## 2. Interactive Node Drill-Down Modal DOM Structure

Clicking or pressing `Enter`/`Space` on any delegation node opens the accessible dialog modal:

```html
<div data-testid="delegation-drilldown-modal-1" role="dialog" aria-modal="true" aria-labelledby="modal-title-1">
  <h3 id="modal-title-1">Planner / Orchestrator Verification</h3>
  <button data-testid="close-modal-1" aria-label="Close delegation modal">✕ Close</button>
  <div data-testid="modal-actor-id-1">agent-planner-service</div>
  <div data-testid="modal-spiffe-id-1">spiffe://cluster.local/ns/fe-signalloom/sa/planner-sa</div>
  <div data-testid="modal-authz-ref-1">k8s-rbac:planner-role-binding</div>
  <div data-testid="modal-valid-from-1">15 Aug 2026, 01:00</div>
  <div data-testid="modal-valid-to-1">15 Aug 2026, 12:00</div>
  <div data-testid="modal-containment-1">✓ Verified active via agent-nono-evidenced eBPF/Landlock probes</div>
</div>
```

---

## 3. Adversarial Cycle Detected Alert DOM Structure

When an adversarial circular delegation cycle is encountered in the graph:

```html
<div data-testid="cycle-detected-warning" role="alert" aria-live="assertive">
  <span data-testid="cycle-detected-badge">CYCLE BLOCKED</span>
  <p data-testid="cycle-detected-message">
    Adversarial circular delegation cycle detected in delegation graph. Chain traversal clamped to prevent infinite recursion.
  </p>
  <div data-testid="cycle-detected-path">Cycle: agent-a ➔ agent-b ➔ agent-a</div>
</div>
```

---

## 4. Accessibility & Responsive Styling Compliance (WCAG 2.1 AA)

- **Keyboard Navigation**: All interactive chain nodes are focusable (`tabIndex={0}`) and trigger drill-down on `Enter` / `Space`. `Escape` key closes the dialog modal and returns focus.
- **ARIA Semantics**: `role="button"`, `aria-haspopup="dialog"`, `aria-expanded`, `role="dialog"`, `aria-modal="true"`, `role="alert"`, `aria-live="assertive"`.
- **Responsive Flex-Wrap**: `.delegation-stepped-path` utilizes `flex-wrap: wrap` with `min-width: 190px` to prevent horizontal layout overflow on tablet and mobile viewports.
- **Color Contrast**: Complies with 4.5:1 text-to-background contrast ratio using tokens from `styles/tokens.ts` in Signal Loom dark mode.
