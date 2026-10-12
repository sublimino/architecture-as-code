/* ===========================================================================
   Policy Posture & Risk
   Baselines agent workloads against versioned regulatory policy packs.

   Every £ figure in this window comes from /api/compliance/* or is not shown.
   There is no fallback dataset: the console does not currently register any
   /api/compliance route, so a fallback would have been served on 100% of
   requests and would have been indistinguishable from a real measurement.
   When the route is not served the window refuses with a banner and empty
   states, like the eval-lab, pipeline, security-sandbox and agent-cards windows.

   "£ Carried" is only rendered when the API supplies both a `carried` value and
   the `carried_basis` that derived it. It is never computed here: the documented
   convention is TVaR x 1.15, this window computes no TVaR, and VaR95 x 1.15 is a
   different number under the same caption. `carried` also feeds the pass-rate
   and coverage arithmetic, so a wrong one propagates.
   =========================================================================== */
"use strict";

Estate95.register({
  id: "policy-posture",
  title: "Policy Posture & Risk",
  icon: "\u{1F6E1}\uFE0F",
  short: "Policy",
  width: 900,
  height: 640,

  async open(body, api) {
    const h = api.h;

    // ---- currency formatter ------------------------------------------------
    const gbp = (n) => "\u00A3" + Number(n).toLocaleString("en-GB");

    // ---- data fetching -----------------------------------------------------
    // No catch-and-substitute. A failure is surfaced to the caller, which shows
    // the refusal banner and empty states.
    async function fetchSummary(version) {
      const qs = version ? "?version=" + encodeURIComponent(version) : "";
      return api.get("/api/compliance/summary" + qs);
    }

    async function fetchChecks() {
      return api.get("/api/compliance/checks");
    }

    // Reason text for a failed /api/compliance/* read.
    function refusalReason(err) {
      const status = err && err.status;
      const detail = (err && err.message) || "request failed";
      if (status === 404 || status === 501) {
        return "Route not served: this console registers no /api/compliance route, " +
          "so no posture figures can be read (" + detail + "). " +
          "Nothing is shown rather than a stand-in.";
      }
      if (status === 503) {
        return "The compliance backend is unavailable (" + detail + "). " +
          "Bring the demo up from Control Plane; this view reloads on Scan Now.";
      }
      return "Could not load the compliance posture: " + detail +
        ". Nothing is shown rather than a stand-in.";
    }

    // ---- pill colour helpers -----------------------------------------------
    function coveragePill(passed, total) {
      const pct = total > 0 ? Math.round((passed / total) * 100) : 0;
      const kind = pct > 80 ? "ok" : pct > 50 ? "warn" : "crit";
      return api.pill(pct + "%", kind);
    }

    function statusPill(status) {
      return api.pill(status, status === "pass" ? "ok" : "crit");
    }

    // ---- header ------------------------------------------------------------
    const header = h("div", { class: "stack", style: { gap: "4px" } },
      h("div", { class: "eyebrow" }, "POLICY AS VERSIONED CODE \u00B7 FAIR RISK QUANTIFICATION"),
      h("h3", {}, "Agent Compliance Posture"),
      h("p", { class: "muted" },
        "Baselines agent workloads against versioned regulatory policy packs. " +
        "\u00A3 values are FAIR-quantified (industry-indicative calibration)."));

    body.appendChild(header);

    // ---- refusal banner host (filled only when a fetch fails) --------------
    const errHost = h("div", {});
    body.appendChild(errHost);

    function showRefusal(err) {
      errHost.innerHTML = "";
      errHost.appendChild(h("div", { class: "notice err" }, refusalReason(err)));
    }

    function clearRefusal() {
      errHost.innerHTML = "";
    }

    // ---- summary stats row -------------------------------------------------
    const statsRow = h("div", { class: "row", style: { gap: "8px", flexWrap: "wrap" } });
    body.appendChild(statsRow);

    const big = (text) =>
      h("span", { class: "mono", style: { fontSize: "18px", fontWeight: "700" } }, String(text));
    const num = (v) => (typeof v === "number" && isFinite(v) ? v : null);

    // A stat is rendered iff the API supplied it. "unavailable" is the honest
    // reading of a missing figure; 0 or a placeholder would read as measured.
    function moneyStat(legend, value, note) {
      const n = num(value);
      return api.groupbox(legend,
        big(n === null ? "unavailable" : gbp(n)),
        h("div", { class: "muted", style: { fontSize: "10px" } },
          n === null ? legend + " unavailable: not supplied by /api/compliance/summary" : (note || "")));
    }

    function renderStats(s) {
      statsRow.innerHTML = "";
      if (!s) {
        statsRow.appendChild(h("div", { class: "muted" },
          "No posture figures. Nothing is shown until /api/compliance/summary answers."));
        return;
      }

      const passed = num(s.totalPassed);
      const controls = num(s.totalControls);
      if (passed === null || controls === null || controls <= 0) {
        statsRow.appendChild(api.groupbox("Checks Passed",
          big("unavailable"),
          h("div", { class: "muted", style: { fontSize: "10px" } },
            "No control counts supplied, so no pass rate can be derived.")));
      } else {
        const passRate = passed / controls;
        const passKind = passRate > 0.8 ? "ok" : passRate > 0.5 ? "warn" : "crit";
        statsRow.appendChild(api.groupbox("Checks Passed",
          h("div", { class: "row", style: { alignItems: "baseline", gap: "8px" } },
            big(passed + " / " + controls),
            api.pill(Math.round(passRate * 100) + "%", passKind))));
      }

      statsRow.appendChild(moneyStat("Total ALE", s.totalAle));
      statsRow.appendChild(moneyStat("Total VaR\u2089\u2085", s.totalVar95));

      // "\u00A3 Carried" needs both the figure and the basis that derived it. It is
      // never computed here from VaR95 \u2014 that is a different quantity.
      const carried = num(s.carried);
      const basis = String(s.carried_basis || s.carriedBasis || "").trim();
      if (carried === null || !basis) {
        statsRow.appendChild(api.groupbox("\u00A3 Carried",
          big("unavailable"),
          h("div", { class: "muted", style: { fontSize: "10px" } },
            "\u00A3 Carried unavailable: no TVaR and basis supplied by " +
            "/api/compliance/summary. It is not derived from VaR\u2089\u2085 here.")));
      } else {
        statsRow.appendChild(api.groupbox("\u00A3 Carried",
          big(gbp(carried)),
          h("div", { class: "muted", style: { fontSize: "10px" } }, basis)));
      }
    }

    // ---- framework coverage table ------------------------------------------
    const fwTableBody = h("tbody", {});
    const fwTable = h("div", { class: "tablewrap", style: { maxHeight: "180px" } },
      h("table", { class: "grid" },
        h("thead", {}, h("tr", {},
          h("th", {}, "Framework"),
          h("th", {}, "Version"),
          h("th", {}, "Controls"),
          h("th", {}, "Passed"),
          h("th", {}, "Coverage"),
          h("th", {}, "\u00A3 Exposure"))),
        fwTableBody));

    const fwGroup = api.groupbox("Framework Coverage", fwTable);
    body.appendChild(fwGroup);

    function renderFrameworks(frameworks) {
      fwTableBody.innerHTML = "";
      const rows = Array.isArray(frameworks) ? frameworks : [];
      if (!rows.length) {
        fwTableBody.appendChild(h("tr", {}, h("td", { colspan: "6", class: "muted" },
          "No frameworks. Nothing is shown until /api/compliance/summary answers.")));
        return;
      }
      for (const fw of rows) {
        fwTableBody.appendChild(h("tr", {},
          h("td", { style: { fontWeight: "500" } }, fw.name || fw.id),
          h("td", { class: "mono" }, fw.version),
          h("td", {}, String(fw.controls)),
          h("td", {}, String(fw.passed)),
          h("td", {}, coveragePill(fw.passed, fw.controls)),
          h("td", { class: "mono" }, gbp(fw.ale))));
      }
    }

    // ---- "what if" section -------------------------------------------------
    const deltaMsg = h("div", { style: { marginTop: "6px" } });
    const versionSelect = h("select", { class: "btn", style: { minWidth: "120px" } },
      h("option", { value: "v2.0", selected: true }, "v2.0 (current)"),
      h("option", { value: "v2.1" }, "v2.1 (tightened)"),
      h("option", { value: "v1.0" }, "v1.0 (baseline)"));

    let currentAle = null;

    versionSelect.addEventListener("change", async () => {
      const ver = versionSelect.value;
      deltaMsg.innerHTML = "";
      deltaMsg.appendChild(h("span", { class: "muted" }, "Recalculating\u2026"));
      let newData;
      try {
        newData = await fetchSummary(ver);
      } catch (err) {
        showRefusal(err);
        renderStats(null);
        renderFrameworks(null);
        deltaMsg.innerHTML = "";
        deltaMsg.appendChild(h("span", { class: "muted" },
          "No delta: the policy version could not be priced. " + refusalReason(err)));
        return;
      }
      clearRefusal();
      renderStats(newData);
      renderFrameworks(newData.frameworks);
      if (num(newData.totalAle) === null || currentAle === null) {
        deltaMsg.innerHTML = "";
        deltaMsg.appendChild(h("span", { class: "muted" },
          "No delta: a baseline and a new total ALE are both needed to derive one."));
        return;
      }
      const delta = newData.totalAle - currentAle;
      deltaMsg.innerHTML = "";
      if (delta !== 0) {
        const sign = delta < 0 ? "\u2212" : "+";
        const kind = delta < 0 ? "ok" : "crit";
        deltaMsg.appendChild(h("div", { class: "row", style: { gap: "8px", alignItems: "center" } },
          h("span", {}, "\u00A3 exposure changes by "),
          api.pill(sign + gbp(Math.abs(delta)), kind)));
      } else {
        deltaMsg.appendChild(h("span", { class: "muted" }, "No change from current baseline."));
      }
    });

    const whatIfGroup = api.groupbox("Tighten a control",
      h("div", { class: "row", style: { gap: "8px", alignItems: "center" } },
        h("span", {}, "Policy version:"),
        versionSelect),
      deltaMsg);
    body.appendChild(whatIfGroup);

    // ---- per-check detail (collapsible) ------------------------------------
    const checkTableBody = h("tbody", {});
    const checkTable = h("div", { class: "tablewrap", style: { maxHeight: "200px" } },
      h("table", { class: "grid" },
        h("thead", {}, h("tr", {},
          h("th", {}, "Check"),
          h("th", {}, "Framework"),
          h("th", {}, "Status"),
          h("th", {}, "\u00A3 ALE"))),
        checkTableBody));

    const showAllBtn = h("button", { class: "btn", style: { marginTop: "6px", display: "none" } });
    let checksExpanded = false;

    function renderChecks(checksIn) {
      checkTableBody.innerHTML = "";
      const checks = Array.isArray(checksIn) ? checksIn : [];
      if (!checks.length) {
        showAllBtn.style.display = "none";
        checkTableBody.appendChild(h("tr", {}, h("td", { colspan: "4", class: "muted" },
          "No control detail. Nothing is shown until /api/compliance/checks answers.")));
        return;
      }
      const limit = checksExpanded ? checks.length : Math.min(20, checks.length);
      for (let i = 0; i < limit; i++) {
        const c = checks[i];
        const isFail = c.status === "fail";
        checkTableBody.appendChild(h("tr", {},
          h("td", { style: isFail ? { color: "var(--crit)" } : {} }, c.name),
          h("td", {}, c.framework),
          h("td", {}, statusPill(c.status)),
          h("td", { class: "mono", style: isFail ? { color: "var(--crit)", fontWeight: "500" } : {} },
            num(c.ale) === null ? "unavailable" : gbp(c.ale))));
      }
      if (checks.length > 20) {
        showAllBtn.style.display = "";
        showAllBtn.textContent = checksExpanded
          ? "Show first 20 checks"
          : "Show all " + checks.length + " checks";
      } else {
        showAllBtn.style.display = "none";
      }
    }

    let allChecks = [];
    showAllBtn.addEventListener("click", () => {
      checksExpanded = !checksExpanded;
      renderChecks(allChecks);
    });

    const detailGroup = api.groupbox("Control Detail", checkTable, showAllBtn);
    body.appendChild(detailGroup);

    // ---- scan now button ---------------------------------------------------
    const consoleEl = h("div", { class: "console", style: { minHeight: "40px", maxHeight: "100px", display: "none" } });
    const scanBtn = h("button", { class: "btn" }, "Scan Now");

    scanBtn.addEventListener("click", async () => {
      scanBtn.disabled = true;
      scanBtn.textContent = "Scanning\u2026";
      consoleEl.style.display = "";
      consoleEl.innerHTML = "";
      const line = (t, cls) => {
        consoleEl.appendChild(h("span", cls ? { class: cls } : {}, t + "\n"));
        consoleEl.scrollTop = consoleEl.scrollHeight;
      };
      line("Initiating compliance scan\u2026", "dim");

      try {
        const res = await api.post("/api/compliance/scan", {
          namespace: "default",
          policyVersion: "v2.0",
          frameworks: ["eu-ai-act", "nist-800-53"],
        });
        line("Scan complete: " + (res.message || "OK"), "g");
      } catch (err) {
        // There is no cache. Say what happened instead of implying a stale read.
        line("Scan endpoint unavailable (" + ((err && err.message) || "request failed") +
          "). No posture was scanned.", "r");
      }

      await load();
      scanBtn.disabled = false;
      scanBtn.textContent = "Scan Now";
    });

    body.appendChild(h("div", { class: "row", style: { gap: "8px", marginTop: "4px" } }, scanBtn));
    body.appendChild(consoleEl);

    // ---- load / refresh ----------------------------------------------------
    async function load() {
      let summary;
      try {
        summary = await fetchSummary();
      } catch (err) {
        showRefusal(err);
        currentAle = null;
        renderStats(null);
        renderFrameworks(null);
        allChecks = [];
        renderChecks(allChecks);
        return;
      }
      clearRefusal();
      summary = summary || {};
      currentAle = num(summary.totalAle);
      renderStats(summary);
      renderFrameworks(summary.frameworks);

      try {
        allChecks = await fetchChecks();
      } catch (err) {
        showRefusal(err);
        allChecks = [];
      }
      renderChecks(allChecks);
    }

    await load();
  },
});
