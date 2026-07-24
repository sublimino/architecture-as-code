/* ===========================================================================
   Estate 95, Read Me. A no-network welcome / overview pane. Explains that this
   desktop is one Windows-95 sheet of glass over the LIVE OSRAMP + Olly-Sentinel
   cluster, gives a legend of every window and the real component it touches, and
   offers quick shortcuts to the headline windows. Self-registers on load.
   =========================================================================== */
"use strict";

Estate95.register({
  id: "readme",
  title: "Estate 95",
  icon: "🖥️",
  short: "Read Me",
  width: 640,
  height: 480,

  open(body, api) {
    const h = api.h;

    // The whole desktop, described once. Each row: which window, what it does,
    // and the real thing on the running cluster it is wired to.
    const HEADLINE = [
      ["🗂️", "agent-cards", "Agent Registry",
        "The estate's agents the way ARC lists them: model, provider, skills and auth, each with its A2A card and a live diff against the running service."],
      ["📊", "eval-lab", "Eval Lab",
        "Does the agent hold up? Root-cause eval runs, pass / fail counts, and an agent-vs-human scorecard."],
      ["🗼", "pipeline", "Pipeline Panopticon",
        "Watch it work. The live Kafka incident flow (received, enriched, ticket) as it happens."],
    ];

    const WINDOWS = [
      ["🗺️", "osramp-console", "OSRAMP Console",
        "Runs the make targets and scripts and draws the architecture map.",
        "make / scripts via /api/steps"],
      ["🎛️", "control-panel", "Control Plane",
        "Bring the whole demo up or take it down; watch each lifecycle step.",
        "lifecycle actions (POST /api/runs)"],
      ["🗂️", "agent-cards", "Agent Registry",
        "The estate's agents the way ARC lists them: model, provider, skills and auth, each with its A2A card and a live diff.",
        "/api/agent-card + /api/agent-card/live"],
      ["🛰️", "orbit", "Orbit / Approvals",
        "Approve or reject the actions Olly proposes; approval is a signed token the agent cannot mint.",
        "/api/orbit/proposals + approve/reject"],
      ["🎟️", "servicenow", "ServiceNow",
        "The incident ticket store the agent files into, with full RCA enrichment.",
        "io-mapping-stub via /api/incidents"],
      ["☸️", "cluster", "Cluster State",
        "Every pod's health and each Flux reconciliation.",
        "kubectl + Flux via /api/cluster/overview"],
      ["🖥️", "terminal", "Scoped Terminal",
        "A read-only, allow-listed kubectl / flux / helm / rpk prompt into the cluster.",
        "scoped runner over /ws/term"],
      ["🗼", "pipeline", "Pipeline Panopticon",
        "The live incident flow: received, declined, enriched, ticket.",
        "Kafka topics via /api/pipeline/events"],
      ["🧪", "adk-studio", "ADK Studio",
        "The Google ADK 'adk web' developer UI, embedded whole.",
        "adk web (:8000) via /proxy/adk/"],
      ["📊", "eval-lab", "Eval Lab",
        "RCA eval runs plus the agent-vs-human scorecard.",
        "eval history via /api/eval-history"],
      ["📈", "grafana", "Eye in the Sky",
        "The control-tower dashboards: the telemetry the agent reads from.",
        "Grafana via /proxy/grafana/"],
    ];

    const jump = (id) => () => Estate95.open(id);

    // ---- Masthead ---------------------------------------------------------
    body.appendChild(h("div", { class: "eyebrow" }, "Welcome to"));
    body.appendChild(h("div", { class: "row", style: { alignItems: "baseline", gap: "10px" } },
      h("h2", { style: { fontSize: "20px" } }, "Estate 95"),
      api.pill("LIVE cluster", "ok"),
      h("span", { class: "muted" }, "OSRAMP · Olly-Sentinel")));

    body.appendChild(h("p", { style: { marginTop: "8px" } },
      "One Windows-95 desktop over the running OSRAMP + Olly-Sentinel Kubernetes demo. ",
      "Every window here is wired to a ", h("b", {}, "real"),
      " component of the live cluster. Double-click a desktop icon, ",
      "pick from the Start menu, or use the shortcuts below."));

    // ---- Headline: A2A, agent cards, evals up front -----------------------
    const headRows = HEADLINE.map(([icon, id, name, blurb]) =>
      h("div", { class: "row", style: { alignItems: "flex-start", flexWrap: "nowrap", padding: "4px 0" } },
        h("span", { style: { fontSize: "22px", flex: "0 0 auto", lineHeight: "1" } }, icon),
        h("div", { class: "stack", style: { gap: "2px", flex: "1 1 auto", minWidth: "0" } },
          h("b", {}, name),
          h("span", { class: "muted", style: { fontSize: "12px" } }, blurb)),
        h("button", { class: "btn", style: { flex: "0 0 auto" }, onclick: jump(id) }, "Open")));

    body.appendChild(api.groupbox("Start here: the headline",
      h("p", { class: "muted", style: { marginBottom: "6px" } },
        "An autonomous SRE agent that reads telemetry, writes a root-cause analysis, and files a ticket. ",
        "It is governed by a published A2A contract and measured against human analysts."),
      h("div", { class: "stack", style: { gap: "6px" } }, headRows)));

    // ---- Full legend: every window + the real thing it touches ------------
    const tableRows = WINDOWS.map(([icon, id, name, does, touches]) => {
      const tr = h("tr", { class: "clickable", title: "Open " + name },
        h("td", { style: { whiteSpace: "nowrap" } },
          h("span", { style: { marginRight: "6px" } }, icon), h("b", {}, name)),
        h("td", {}, does),
        h("td", {}, h("span", { class: "mono", style: { fontSize: "11px" } }, touches)));
      tr.addEventListener("click", jump(id));
      return tr;
    });

    body.appendChild(api.groupbox("Every window, and the real thing it touches",
      h("div", { class: "tablewrap" },
        h("table", { class: "grid" },
          h("thead", {}, h("tr", {},
            h("th", {}, "Window"),
            h("th", {}, "What it does"),
            h("th", {}, "Wired to"))),
          h("tbody", {}, tableRows)))));

    // ---- Quick jump buttons ----------------------------------------------
    body.appendChild(api.groupbox("Jump to",
      h("div", { class: "row" },
        h("button", { class: "btn", onclick: jump("osramp-console") }, "🗺️ OSRAMP Console"),
        h("button", { class: "btn", onclick: jump("agent-cards") }, "🗂️ Agent Registry"),
        h("button", { class: "btn", onclick: jump("pipeline") }, "🗼 Pipeline Panopticon"),
        h("button", { class: "btn", onclick: jump("eval-lab") }, "📊 Eval Lab"),
        h("button", { class: "btn", onclick: jump("control-panel") }, "🎛️ Control Plane"))));

    // ---- Footer: how to read status + what to do when it's down -----------
    body.appendChild(h("div", { class: "row", style: { margin: "12px 0 8px", gap: "6px" } },
      h("span", { class: "muted", style: { fontSize: "11px" } }, "Status colours:"),
      api.pill("healthy", "ok"),
      api.pill("needs a look", "warn"),
      api.pill("down / failing", "crit"),
      api.pill("note", "info")));

    body.appendChild(h("div", { class: "notice" },
      h("span", {},
        "Windows that reach into the cluster show a red banner when the demo is not running. ",
        "If that happens, open ",
        h("b", { class: "mono", style: { cursor: "pointer" }, onclick: jump("control-panel") }, "Control Plane"),
        " and bring the demo up.")));
  },
});

