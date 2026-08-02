/* ===========================================================================
   Policy Posture & Risk
   Conference demo: baselines agent workloads against versioned regulatory
   policy packs. £ values are FAIR-quantified (industry-indicative calibration).
   Consumes /api/compliance/* endpoints; falls back to hardcoded demo data
   when the backend is not yet deployed.
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

    // ---- fallback demo data ------------------------------------------------
    const DEMO_FRAMEWORKS = [
      { id: "eu-ai-act",   name: "EU AI Act",   version: "v2.0", controls: 24, passed: 18, ale: 48200,  var95: 192800 },
      { id: "nist-800-53", name: "NIST 800-53", version: "v2.0", controls: 31, passed: 26, ale: 35100,  var95: 140400 },
      { id: "dora",        name: "DORA",        version: "v1.0", controls: 18, passed: 16, ale: 12400,  var95: 49600  },
      { id: "cra",         name: "CRA",         version: "v1.0", controls: 14, passed: 12, ale: 8900,   var95: 35600  },
    ];

    const DEMO_CHECKS = [
      { name: "Model card published",           framework: "EU AI Act",   status: "pass", ale: 0     },
      { name: "Bias testing on protected attrs", framework: "EU AI Act",   status: "fail", ale: 12400 },
      { name: "Human oversight mechanism",       framework: "EU AI Act",   status: "pass", ale: 0     },
      { name: "Transparency documentation",      framework: "EU AI Act",   status: "fail", ale: 8200  },
      { name: "Risk classification logged",       framework: "EU AI Act",   status: "pass", ale: 0     },
      { name: "Data governance policy",           framework: "EU AI Act",   status: "fail", ale: 9100  },
      { name: "Conformity assessment",            framework: "EU AI Act",   status: "pass", ale: 0     },
      { name: "Post-market monitoring",           framework: "EU AI Act",   status: "fail", ale: 7300  },
      { name: "Technical documentation",          framework: "EU AI Act",   status: "fail", ale: 6800  },
      { name: "Incident reporting channel",       framework: "EU AI Act",   status: "fail", ale: 4400  },
      { name: "AC-2 Account management",          framework: "NIST 800-53", status: "pass", ale: 0     },
      { name: "AC-6 Least privilege",             framework: "NIST 800-53", status: "pass", ale: 0     },
      { name: "AU-2 Audit events",                framework: "NIST 800-53", status: "pass", ale: 0     },
      { name: "AU-6 Audit review",                framework: "NIST 800-53", status: "fail", ale: 8200  },
      { name: "CA-7 Continuous monitoring",        framework: "NIST 800-53", status: "fail", ale: 6400  },
      { name: "CM-6 Configuration settings",       framework: "NIST 800-53", status: "pass", ale: 0     },
      { name: "IA-5 Authenticator management",     framework: "NIST 800-53", status: "fail", ale: 9200  },
      { name: "IR-4 Incident handling",            framework: "NIST 800-53", status: "pass", ale: 0     },
      { name: "RA-5 Vulnerability scanning",       framework: "NIST 800-53", status: "fail", ale: 7100  },
      { name: "SC-7 Boundary protection",          framework: "NIST 800-53", status: "fail", ale: 4200  },
      { name: "SI-2 Flaw remediation",             framework: "NIST 800-53", status: "pass", ale: 0     },
      { name: "ICT risk management framework",     framework: "DORA",        status: "pass", ale: 0     },
      { name: "ICT incident reporting",            framework: "DORA",        status: "fail", ale: 6200  },
      { name: "Digital resilience testing",         framework: "DORA",        status: "pass", ale: 0     },
      { name: "Third-party risk policy",            framework: "DORA",        status: "fail", ale: 6200  },
      { name: "Vulnerability handling process",     framework: "CRA",         status: "pass", ale: 0     },
      { name: "SBOM provided to downstream",       framework: "CRA",         status: "fail", ale: 4500  },
      { name: "Security update mechanism",          framework: "CRA",         status: "fail", ale: 4400  },
    ];

    function demoSummary(frameworks) {
      const totalControls = frameworks.reduce((s, f) => s + f.controls, 0);
      const totalPassed   = frameworks.reduce((s, f) => s + f.passed, 0);
      const totalAle      = frameworks.reduce((s, f) => s + f.ale, 0);
      const totalVar95    = frameworks.reduce((s, f) => s + f.var95, 0);
      const tvar          = Math.round(totalVar95 * 1.15);
      return { totalControls, totalPassed, totalAle, totalVar95, carried: tvar, frameworks };
    }

    // ---- data fetching (with 404 fallback) ---------------------------------
    async function fetchSummary(version) {
      const qs = version ? "?version=" + encodeURIComponent(version) : "";
      try {
        const data = await api.get("/api/compliance/summary" + qs);
        return data;
      } catch {
        // API not deployed yet — use demo data
        return demoSummary(DEMO_FRAMEWORKS);
      }
    }

    async function fetchChecks() {
      try {
        return await api.get("/api/compliance/checks");
      } catch {
        return DEMO_CHECKS;
      }
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

    // ---- summary stats row -------------------------------------------------
    const statsRow = h("div", { class: "row", style: { gap: "8px", flexWrap: "wrap" } });
    body.appendChild(statsRow);

    function renderStats(s) {
      statsRow.innerHTML = "";
      const passRate = s.totalControls > 0 ? s.totalPassed / s.totalControls : 0;
      const passKind = passRate > 0.8 ? "ok" : passRate > 0.5 ? "warn" : "crit";

      statsRow.appendChild(api.groupbox("Checks Passed",
        h("div", { class: "row", style: { alignItems: "baseline", gap: "8px" } },
          h("span", { class: "mono", style: { fontSize: "18px", fontWeight: "700" } },
            s.totalPassed + " / " + s.totalControls),
          api.pill(Math.round(passRate * 100) + "%", passKind))));

      statsRow.appendChild(api.groupbox("Total ALE",
        h("span", { class: "mono", style: { fontSize: "18px", fontWeight: "700" } }, gbp(s.totalAle))));

      statsRow.appendChild(api.groupbox("Total VaR\u2089\u2085",
        h("span", { class: "mono", style: { fontSize: "18px", fontWeight: "700" } }, gbp(s.totalVar95))));

      statsRow.appendChild(api.groupbox("\u00A3 Carried",
        h("span", { class: "mono", style: { fontSize: "18px", fontWeight: "700" } }, gbp(s.carried)),
        h("div", { class: "muted", style: { fontSize: "10px" } }, "TVaR + risk load")));
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
      for (const fw of frameworks) {
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

    let currentAle = 0;

    versionSelect.addEventListener("change", async () => {
      const ver = versionSelect.value;
      deltaMsg.innerHTML = "";
      deltaMsg.appendChild(h("span", { class: "muted" }, "Recalculating\u2026"));
      const newData = await fetchSummary(ver);
      renderStats(newData);
      renderFrameworks(newData.frameworks);
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

    function renderChecks(checks) {
      checkTableBody.innerHTML = "";
      const limit = checksExpanded ? checks.length : Math.min(20, checks.length);
      for (let i = 0; i < limit; i++) {
        const c = checks[i];
        const isFail = c.status === "fail";
        checkTableBody.appendChild(h("tr", {},
          h("td", { style: isFail ? { color: "var(--crit)" } : {} }, c.name),
          h("td", {}, c.framework),
          h("td", {}, statusPill(c.status)),
          h("td", { class: "mono", style: isFail ? { color: "var(--crit)", fontWeight: "500" } : {} }, gbp(c.ale))));
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
        line("Scan endpoint unavailable \u2014 using cached posture.", "r");
      }

      // refresh all data
      const summary = await fetchSummary();
      currentAle = summary.totalAle;
      renderStats(summary);
      renderFrameworks(summary.frameworks);
      allChecks = await fetchChecks();
      renderChecks(allChecks);

      scanBtn.disabled = false;
      scanBtn.textContent = "Scan Now";
    });

    body.appendChild(h("div", { class: "row", style: { gap: "8px", marginTop: "4px" } }, scanBtn));
    body.appendChild(consoleEl);

    // ---- initial load ------------------------------------------------------
    const summary = await fetchSummary();
    currentAle = summary.totalAle;
    renderStats(summary);
    renderFrameworks(summary.frameworks);
    allChecks = await fetchChecks();
    renderChecks(allChecks);
  },
});
