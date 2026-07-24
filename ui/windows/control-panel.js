/* ===========================================================================
   Control Plane, environment & Olly
   One dashboard to run setup.sh / teardown.sh / make up and the Olly Sentinel
   + ADK actions. Renders ONLY the "control" lane from /api/steps: its two steps
   ("Cluster lifecycle" and "Olly Sentinel + ADK"), each as a groupbox of
   buttons that stream into a single shared console at the bottom.
   =========================================================================== */
"use strict";

Estate95.register({
  id: "control-panel",
  title: "Control Plane",
  icon: "🎛️",
  short: "Control Plane",
  width: 760,
  height: 540,

  async open(body, api) {
    const h = api.h;

    // ---- shared console (one pane for all streamed output) -----------------
    const consoleEl = h("div", { class: "console", style: { minHeight: "150px", maxHeight: "230px" } },
      h("span", { class: "dim" }, "Idle. Pick an action above and its output streams here.\n"));

    // status line that tracks what is currently attached to the console
    const status = h("span", { class: "muted mono" }, "Idle");

    const clearBtn = h("button", { class: "btn", onclick: () => {
      consoleEl.innerHTML = "";
      consoleEl.appendChild(h("span", { class: "dim" }, "Cleared.\n"));
    } }, "Clear");

    // ---- action button factory --------------------------------------------
    // action.class === "background" => runs alongside a lifecycle action.
    // Everything else serializes on the broker (one lifecycle action at a time).
    function actionRow(action) {
      const isBg = action && action.class === "background";
      const btn = h("button", { class: "btn", title: (action.command || []).join(" ") }, action.label);
      btn.addEventListener("click", () => {
        status.textContent = "Running: " + action.label + " …";
        status.className = "mono";
        btn.disabled = true;
        api.runAction(action.id, consoleEl, (code) => {
          btn.disabled = false;
          const ok = code === 0;
          status.textContent = (ok ? "Finished: " : "Failed: ") + action.label + " (exit " + code + ")";
          status.className = "mono";
        });
      });
      return h("div", { class: "row" },
        btn,
        isBg
          ? api.pill("runs alongside", "info")
          : api.pill("serialized", "plain")
      );
    }

    // ---- one groupbox per step, actions grouped by step.name ---------------
    function stepGroup(step) {
      const actions = (step.actions || []);
      const statusPill = step.status === "implemented"
        ? api.pill("implemented", "ok")
        : api.pill(step.status || "planned", "warn");

      const meta = h("div", { class: "row", style: { marginBottom: "6px" } },
        step.owner ? api.pill(step.owner, "plain") : null,
        step.phase ? api.pill(step.phase, "plain") : null,
        statusPill);

      const desc = step.description
        ? h("p", { class: "muted", style: { marginBottom: "8px" } }, step.description)
        : null;

      const rows = actions.length
        ? actions.map(actionRow)
        : [h("div", { class: "muted" }, "No actions for this step.")];

      return api.groupbox(step.name || step.id || "Step", meta, desc, h("div", { class: "stack" }, ...rows));
    }

    // ---- load /api/steps, render the control lane --------------------------
    let data;
    try {
      data = await api.get("/api/steps");
    } catch (err) {
      body.appendChild(h("div", { class: "notice err" }, err.message));
      return;
    }

    const lanes = (data && data.lanes) || [];
    const lane = lanes.find((l) => l && l.id === "control");

    if (!lane) {
      body.appendChild(h("div", { class: "notice err" }, "The “control” lane is not present in /api/steps."));
      return;
    }

    const steps = (lane.steps || []);

    // header
    const header = h("div", { class: "stack", style: { gap: "4px" } },
      h("div", { class: "eyebrow" }, "Cluster lifecycle & Olly Sentinel"),
      h("h3", {}, "Bring the whole demo up and down from one place"));

    // explanatory notice about serialization vs. background execution
    const notice = h("div", { class: "notice" },
      h("div", {},
        h("strong", {}, "Lifecycle actions serialize. "),
        "Cluster-lifecycle actions (",
        h("code", { class: "mono" }, "setup.sh"),
        ", ",
        h("code", { class: "mono" }, "make up"),
        ", ",
        h("code", { class: "mono" }, "make down"),
        ", ",
        h("code", { class: "mono" }, "make teardown"),
        ") run one at a time on the broker, so destructive operations never overlap. Background actions (the ",
        h("code", { class: "mono" }, "ADK eval"),
        " and ",
        h("code", { class: "mono" }, "adk web"),
        " studio, marked ",
        api.pill("runs alongside", "info"),
        ") run alongside a lifecycle action. Every action streams into the single console below."));

    // step groups (in lane order: Cluster lifecycle, then Olly Sentinel + ADK)
    const groups = steps.length
      ? steps.map(stepGroup)
      : [h("div", { class: "notice" }, "The control lane has no steps.")];

    // output groupbox (shared console + status + clear)
    const outputBox = api.groupbox("Streamed output",
      h("div", { class: "row", style: { justifyContent: "space-between", marginBottom: "6px" } },
        status,
        clearBtn),
      consoleEl);

    // assemble
    body.appendChild(h("div", { class: "stack" },
      header,
      notice,
      ...groups,
      outputBox));
  },
});

