/* ===========================================================================
   Eval Lab, RCA evals & scorecard.
   Reads /api/eval-history and lays out:
     1. Agent vs human, the scorecard (human stays "awaiting baseline").
     2. Run history, every eval run, with passed/failed counts.
     3. Run eval, streams the deterministic signal-check GATE plus the ADK
        rca_readiness eval into a shared console, then refreshes the ledger.
     4. What the evals actually measure, and the fairness caveats.
   Survives a down cluster (503) by showing a red banner and empty states.
   =========================================================================== */
"use strict";

Estate95.register({
  id: "eval-lab",
  title: "Eval Lab",
  icon: "📊",
  short: "Eval Lab",
  width: 820,
  height: 600,

  open(body, api) {
    const h = api.h;

    // -- cell pill helpers ---------------------------------------------------
    // Agent column: real measured values read as "ok"; anything empty or still
    // pending falls back to a neutral "plain" chip.
    function agentPill(v) {
      const s = v == null ? "" : String(v).trim();
      if (!s || /awaiting/i.test(s)) return api.pill(s || "-", "plain");
      return api.pill(s, "ok");
    }
    // Human column: "awaiting baseline" is the honest default, a warn chip.
    function humanPill(v) {
      const s = v == null ? "" : String(v).trim();
      if (!s) return api.pill("-", "plain");
      if (/awaiting/i.test(s)) return api.pill(s, "warn");
      return api.pill(s, "plain");
    }

    // -- header --------------------------------------------------------------
    body.appendChild(h("div", { class: "stack", style: { gap: "4px" } },
      h("div", { class: "eyebrow" }, "RCA evals · agent vs human"),
      h("h3", {}, "Does the root-cause agent hold up?"),
      h("p", { class: "muted" },
        "Every run scores the agent's RCA enrichment against a seeded incident. ",
        "The deterministic signal-check is the pass/fail gate; the ADK ROUGE / response-match ",
        "score is the softer surface on the ADK Eval tab.")));

    // -- error banner host (filled only when a fetch fails) ------------------
    const errHost = h("div", {});
    body.appendChild(errHost);

    // -- (1) Agent vs human scorecard ---------------------------------------
    const scoreHost = h("div", {}, h("div", { class: "muted" }, "Loading scorecard…"));
    body.appendChild(api.groupbox("Agent vs human", scoreHost));

    function renderScorecard(scorecard) {
      scoreHost.innerHTML = "";
      const rowsData = Array.isArray(scorecard) ? scorecard : [];
      if (!rowsData.length) {
        scoreHost.appendChild(h("div", { class: "muted" },
          "No scorecard yet. Run an eval to populate the agent column."));
        return;
      }
      const rows = rowsData.map((m) =>
        h("tr", {},
          h("td", {}, m && m.metric != null ? String(m.metric) : "-"),
          h("td", {}, agentPill(m && m.agent)),
          h("td", {}, humanPill(m && m.human)),
          h("td", {}, h("span", { class: "mono", style: { fontSize: "11px" } },
            m && m.source != null ? String(m.source) : "-"))));
      scoreHost.appendChild(h("div", { class: "tablewrap" },
        h("table", { class: "grid" },
          h("thead", {}, h("tr", {},
            h("th", {}, "Metric"),
            h("th", {}, "Agent"),
            h("th", {}, "Human"),
            h("th", {}, "Source"))),
          h("tbody", {}, ...rows))));
      scoreHost.appendChild(h("div", { class: "muted", style: { fontSize: "11px", marginTop: "6px" } },
        "The human column stays “awaiting baseline” until labelled real-incident data lands."));
    }

    // -- (2) Run history -----------------------------------------------------
    const runsHost = h("div", {}, h("div", { class: "muted" }, "Loading run history…"));
    body.appendChild(api.groupbox("Run history", runsHost));

    function renderRuns(runs) {
      runsHost.innerHTML = "";
      const rowsData = Array.isArray(runs) ? runs : [];
      if (!rowsData.length) {
        runsHost.appendChild(h("div", { class: "notice" },
          h("span", {}, "🗒️"),
          h("div", {}, "No eval runs yet. Click ", h("b", {}, "Run eval"), " below.")));
        return;
      }
      const rows = rowsData.map((r) => {
        const passed = r && r.passed != null ? r.passed : 0;
        const failed = r && r.failed != null ? r.failed : 0;
        const failedPill = Number(failed) > 0
          ? api.pill(String(failed), "crit")
          : api.pill(String(failed), "plain");
        const name = (r && (r.name || r.file)) || "eval run";
        const sub = r && r.file && r.file !== name
          ? h("span", { class: "muted mono", style: { fontSize: "11px" } }, String(r.file))
          : null;
        return h("tr", {},
          h("td", {}, h("div", { class: "stack", style: { gap: "1px" } },
            h("b", {}, String(name)), sub)),
          h("td", { class: "right tnum" }, r && r.cases != null ? String(r.cases) : "-"),
          h("td", {}, api.pill(String(passed), "ok")),
          h("td", {}, failedPill));
      });
      runsHost.appendChild(h("div", { class: "tablewrap", style: { maxHeight: "200px" } },
        h("table", { class: "grid" },
          h("thead", {}, h("tr", {},
            h("th", {}, "Run"),
            h("th", { class: "right" }, "Cases"),
            h("th", {}, "Passed"),
            h("th", {}, "Failed"))),
          h("tbody", {}, ...rows))));
    }

    // -- note from /api/eval-history ----------------------------------------
    const noteHost = h("div", { style: { marginTop: "2px" } });
    body.appendChild(noteHost);

    function renderNote(note) {
      noteHost.innerHTML = "";
      const s = note == null ? "" : String(note).trim();
      if (!s) return;
      noteHost.appendChild(h("div", { class: "notice" },
        h("span", {}, "ℹ️"),
        h("div", {}, s)));
    }

    // -- (3) Run eval --------------------------------------------------------
    const consoleEl = h("div", { class: "console", style: { minHeight: "140px", maxHeight: "240px" } },
      h("span", { class: "dim" },
        "Idle. Click Run eval to stream the deterministic signal-check gate and the ADK rca_readiness eval here.\n"));

    const runStatus = h("span", { class: "muted mono" }, "Idle");
    const runBtn = h("button", { class: "btn" }, "Run eval");
    const clearBtn = h("button", { class: "btn", onclick: () => {
      consoleEl.innerHTML = "";
      consoleEl.appendChild(h("span", { class: "dim" }, "Cleared.\n"));
    } }, "Clear");

    runBtn.addEventListener("click", () => {
      runBtn.disabled = true;
      runStatus.textContent = "Running eval: signal-check gate + ADK rca_readiness…";
      runStatus.className = "mono";
      api.runAction("olly-eval", consoleEl, (code) => {
        runBtn.disabled = false;
        const ok = code === 0;
        runStatus.textContent = (ok ? "Eval passed (exit 0)" : "Eval failed (exit " + code + ")") +
          ". Refreshing ledger…";
        runStatus.className = "mono";
        load();
      });
    });

    body.appendChild(api.groupbox("Run eval",
      h("p", { class: "muted", style: { marginBottom: "6px" } },
        "Runs ", h("code", { class: "mono" }, "make olly-eval"),
        " on the broker: the deterministic signal-check gate first, then the ADK ",
        h("code", { class: "mono" }, "rca_readiness"), " eval. Output streams below; the ledger refreshes on exit."),
      h("div", { class: "row", style: { justifyContent: "space-between", marginBottom: "6px" } },
        h("div", { class: "row" }, runBtn, clearBtn),
        runStatus),
      consoleEl));

    // -- (4) What the evals measure -------------------------
    const point = (label, kind, text) =>
      h("div", { class: "row", style: { gap: "8px", alignItems: "flex-start", padding: "1px 0" } },
        api.pill(label, kind),
        h("div", { style: { flex: "1 1 auto", fontSize: "12px" } }, text));

    body.appendChild(api.groupbox("What the evals actually measure",
      h("div", { class: "stack", style: { gap: "6px" } },
        point("built from RCA", "info",
          "Each eval scores the agent's RCA enrichment for a seeded incident, not free text. Three checks have to hold."),
        point("check 1 · fault domain", "plain",
          "The enrichment's fault_domain must match the fault domain of the seeded incident."),
        point("check 2 · evidence", "plain",
          "Exactly 3 pieces of evidence, each a read-only ELK (Elasticsearch) query pattern. No writes, no side effects."),
        point("check 3 · redaction", "plain",
          "Every planted secret in the source data must be redacted out of the enrichment."),
        point("the real gate", "ok",
          "The deterministic signal-check is the pass/fail gate. It is exact and repeatable. That is what decides green or red."),
        point("Eval-tab surface", "info",
          "The ADK ROUGE / response-match score is the softer, model-graded view on the ADK Eval tab. It is a surface, not the gate."),
        point("fairness caveat", "warn",
          "Any “minutes vs hours” speed-up is measured on seeded, hindsight-clean data, not a live production comparison. Read it as directional, not a benchmark."),
        point("awaiting baseline", "warn",
          "The human column stays “awaiting baseline” until labelled real-incident data lands to score analysts against."))));

    // -- load / refresh the ledger ------------------------------------------
    async function load() {
      let data;
      try {
        data = await api.get("/api/eval-history");
      } catch (err) {
        errHost.innerHTML = "";
        errHost.appendChild(h("div", { class: "notice err" },
          err && err.message ? err.message : "Could not load the eval history."));
        renderScorecard(null);
        renderRuns(null);
        renderNote(null);
        return;
      }
      errHost.innerHTML = "";
      data = data || {};
      renderScorecard(data.scorecard);
      renderRuns(data.runs);
      renderNote(data.note);
    }

    load();
  },
});

