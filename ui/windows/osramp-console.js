/* ===========================================================================
   OSRAMP Console, architecture map
   The OSRAMP web console folded into the Estate 95 desktop. Reads the workflow
   map (/api/steps) and renders the three delivery lanes whose output belongs to
   the OSRAMP console: Deliver (signed artifacts), Operate (the ingestion
   pipeline), and Assure (VEX / policy gates / agentic remediation). Every action
   button runs the real command against the cluster and streams its output into a
   single shared console at the bottom of the window.
   =========================================================================== */
"use strict";

Estate95.register({
  id: "osramp-console",
  title: "OSRAMP Console",
  icon: "🗺️",
  short: "OSRAMP",
  width: 820,
  height: 560,

  async open(body, api) {
    const h = api.h;

    // A friendly glyph per lane so the three phases are easy to tell apart.
    const laneIcon = { deliver: "📦", operate: "⚙️", assure: "🛡️" };

    // Render a command array as the exact line that will run.
    const cmdText = (a) => {
      const c = a && a.command;
      return Array.isArray(c) ? c.join(" ") : (c == null ? "" : String(c));
    };

    // Map a step's implementation status onto a pill colour.
    const statusKind = (s) => {
      const v = String(s || "").toLowerCase();
      if (v === "implemented" || v === "done" || v === "ready") return "ok";
      if (v === "planned" || v === "todo" || v === "wip" || v === "in-progress") return "warn";
      if (v === "blocked" || v === "failed") return "crit";
      return "plain";
    };

    // ---- header -----------------------------------------------------------
    body.appendChild(h("div", { class: "eyebrow" }, "OSRAMP web console"));
    body.appendChild(h("p", { class: "muted" },
      "Deliver signed artifacts, operate the ingestion pipeline, and assure the estate " +
      "with VEX triage, policy gates, and human-in-the-loop remediation. Each button below " +
      "runs the real command against the cluster and streams its output to the shared console " +
      "at the bottom of this window."));

    // ---- load the workflow map -------------------------------------------
    let data;
    try {
      data = await api.get("/api/steps");
    } catch (err) {
      body.appendChild(h("div", { class: "notice err" }, err && err.message ? err.message : "Could not load the workflow map."));
      return;
    }

    const lanes = (((data && data.lanes) || [])).filter((l) => l && l.console === "osramp");
    if (!lanes.length) {
      body.appendChild(h("div", { class: "notice" }, "No OSRAMP lanes are defined in the workflow map."));
      return;
    }

    // ---- shared console + run-state --------------------------------------
    // A single console pane is shared by every action button in the window.
    const allButtons = [];
    let running = false;

    const statusPill = api.pill("Idle", "plain");
    const consoleEl = h("div", { class: "console", style: { height: "180px" } },
      h("span", { class: "dim" }, "Idle. Choose an action above to run its command here.\n"));

    const setRunning = (on, label) => {
      running = on;
      for (const b of allButtons) b.disabled = on;
      statusPill.className = "pill " + (on ? "warn" : "plain");
      statusPill.textContent = on ? ("Running: " + label) : "Idle";
    };

    // Build one .btn wired to run its action and re-enable on exit.
    const actionButton = (action) => {
      const label = (action && (action.label || action.id)) || "Run";
      const btn = h("button", { class: "btn", title: cmdText(action) }, label);
      allButtons.push(btn);
      btn.addEventListener("click", () => {
        if (running || !action || !action.id) return;
        setRunning(true, label);
        btn.textContent = "Running…";
        api.runAction(action.id, consoleEl, () => {
          btn.textContent = label;
          setRunning(false);
        });
      });
      return btn;
    };

    // ---- lanes ------------------------------------------------------------
    for (const lane of lanes) {
      const section = h("div", { style: { marginTop: "14px" } });
      section.appendChild(h("h3", { style: { marginTop: "6px" } },
        (laneIcon[lane.id] || "▪") + "  " + (lane.title || lane.id || "Lane")));

      for (const step of (lane.steps || [])) {
        // owner + phase (+ status) as pills
        const meta = h("div", { class: "row", style: { marginBottom: "2px" } },
          h("span", { class: "muted", style: { fontSize: "11px" } }, "Owner:"),
          api.pill(step.owner || "n/a", "plain"),
          h("span", { class: "muted", style: { fontSize: "11px" } }, "Phase:"),
          api.pill(step.phase || "n/a", "info"),
          step.status ? api.pill(step.status, statusKind(step.status)) : null);

        // description, small + muted
        const desc = h("p", { class: "muted", style: { fontSize: "12px", margin: "6px 0 2px" } },
          step.description || "");

        // one row per action: [ button ] followed by the exact command
        const actions = h("div", { class: "stack", style: { marginTop: "8px", gap: "6px" } });
        const list = (step.actions || []);
        if (!list.length) {
          actions.appendChild(h("span", { class: "muted", style: { fontSize: "12px" } },
            "No runnable actions for this step."));
        } else {
          for (const action of list) {
            actions.appendChild(h("div", { class: "row" },
              actionButton(action),
              h("code", {
                class: "mono",
                style: { flex: "1 1 240px", minWidth: "0", whiteSpace: "normal", wordBreak: "break-word" },
              }, cmdText(action) || "n/a")));
          }
        }

        section.appendChild(api.groupbox(step.name || step.id || "Step", meta, desc, actions));
      }

      body.appendChild(section);
    }

    // ---- shared console at the bottom ------------------------------------
    body.appendChild(api.groupbox("Command output",
      h("div", { class: "row", style: { justifyContent: "space-between", marginBottom: "6px" } },
        h("span", { class: "muted", style: { fontSize: "11px" } },
          "One shared console for every action in this window"),
        statusPill),
      consoleEl));
  },
});

