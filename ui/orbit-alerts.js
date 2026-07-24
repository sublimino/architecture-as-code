/* ===========================================================================
   Orbit HITL watcher. Polls the sentinel's parked-proposal store (proxied by
   the broker at /api/orbit/proposals) and turns a human-in-the-loop trigger
   into a desktop event: a count badge on the Orbit icon and taskbar button,
   plus a Windows-95 toast when a new proposal lands while you are watching.
   The toast's Open button raises the Orbit window so the approval can be
   reviewed and signed. Read-only; every decision still happens in Orbit.
   =========================================================================== */
"use strict";

(function () {
  const SEEN = new Set();     // proposal ids we have already reacted to
  const HANDLES = {};         // proposal id -> live toast handle
  let baseline = true;        // first poll seeds the backlog without toasting

  // "remediate_restart_service" -> "restart service" for the toast line.
  function label(action) {
    if (!action) return "an action";
    return action.replace(/^remediate_/, "").replace(/_/g, " ");
  }

  async function poll() {
    let list;
    try {
      const res = await fetch("/api/orbit/proposals?state=proposed", { cache: "no-store" });
      if (!res.ok) return;                 // sentinel not ready: stay quiet
      list = await res.json();
    } catch (_) {
      return;                              // cluster down: stay quiet
    }
    if (!Array.isArray(list)) return;

    Estate95.badge("orbit", list.length);

    const live = new Set();
    for (const p of list) {
      const id = p.proposal_id;
      if (!id) continue;
      live.add(id);
      if (SEEN.has(id)) continue;
      SEEN.add(id);
      if (baseline) continue;              // handled once, below, as a summary

      HANDLES[id] = Estate95.notify({
        key: "orbit:" + id,
        icon: "🛰️",
        title: "Orbit — approval needed",
        message: (p.app_id || "An app") + " · " + label(p.action) +
          " is parked for your decision. Open Orbit to review the evidence and sign.",
        actionLabel: "Open Orbit",
        onAction: () => Estate95.open("orbit"),
      });
    }

    // On the first poll of a session, a page load can already carry a backlog.
    // One summary toast surfaces it (a refresh should not replay a toast per
    // proposal); live parks after this each get their own toast above.
    if (baseline && live.size > 0) {
      const n = live.size;
      Estate95.notify({
        key: "orbit:backlog",
        icon: "🛰️",
        title: "Orbit — approval needed",
        message: n === 1
          ? "1 action is parked for your decision. Open Orbit to review and sign."
          : n + " actions are parked for your decision. Open Orbit to review and sign.",
        actionLabel: "Open Orbit",
        onAction: () => Estate95.open("orbit"),
      });
    }

    // A proposal that left the parked set was approved or rejected; drop its
    // toast and forget it so a fresh park on the same app notifies again.
    for (const id of Array.from(SEEN)) {
      if (!live.has(id)) {
        SEEN.delete(id);
        if (HANDLES[id]) { HANDLES[id].dismiss(); delete HANDLES[id]; }
      }
    }
    baseline = false;
  }

  function start() { poll(); setInterval(poll, 4000); }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
