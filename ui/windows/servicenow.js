/* ===========================================================================
   Estate 95 window, "ServiceNow, Incidents"
   A ServiceNow-style incident console rendered inside Windows-95 chrome.
   Reads /api/incidents (the io-mapping-stub in-memory ticket store). LEFT is a
   clickable list of tickets; RIGHT is the selected incident's form plus a
   "Work notes" section that renders the Olly RCA enrichment payload.
   Plain browser JS, no imports; only the global Estate95 is used.
   =========================================================================== */
(function () {
  "use strict";
  if (typeof Estate95 === "undefined" || !Estate95.register) return;

  // -- pure formatting helpers (scoped inside this IIFE) --------------------
  var STATE = {
    "new": { label: "New", kind: "info" },
    "in_progress": { label: "In Progress", kind: "warn" },
    "enriched": { label: "Enriched", kind: "ok" },
  };
  function stateInfo(s) { return STATE[s] || { label: s || "-", kind: "plain" }; }
  function cap(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }
  function fmtConf(n) { return (typeof n === "number" && n > 0) ? Math.round(n * 100) + "%" : "-"; }
  function fmtDate(s) {
    if (!s) return "-";
    var d = new Date(s);
    return isNaN(d.getTime()) ? String(s) : d.toLocaleString();
  }

  Estate95.register({
    id: "servicenow",
    title: "ServiceNow",
    icon: "🎟️",
    short: "ServiceNow",
    width: 860,
    height: 600,
    open: function (body, api) {
      var h = api.h;
      var tickets = [];
      var selectedCorr = null;

      function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); }

      // -- header (title, count, refresh) ----------------------------------
      var countPill = api.pill("0 incidents", "plain");
      var refreshBtn = h("button", { class: "btn" }, "Refresh");
      var header = h("div", { class: "row", style: { flex: "0 0 auto", justifyContent: "space-between" } },
        h("div", { class: "row", style: { gap: "8px" } },
          h("span", { style: { fontWeight: "700", fontSize: "14px" } }, "🎟️ Incidents"),
          countPill),
        refreshBtn);

      // -- two-pane body: list on the left, form on the right --------------
      var leftPane = h("div", { class: "tablewrap", style: { flex: "0 0 320px", minWidth: "0", minHeight: "0" } });
      var rightPane = h("div", { style: { flex: "1 1 auto", minWidth: "0", minHeight: "0", overflow: "auto", paddingLeft: "2px" } });
      var main = h("div", { class: "row", style: { flex: "1 1 auto", minHeight: "0", alignItems: "stretch", gap: "8px", flexWrap: "nowrap" } }, leftPane, rightPane);

      var footer = h("div", { class: "muted", style: { flex: "0 0 auto", fontSize: "11px" } },
        "This is the io-mapping-stub in-memory ticket store. A real ServiceNow PDI is used when .env supplies ",
        h("code", {}, "SERVICENOW_*"), " and ", h("code", {}, "make olly-pdi-secret"), " has run.");

      body.style.display = "flex";
      body.style.flexDirection = "column";
      body.style.gap = "8px";
      body.appendChild(header);
      body.appendChild(main);
      body.appendChild(footer);

      refreshBtn.addEventListener("click", load);

      // -- a label/value form row (ServiceNow-style) -----------------------
      function frow(label, value) {
        var v = (value == null || value === "") ? "-" : value;
        return h("div", { class: "row", style: { alignItems: "flex-start", gap: "8px", margin: "0 0 6px" } },
          h("div", { style: { flex: "0 0 128px", fontWeight: "700", color: "#333" } }, label),
          h("div", { style: { flex: "1 1 auto", minWidth: "0", wordBreak: "break-word" } }, v));
      }

      // -- LEFT: ticket list -----------------------------------------------
      function renderList() {
        clear(leftPane);
        countPill.textContent = tickets.length + (tickets.length === 1 ? " incident" : " incidents");
        if (!tickets.length) {
          leftPane.appendChild(h("div", { class: "notice", style: { margin: "8px" } }, "No incidents in the ticket store yet."));
          return;
        }
        var tbody = h("tbody", {});
        tickets.forEach(function (t) {
          var si = stateInfo(t.state);
          var tr = h("tr", { class: "clickable" + (t.correlation_id === selectedCorr ? " sel" : "") },
            h("td", {}, t.inc_number || "-"),
            h("td", {}, t.app_id || "-"),
            h("td", {}, si.label),
            h("td", {}, t.fault_domain ? cap(t.fault_domain) : "-"),
            h("td", { class: "right tnum" }, fmtConf(t.confidence_score)));
          tr.addEventListener("click", function () { select(t.correlation_id); });
          tbody.appendChild(tr);
        });
        leftPane.appendChild(h("table", { class: "grid" },
          h("thead", {}, h("tr", {},
            h("th", {}, "Number"), h("th", {}, "App"), h("th", {}, "State"),
            h("th", {}, "Fault"), h("th", { class: "right" }, "Conf"))),
          tbody));
      }

      function select(corr) {
        selectedCorr = corr;
        renderList();
        var t = null;
        for (var i = 0; i < tickets.length; i++) { if (tickets[i].correlation_id === corr) { t = tickets[i]; break; } }
        renderDetail(t);
      }

      // -- RIGHT: incident form + work notes -------------------------------
      function renderDetail(t) {
        clear(rightPane);
        if (!t) {
          rightPane.appendChild(h("div", { class: "muted", style: { padding: "12px" } },
            "Select an incident on the left to view its details."));
          return;
        }
        var si = stateInfo(t.state);
        rightPane.appendChild(h("div", { style: { padding: "2px 2px 0" } },
          h("div", { class: "eyebrow" }, "Incident"),
          h("div", { class: "row", style: { gap: "8px", alignItems: "center" } },
            h("span", { style: { fontWeight: "700", fontSize: "16px" } }, t.inc_number || "(no number)"),
            api.pill(si.label, si.kind))));

        rightPane.appendChild(api.groupbox("Incident detail",
          frow("Correlation ID", t.correlation_id ? h("code", {}, t.correlation_id) : null),
          frow("Application", t.app_id),
          frow("Short description", t.short_description),
          frow("Alert type", t.alert_type),
          frow("Fault domain", t.fault_domain ? cap(t.fault_domain) : null),
          frow("Confidence", fmtConf(t.confidence_score)),
          frow("Created", fmtDate(t.created_at)),
          frow("Enriched", fmtDate(t.enriched_at)),
          frow("RCA summary", t.rca_summary)));

        rightPane.appendChild(renderWorkNotes(t));
      }

      // -- Work notes: render the Olly RCA enrichment ----------------------
      function renderWorkNotes(t) {
        var enr = t.enrichment;
        if (!enr || typeof enr !== "object") {
          return api.groupbox("Work notes",
            h("div", { class: "notice" }, "No RCA enrichment recorded for this incident yet."));
        }
        var kids = [];
        var ag = enr.agent || {};
        kids.push(h("div", { class: "muted", style: { fontSize: "11px", marginBottom: "8px" } },
          "Enriched by " + (ag.name || "olly-sentinel") +
          (ag.version ? " v" + ag.version : "") +
          (ag.model_id ? " · " + ag.model_id : "") +
          (ag.eval_run_id ? " · eval " + ag.eval_run_id : "")));

        var rca = enr.rca || {};
        kids.push(h("div", { class: "eyebrow" }, "Probable cause"));
        kids.push(h("p", { style: { margin: "0 0 10px" } }, rca.probable_cause || "-"));

        var actions = Array.isArray(rca.suggested_actions) ? rca.suggested_actions : [];
        kids.push(h("div", { class: "eyebrow" }, "Suggested actions"));
        if (actions.length) {
          kids.push(h("ul", { style: { margin: "0 0 10px 18px" } },
            actions.map(function (a) { return h("li", { style: { marginBottom: "3px" } }, a); })));
        } else {
          kids.push(h("p", { class: "muted", style: { margin: "0 0 10px" } }, "None provided."));
        }

        var evidence = Array.isArray(enr.evidence) ? enr.evidence : [];
        kids.push(h("div", { class: "eyebrow" }, "Evidence"));
        if (evidence.length) {
          var rows = evidence.map(function (e) {
            return h("tr", {},
              h("td", {}, e.source || "-"),
              h("td", {}, e.scope || "-"),
              h("td", { style: { fontFamily: "var(--font-mono)", fontSize: "11px", wordBreak: "break-word" } }, e.query || "-"),
              h("td", { class: "right tnum" }, (typeof e.doc_count === "number") ? String(e.doc_count) : "-"));
          });
          kids.push(h("div", { class: "tablewrap", style: { marginBottom: "10px" } },
            h("table", { class: "grid" },
              h("thead", {}, h("tr", {},
                h("th", {}, "Source"), h("th", {}, "Scope"), h("th", {}, "Query"), h("th", { class: "right" }, "Docs"))),
              h("tbody", {}, rows))));
        } else {
          kids.push(h("p", { class: "muted", style: { margin: "0 0 10px" } }, "No evidence entries recorded."));
        }

        var red = enr.redaction || {};
        var applied = !!red.applied;
        var found = (typeof red.secrets_found === "number") ? red.secrets_found : 0;
        kids.push(h("div", { class: "eyebrow" }, "Redaction"));
        kids.push(h("div", { class: "row", style: { gap: "8px" } },
          api.pill(applied ? "Applied" : "Not applied", applied ? "ok" : "plain"),
          api.pill("Secrets found: " + found, found > 0 ? "warn" : "plain")));

        return api.groupbox("Work notes", kids);
      }

      // -- fetch + wire ----------------------------------------------------
      async function load() {
        refreshBtn.disabled = true;
        clear(leftPane);
        leftPane.appendChild(h("div", { class: "muted", style: { padding: "10px" } }, "Loading incidents…"));
        try {
          var data = await api.get("/api/incidents");
          tickets = Array.isArray(data) ? data : [];
          if (selectedCorr && !tickets.some(function (t) { return t.correlation_id === selectedCorr; })) selectedCorr = null;
          renderList();
          var sel = null;
          for (var i = 0; i < tickets.length; i++) { if (tickets[i].correlation_id === selectedCorr) { sel = tickets[i]; break; } }
          renderDetail(sel);
        } catch (err) {
          clear(leftPane);
          leftPane.appendChild(h("div", { class: "notice err", style: { margin: "8px" } },
            (err && err.message) ? err.message : "Failed to load incidents."));
          clear(rightPane);
          var detail = err && err.body && err.body.detail;
          rightPane.appendChild(h("div", { class: "muted", style: { padding: "12px" } },
            (err && err.status === 503) ? "The ticket store or cluster is not available right now." : "Unable to load the incident list.",
            detail ? h("div", { style: { marginTop: "6px" } }, String(detail)) : null));
        } finally {
          refreshBtn.disabled = false;
        }
      }

      renderDetail(null);
      load();
    },
  });
})();

