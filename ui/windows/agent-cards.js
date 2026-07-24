/* ===========================================================================
   Agent Registry. A local abstraction of the internal ARC registry: the agents
   in the estate listed together with their model, provider, skills and auth,
   each drilling into its committed A2A AgentCard rendered two ways (a
   Windows-95 card view and the raw JSON contract). Olly Sentinel and Orbit are
   live and served by the running cluster; Incident Triage and Knowledge MCP are
   reference peers. The broker serves each committed card at /api/agent-card/
   <name> and, for live agents, the running card at /api/agent-card/live/<name>.
   =========================================================================== */
"use strict";

Estate95.register({
  id: "agent-cards",
  title: "Agent Registry",
  icon: "🗂️",
  short: "Registry",
  width: 780,
  height: 640,

  open(body, api) {
    const h = api.h;

    // The registry holds, alongside each A2A card, the ARC governance metadata
    // that the card contract itself does not carry: visibility, owning team,
    // app id, framework, data classification, deployed environments, models,
    // and dependencies. This mirrors what ARC's internal registry shows.
    const REGISTRY = [
      { id: "olly-sentinel", label: "Olly Sentinel", icon: "🪪", status: "live",
        purpose: "Read-only RCA enrichment over 7 MCP tools",
        visibility: "Private", creator: "torin.vandenbulk", team: "GCO SRE Platform",
        appId: "APM-172472", framework: "Google ADK", dataClass: "Confidential",
        provider: "Vertex AI via ARC", models: ["gemini-2.5-flash"],
        environments: { "Dev / Sandbox": "live", "UAT / INT": "planned", "Prod": "Sep 2026" },
        dependencies: ["elk-search-mcp (7 tools)", "io-mapping-stub", "Redpanda", "Elasticsearch"],
        created: "2026-07-08", updated: "2026-07-20" },
      { id: "orbit", label: "Orbit", icon: "🛰️", status: "live",
        purpose: "LLM proposes one action; a signed human approval executes it",
        visibility: "Private", creator: "torin.vandenbulk", team: "GCO SRE Platform",
        appId: "APM-172472", framework: "Google ADK", dataClass: "Confidential",
        provider: "Vertex AI via ARC", models: ["gemini-2.5-flash"],
        environments: { "Dev / Sandbox": "live", "UAT / INT": "planned", "Prod": "Sep 2026" },
        dependencies: ["olly-sentinel (RCA input)", "ed25519 approval service", "action-proposal.v1"],
        created: "2026-07-19", updated: "2026-07-20" },
      { id: "incident-triage", label: "Incident Triage", icon: "🧭", status: "reference",
        purpose: "Fast front-line classify, score and route, before deep RCA",
        visibility: "Public", creator: "arc-platform", team: "GCO SRE Platform",
        appId: "APM-160104", framework: "Google ADK", dataClass: "Internal",
        provider: "Vertex AI via ARC", models: ["gemini-1.5-flash-8b (low-latency)"],
        environments: { "Dev / Sandbox": "live", "UAT / INT": "live", "Prod": "live" },
        dependencies: ["Netcool / NOI feed", "ServiceNow routing"],
        created: "2026-03-02", updated: "2026-07-11" },
      { id: "knowledge-mcp", label: "Knowledge MCP", icon: "📚", status: "reference",
        purpose: "Retrieval-augmented prior incidents and runbooks, with citations",
        visibility: "Public", creator: "arc-platform", team: "GCO Knowledge Platform",
        appId: "APM-158890", framework: "Google ADK", dataClass: "Internal",
        provider: "GCO Knowledge Platform", models: ["gemini-1.5-pro (long-context RAG)"],
        environments: { "Dev / Sandbox": "live", "UAT / INT": "live", "Prod": "live" },
        dependencies: ["ServiceNow MCP", "Confluence MCP", "vector index"],
        created: "2025-11-14", updated: "2026-06-30" },
    ];
    const modelLine = (a) => (a.models || []).join(", ");
    const meta = (id) => REGISTRY.find((a) => a.id === id) || {};
    const isLive = (id) => meta(id).status === "live";
    let current = "olly-sentinel";

    // The three fields that MUST match for "served == committed": the agent
    // name, the sorted set of skill ids, and the sorted set of read scopes.
    const skillIds = (card) =>
      (card && Array.isArray(card.skills) ? card.skills : [])
        .map((s) => s && s.id).filter(Boolean).sort();

    const scopes = (card) => {
      const out = [];
      const sec = (card && Array.isArray(card.security)) ? card.security : [];
      for (const entry of sec) {
        const list = entry && Array.isArray(entry.eems) ? entry.eems : [];
        for (const sc of list) if (sc) out.push(sc);
      }
      return Array.from(new Set(out)).sort();
    };

    const sameList = (a, b) =>
      a.length === b.length && a.every((v, i) => v === b[i]);

    // -- tab bar: Card view / JSON contract ---------------------------------
    let card = null;
    const guiHost = h("div", {});
    const jsonHost = h("div", { style: { display: "none" } });
    const tabGui = h("button", { class: "tab active" }, "Card view");
    const tabJson = h("button", { class: "tab" }, "JSON contract");

    function selectTab(which) {
      const gui = which === "gui";
      tabGui.classList.toggle("active", gui);
      tabJson.classList.toggle("active", !gui);
      guiHost.style.display = gui ? "" : "none";
      jsonHost.style.display = gui ? "none" : "";
    }
    tabGui.addEventListener("click", () => selectTab("gui"));
    tabJson.addEventListener("click", () => selectTab("json"));

    // -- registry table: every agent, click a row to open its card ----------
    body.appendChild(h("div", { class: "eyebrow" }, "Agent Registry · " + REGISTRY.length + " agents"));
    body.appendChild(h("p", { class: "muted", style: { fontSize: "12px", margin: "2px 0 8px" } },
      "The agents in the estate, the way ARC's registry lists them. Olly Sentinel and Orbit are served ",
      "by the running cluster; Incident Triage and Knowledge MCP are reference peers. Select a row to open its card."));

    const rowEls = {};
    const regRows = REGISTRY.map((a) => {
      const tr = h("tr", { class: "clickable", title: "Open " + a.label + " card" },
        h("td", { style: { whiteSpace: "nowrap" } },
          h("div", { class: "row", style: { gap: "6px", alignItems: "baseline" } },
            h("span", {}, a.icon), h("b", {}, a.label)),
          h("div", { class: "muted", style: { fontSize: "10px", lineHeight: "1.2" } }, a.purpose),
          h("div", { class: "muted", style: { fontSize: "10px" } }, "updated " + (a.updated || "—"))),
        h("td", {}, h("span", { class: "mono", style: { fontSize: "11px" } }, modelLine(a))),
        h("td", {}, h("span", { class: "muted", style: { fontSize: "11px" } }, a.team)),
        h("td", {}, a.status === "live" ? api.pill("live", "ok") : api.pill("reference", "plain")));
      tr.addEventListener("click", () => { if (current !== a.id) { current = a.id; syncSelector(); load(); } });
      rowEls[a.id] = tr;
      return tr;
    });
    function syncSelector() {
      for (const a of REGISTRY) rowEls[a.id].classList.toggle("active-row", a.id === current);
    }
    body.appendChild(h("div", { class: "tablewrap", style: { marginBottom: "10px" } },
      h("table", { class: "grid" },
        h("thead", {}, h("tr", {},
          h("th", {}, "Agent"), h("th", {}, "Model"), h("th", {}, "Team"), h("th", {}, "Status"))),
        h("tbody", {}, regRows))));

    body.appendChild(h("div", { class: "tabs" }, tabGui, tabJson));
    body.appendChild(h("div", { class: "tabpane" }, guiHost, jsonHost));

    // -- JSON contract view -------------------------------------------------
    function renderJson(card) {
      jsonHost.innerHTML = "";
      jsonHost.appendChild(h("p", { style: { fontSize: "12px", marginBottom: "6px" } },
        "The committed contract, served verbatim at ",
        h("code", {}, "/.well-known/agent-card.json"), " from ",
        h("code", {}, "contracts/agent-card.olly-sentinel.v1.json"),
        ". This is exactly what a peer agent or ARC reads and authenticates against."));
      jsonHost.appendChild(h("div", { class: "console", style: { maxHeight: "480px" } },
        h("span", { class: "u" }, JSON.stringify(card, null, 2))));
    }

    // -- Card view (the trading card) ---------------------------------------
    function renderGui(card) {
      guiHost.innerHTML = "";
      const skills = Array.isArray(card.skills) ? card.skills : [];
      const eems = (card.securitySchemes && card.securitySchemes.eems) || null;
      const grantedScopes = scopes(card);
      const org = (card.provider && card.provider.organization) || "unknown provider";
      const provUrl = card.provider && card.provider.url;

      const capPills = [];
      if (card.capabilities) {
        capPills.push(api.pill("streaming " + (card.capabilities.streaming ? "on" : "off"),
          card.capabilities.streaming ? "ok" : "plain"));
        capPills.push(api.pill("push " + (card.capabilities.pushNotifications ? "on" : "off"),
          card.capabilities.pushNotifications ? "ok" : "plain"));
      }
      if (card.preferredTransport) capPills.push(api.pill(card.preferredTransport, "info"));

      const m = meta(current);
      guiHost.appendChild(h("div", { class: "stack", style: { gap: "6px" } },
        h("div", { class: "eyebrow" }, "A2A Agent Card · committed contract"),
        h("div", { class: "row", style: { gap: "8px", alignItems: "baseline" } },
          h("h2", { style: { fontSize: "20px" } }, card.name || "(unnamed agent)"),
          api.pill("v" + (card.version || "?"), "info"),
          m.status === "live" ? api.pill("live", "ok") : api.pill("reference", "plain")),
        h("div", { class: "muted" }, org,
          provUrl ? h("span", {}, "  ·  ", h("code", {}, provUrl)) : null),
        capPills.length ? h("div", { class: "row" }, capPills) : null,
        card.description ? h("p", { style: { marginTop: "6px" } }, card.description) : null));

      // Registry metadata: the ARC governance record kept beside the card.
      const envPill = (name, state) =>
        h("span", { class: "row", style: { gap: "3px", alignItems: "center" } },
          api.pill(name, state === "live" ? "ok" : "plain"),
          state !== "live" ? h("span", { class: "muted", style: { fontSize: "10px" } }, "(" + state + ")") : null);
      const row = (k, v) => h("tr", {}, h("td", { style: { whiteSpace: "nowrap" } }, h("b", {}, k)), h("td", {}, v));
      guiHost.appendChild(api.groupbox("Registry entry (ARC governance record)",
        h("div", { class: "tablewrap" },
          h("table", { class: "grid" }, h("tbody", {},
            row("Visibility", api.pill(m.visibility || "Private", m.visibility === "Public" ? "info" : "plain")),
            row("Creator", m.creator || "—"),
            row("Team", m.team || org),
            row("App ID", h("span", { class: "mono", style: { fontSize: "12px" } }, m.appId || "—")),
            row("Framework", api.pill(m.framework || "Google ADK", "info")),
            row("Data classification", api.pill(m.dataClass || "Internal", m.dataClass === "Confidential" ? "warn" : "plain")),
            row("Models", h("span", { class: "mono", style: { fontSize: "12px" } }, modelLine(m) || "n/a")),
            row("Model provider", m.provider || org),
            row("Live environments", h("div", { class: "row", style: { gap: "6px", flexWrap: "wrap" } },
              ...Object.entries(m.environments || {}).map(([n, s]) => envPill(n, s)))),
            row("Dependencies", h("div", { class: "row", style: { gap: "4px", flexWrap: "wrap" } },
              ...(m.dependencies || []).map((d) => api.pill(d, "plain")))),
            row("Created", m.created || "—"),
            row("Last updated", m.updated || "—"),
            row("Runtime", m.status === "live" ? "Served by the running cluster" : "Reference peer, not deployed in this replica"),
            row("Purpose", m.purpose || "n/a"))))));

      // Skills
      const skillNodes = skills.length ? skills.map((s) => {
        const tags = (Array.isArray(s.tags) ? s.tags : []).map((t) => api.pill(t, "plain"));
        const examples = (Array.isArray(s.examples) ? s.examples : []);
        return h("div", { class: "stack", style: { gap: "5px", marginBottom: "10px" } },
          h("div", { class: "row", style: { gap: "8px", alignItems: "baseline" } },
            h("strong", {}, s.name || s.id || "(skill)"),
            s.id ? h("code", {}, s.id) : null),
          s.description ? h("div", { style: { fontSize: "12px" } }, s.description) : null,
          tags.length ? h("div", { class: "row" }, tags) : null,
          examples.length
            ? h("div", { class: "stack", style: { gap: "3px" } },
                h("div", { class: "muted", style: { fontSize: "11px" } }, "Example input"),
                h("div", { class: "console", style: { maxHeight: "120px" } },
                  examples.map((ex) => h("span", { class: "u" },
                    (typeof ex === "string" ? ex : JSON.stringify(ex)) + "\n"))))
            : null);
      }) : [h("div", { class: "muted" }, "This card declares no skills.")];
      guiHost.appendChild(api.groupbox("Skills", ...skillNodes));

      // Security: render every declared scheme. Orbit adds an approval_jwt
      // scheme (the signed-approval gate) alongside EEMS.
      const secChildren = [];
      const schemes = (card.securitySchemes && typeof card.securitySchemes === "object")
        ? Object.entries(card.securitySchemes) : [];
      if (schemes.length) {
        for (const [sname, s] of schemes) {
          const isApproval = /approval/i.test(sname);
          secChildren.push(h("div", { class: "row", style: { gap: "8px", alignItems: "baseline", marginTop: "4px" } },
            h("strong", {}, sname),
            api.pill("scheme: " + (s.scheme || s.type || "?"), isApproval ? "warn" : "info"),
            isApproval ? api.pill("human-in-the-loop", "warn") : null));
          if (s.description)
            secChildren.push(h("div", { style: { fontSize: "12px", marginTop: "2px" } }, s.description));
        }
      } else {
        secChildren.push(h("div", { class: "muted" }, "No security scheme declared."));
      }
      secChildren.push(h("div", { class: "muted", style: { fontSize: "11px", marginTop: "8px" } },
        "Granted read scopes (security[].eems)"));
      secChildren.push(grantedScopes.length
        ? h("div", { class: "row" }, grantedScopes.map((sc) => api.pill(sc, "ok")))
        : h("div", { class: "muted" }, "none"));
      guiHost.appendChild(api.groupbox("Security & auth", ...secChildren));

      // How A2A fits
      const point = (label, text) =>
        h("div", { class: "row", style: { gap: "8px", alignItems: "flex-start" } },
          api.pill(label, "info"),
          h("div", { style: { flex: "1 1 auto", fontSize: "12px" } }, text));
      guiHost.appendChild(api.groupbox("How A2A fits",
        h("div", { class: "stack", style: { gap: "7px" } },
          point("join key", "The correlation-ID is the join key across systems, never an INC number. INC numbers are minted later, downstream."),
          point("read-only", "Entitlements are read-only. EEMS grants read scopes only; this agent holds no write entitlement anywhere."),
          point("writes", "Ticket writes happen downstream, via the IO Mapping Service, never by this agent."),
          point("contract", "This one card is the deterministic contract ARC consumes. Categorization and auth flow from exactly what is declared here."))));

      // COIN auth + A2A security (extensible framework)
      guiHost.appendChild(api.groupbox("Auth with COIN, and the A2A security contract",
        h("p", { style: { fontSize: "12px", marginBottom: "6px" } },
          "The card's ", h("code", {}, "securitySchemes"),
          " is the extension point. In the estate, ARC enforces it; the replica declares it."),
        h("div", { class: "stack", style: { gap: "7px" } },
          point("COIN M2M", "The EEMS bearer is minted by COIN, the firm's machine-to-machine auth service, not a static token. A peer agent reads the card, gets a COIN token for role gco-sentinel-read, and calls message/send with it."),
          point("extensible", "Add mTLS or OAuth2 client-credentials, or new scopes, to securitySchemes without touching the skill or the pipeline. Peers negotiate from whatever the card declares."),
          point("authz", "Authorization stays least-privilege: read-only EEMS scopes on the card, and no write entitlement anywhere in the agent."),
          point("integrity", "served == committed is CI-asserted (pytest + bats), so a tampered card is caught before it ships."),
          point("audit", "Every MCP query and returned report writes a SIEM audit line under the acting role.")),
        h("div", { class: "muted", style: { fontSize: "11px", marginTop: "8px", lineHeight: "1.45" } },
          "Production posture (declared for the estate, not enforced in this replica): Vault-backed secrets, ",
          "COIN M2M auth, Tiramisu egress, SSL certs in prod, least-privilege Mongo scopes, audit logging.")));

      // Served vs. committed: only live agents serve a running card to diff.
      if (isLive(current)) {
        const verifyOut = h("div", { class: "stack", style: { marginTop: "10px" } });
        const verifyBtn = h("button", { class: "btn" }, "Verify live");
        verifyBtn.addEventListener("click", () => verifyLive(card, verifyBtn, verifyOut));
        guiHost.appendChild(api.groupbox("Served vs. committed",
          h("p", { style: { fontSize: "12px" } },
            "Fetch the card the running agent serves and diff the key contract fields ",
            "(name, skill ids, and read scopes) against the committed card above."),
          h("div", { class: "row" }, verifyBtn),
          verifyOut));
      } else {
        guiHost.appendChild(api.groupbox("Served vs. committed",
          h("p", { class: "muted", style: { fontSize: "12px" } },
            "Reference peer: no running instance in this replica, so there is no served card to diff. ",
            "The committed contract above is what a peer would discover.")));
      }
    }

    // -- verify the live-served card against committed ----------------------
    async function verifyLive(committed, btn, out) {
      out.innerHTML = "";
      btn.disabled = true;
      const prev = btn.textContent;
      btn.textContent = "Checking…";

      let live;
      try {
        live = await api.get("/api/agent-card/live/" + current);
      } catch (err) {
        if (err.status === 503) {
          const detail = err.body && (err.body.detail || err.body.error);
          out.appendChild(h("div", { class: "notice" },
            h("div", {},
              h("strong", {}, "Cluster not ready. "),
              "The live agent isn't serving its card yet" + (detail ? " (" + detail + ")" : "") +
              ". The committed contract above is still valid.")));
        } else {
          out.appendChild(h("div", { class: "notice err" }, "Live fetch failed: " + err.message));
        }
        btn.disabled = false;
        btn.textContent = prev;
        return;
      }

      const diffs = [];
      if ((committed.name || "") !== (live.name || ""))
        diffs.push(`name: committed "${committed.name || ""}" != served "${live.name || ""}"`);
      const cIds = skillIds(committed), lIds = skillIds(live);
      if (!sameList(cIds, lIds))
        diffs.push(`skill ids: committed [${cIds.join(", ")}] != served [${lIds.join(", ")}]`);
      const cScopes = scopes(committed), lScopes = scopes(live);
      if (!sameList(cScopes, lScopes))
        diffs.push(`read scopes: committed [${cScopes.join(", ")}] != served [${lScopes.join(", ")}]`);

      if (!diffs.length) {
        out.appendChild(h("div", { class: "row" },
          api.pill("✓ served == committed", "ok"),
          h("span", { class: "muted", style: { fontSize: "12px" } },
            "name, skill ids and read scopes all match.")));
      } else {
        out.appendChild(h("div", { class: "row" },
          api.pill("✗ " + diffs.length + " difference" + (diffs.length > 1 ? "s" : ""), "crit")));
        out.appendChild(h("div", { class: "tablewrap" },
          h("table", { class: "grid" },
            h("thead", {}, h("tr", {}, h("th", {}, "Field mismatch"))),
            h("tbody", {}, diffs.map((d) => h("tr", {}, h("td", {}, h("code", {}, d))))))));
      }

      btn.disabled = false;
      btn.textContent = prev;
    }

    // -- load the committed card, render both views -------------------------
    async function load() {
      guiHost.innerHTML = "";
      guiHost.appendChild(h("div", { class: "eyebrow" }, "Loading committed agent card…"));
      try {
        card = await api.get("/api/agent-card/" + current);
      } catch (err) {
        guiHost.innerHTML = "";
        guiHost.appendChild(h("div", { class: "notice err" },
          "Could not load the committed agent card: " + err.message));
        return;
      }
      renderGui(card);
      renderJson(card);
    }

    load();
  },
});
