/* ===========================================================================
   Orbit, the action + approval console. Shows the proposals the sentinel has
   parked (action-proposal.v1, awaiting a human decision) and lets the operator
   approve or reject each one. Approving asks the broker to mint an ed25519-
   signed token bound to that proposal; the sentinel verifies it against the
   public key it holds and cannot mint itself. The model proposes, a human
   approves, and a deterministic executor acts; in Phase 1 the executor records
   the action without mutating.
   Reads /api/orbit/proposals; posts /api/orbit/approve and /api/orbit/reject.
   =========================================================================== */
"use strict";

Estate95.register({
  id: "orbit",
  title: "Orbit: Action Approvals",
  icon: "🛰️",
  short: "Orbit",
  width: 780,
  height: 600,

  open(body, api) {
    const h = api.h;

    // -- header -------------------------------------------------------------
    body.appendChild(h("div", { class: "stack", style: { gap: "4px" } },
      h("div", { class: "eyebrow" }, "Human-in-the-loop · action-proposal.v1"),
      h("h3", {}, "Approve or reject the actions Olly proposes"),
      h("p", { class: "muted" },
        "When an enrichment warrants an action, Orbit proposes exactly one from a closed enum and parks it here. ",
        "Approving mints a signed, single-use token bound to that proposal; the agent cannot mint one itself, ",
        "so it can never approve its own work. In Phase 1 an approved action is recorded, not executed.")));

    const errHost = h("div", {});
    body.appendChild(errHost);

    // Approver identity (whose name goes on the signed approval).
    const whoInput = h("input", {
      class: "in", value: "estate95-operator",
      style: { width: "180px" }, title: "recorded as approved_by on the signed token",
    });
    body.appendChild(h("div", { class: "row", style: { gap: "8px", alignItems: "center", margin: "4px 0 8px" } },
      h("span", { class: "muted", style: { fontSize: "11px" } }, "Approving as:"), whoInput,
      h("span", { class: "muted", style: { fontSize: "11px" } }, "· bound into the approval token")));

    // -- proposals list -----------------------------------------------------
    const listHost = h("div", {}, h("div", { class: "muted" }, "Loading proposals…"));
    body.appendChild(api.groupbox("Proposals awaiting a decision", listHost));

    // Ledger of decisions made this session (so the operator sees the outcome).
    const ledgerBody = h("tbody", {});
    const ledger = h("div", { class: "tablewrap", style: { maxHeight: "150px" } },
      h("table", { class: "grid" },
        h("thead", {}, h("tr", {},
          h("th", {}, "Proposal"), h("th", {}, "Action"), h("th", {}, "Decision"), h("th", {}, "By"))),
        ledgerBody));
    const ledgerGb = api.groupbox("Decisions this session", ledger);
    body.appendChild(ledgerGb);

    const actionKind = (a) => a === "remediate_restart_service" ? "crit"
      : a === "troubleshoot" ? "warn" : "plain";

    function pushLedger(proposalId, action, decision, by) {
      ledgerBody.insertBefore(h("tr", {},
        h("td", { class: "mono", style: { fontSize: "11px" } }, String(proposalId).slice(0, 16) + "…"),
        h("td", {}, api.pill(action, actionKind(action))),
        h("td", {}, api.pill(decision, decision === "approved" ? "ok" : "plain")),
        h("td", {}, by || "-")), ledgerBody.firstChild);
    }

    async function decide(p, kind, btnrow) {
      for (const b of btnrow) b.disabled = true;
      const who = whoInput.value.trim() || "estate95-operator";
      try {
        if (kind === "approve") {
          const res = await api.post("/api/orbit/approve", { proposal_id: p.proposal_id, approved_by: who });
          const st = (res && res.proposal && res.proposal.approval && res.proposal.approval.state) || "approved";
          pushLedger(p.proposal_id, p.action, st === "executed" ? "approved" : st, res.approved_by || who);
        } else {
          await api.post("/api/orbit/reject", { proposal_id: p.proposal_id, rejected_by: who });
          pushLedger(p.proposal_id, p.action, "rejected", who);
        }
        await load();
      } catch (err) {
        errHost.innerHTML = "";
        errHost.appendChild(h("div", { class: "notice err" },
          (kind === "approve" ? "Approval denied: " : "Reject failed: ") + (err.message || "unknown")));
        for (const b of btnrow) b.disabled = false;
      }
    }

    function renderProposals(list) {
      listHost.innerHTML = "";
      if (!Array.isArray(list) || !list.length) {
        listHost.appendChild(h("div", { class: "notice" },
          h("span", {}, "🛰️"),
          h("div", {}, "No proposals awaiting a decision. Replay a restart-shaped incident ",
            "(for example an OOM on ", h("code", {}, "payments-api"), ") to see one appear here.")));
        return;
      }
      for (const p of list) {
        const approveBtn = h("button", { class: "btn" }, "Approve & sign");
        const rejectBtn = h("button", { class: "btn" }, "Reject");
        const row = [approveBtn, rejectBtn];
        approveBtn.addEventListener("click", () => decide(p, "approve", row));
        rejectBtn.addEventListener("click", () => decide(p, "reject", row));

        const conf = (p.confidence_score != null) ? Number(p.confidence_score).toFixed(2) : "n/a";
        listHost.appendChild(api.groupbox(
          p.app_id + " · " + (p.fault_domain || "unknown"),
          h("div", { class: "row", style: { gap: "8px", alignItems: "baseline", flexWrap: "wrap" } },
            api.pill(p.action, actionKind(p.action)),
            api.pill("confidence " + conf, "info"),
            h("code", { style: { fontSize: "11px" } }, p.correlation_id)),
          h("p", { style: { fontSize: "12px", margin: "6px 0" } }, p.justification || ""),
          p.evidence_refs && p.evidence_refs.length
            ? h("div", { class: "stack", style: { gap: "2px", marginBottom: "6px" } },
                h("div", { class: "muted", style: { fontSize: "11px" } }, "Evidence this proposal rests on"),
                h("div", { class: "row", style: { flexWrap: "wrap", gap: "4px" } },
                  p.evidence_refs.slice(0, 8).map((e) =>
                    h("code", { style: { fontSize: "10px" } }, String(e).split(":")[0]))))
            : null,
          h("div", { class: "row", style: { gap: "8px", marginTop: "4px" } }, approveBtn, rejectBtn)));
      }
    }

    async function load() {
      try {
        const list = await api.get("/api/orbit/proposals?state=proposed");
        errHost.innerHTML = "";
        renderProposals(list);
      } catch (err) {
        listHost.innerHTML = "";
        errHost.innerHTML = "";
        errHost.appendChild(h("div", { class: "notice err" },
          err && err.status === 503
            ? "The cluster or sentinel is not reachable. Bring the demo up from Control Plane."
            : "Could not load proposals: " + (err.message || "unknown")));
      }
    }

    // Groupbox explaining how the approval gate maps to the design.
    body.appendChild(api.groupbox("How the approval gate works",
      h("div", { class: "stack", style: { gap: "5px", fontSize: "12px" } },
        h("div", {}, h("b", {}, "1. Propose · "),
          "Orbit selects one action from ", h("code", {}, "troubleshoot / remediate_restart_service / no_action"),
          " deterministically from the fault domain."),
        h("div", {}, h("b", {}, "2. Approve · "),
          "The broker mints an ed25519-signed token bound to this exact proposal. The sentinel holds only the ",
          h("b", {}, "public"), " key, so it verifies but can never sign."),
        h("div", {}, h("b", {}, "3. Execute · "),
          "A deterministic executor records the action under a separate write identity. Phase 1 is read-only, ",
          "so it logs what it ", h("i", {}, "would"), " do and mutates nothing."))));

    load();
  },
});
