/* ===========================================================================
   Agentic SRE Dashboard launcher. The dashboard is a self-contained page served
   by the broker at /agentic-sre.html, so it works standalone at
   http://localhost:8675/agentic-sre.html and opens from Estate 95 in its own
   browser tab. This desktop app is just the launcher.
   =========================================================================== */
"use strict";

Estate95.register({
  id: "agentic-sre",
  title: "Agentic SRE Dashboard",
  icon: "📡",
  short: "Agentic SRE",
  width: 460,
  height: 260,

  open(body, api) {
    const h = api.h;
    const url = "/agentic-sre.html";
    // Opening from within this click gesture, so the tab is allowed to pop.
    let win = null;
    try { win = window.open(url, "_blank"); } catch (_) { win = null; }

    const openBtn = h("button", { class: "btn" }, "Open dashboard ↗");
    openBtn.addEventListener("click", () => window.open(url, "_blank"));

    body.appendChild(h("div", { class: "stack", style: { gap: "8px" } },
      h("div", { class: "eyebrow" }, "Agentic SRE Dashboard"),
      h("h3", {}, "Live agents, A2A, and the Eye in the Sky"),
      h("p", { class: "muted" },
        "The sleek control view over the Olly and Orbit agents: the ARC agent registry, ",
        "the A2A hand-off with the identity chain, HITL approvals, the live decision timeline, ",
        "and the Grafana estate view. It opens in its own browser tab, separate from Estate 95."),
      win ? h("p", { class: "muted", style: { fontSize: "11px" } }, "Opened in a new tab. Use the button to reopen it.")
          : h("p", { class: "notice" }, "Your browser blocked the pop-up. Click below to open the dashboard."),
      h("div", { class: "row", style: { gap: "8px" } }, openBtn)));
  },
});
