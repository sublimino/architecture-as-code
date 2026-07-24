/* ===========================================================================
   Cluster State, a live view of the OSRAMP / Olly-Sentinel workload.
   Two panes: Kubernetes pods and Flux reconciliation. Defaults to the
   olly-replica + flux-system namespaces; a checkbox widens to everything.
   Polls /api/cluster/overview every 5s and survives a down cluster (503).
   =========================================================================== */
"use strict";

Estate95.register({
  id: "cluster",
  title: "Cluster State",
  icon: "☸️",
  short: "Cluster",
  width: 820,
  height: 560,

  open(body, api) {
    const h = api.h;
    const ALLOWED = new Set(["olly-replica", "flux-system"]);

    // -- shared render state -------------------------------------------------
    let lastData = null;   // last successful /api/cluster/overview payload
    let lastError = null;  // last fetch error (Error with .status/.body)
    let loading = false;

    // -- small helpers -------------------------------------------------------
    // Pod "ready" is a "n/n" string; ok only when every container is up.
    function podIsReady(r) {
      const parts = String(r == null ? "" : r).split("/");
      if (parts.length !== 2) return false;
      const up = Number(parts[0]), total = Number(parts[1]);
      return Number.isFinite(up) && Number.isFinite(total) && total > 0 && up === total;
    }
    // Flux "ready" is "True"/"False" (string), or a bare boolean, defensively.
    function fluxKind(r) {
      if (r === true || r === "True") return "ok";
      if (r === false || r === "False") return "crit";
      return "warn";
    }
    function fluxLabel(r) {
      if (r === true) return "True";
      if (r === false) return "False";
      return r == null || r === "" ? "Unknown" : String(r);
    }
    function nowStr() {
      const d = new Date();
      const h12 = d.getHours() % 12 || 12;
      const mm = String(d.getMinutes()).padStart(2, "0");
      const ss = String(d.getSeconds()).padStart(2, "0");
      return `${h12}:${mm}:${ss} ${d.getHours() >= 12 ? "PM" : "AM"}`;
    }

    // -- top control row -----------------------------------------------------
    const refreshBtn = h("button", { class: "btn", onclick: () => load() }, "Refresh");
    const chk = h("input", { type: "checkbox" });
    chk.addEventListener("change", () => renderData());
    const allLabel = h("label", { class: "row", style: { gap: "5px", cursor: "pointer" } }, chk, "show all namespaces");
    const statusHost = h("span", { class: "row", style: { gap: "8px", marginLeft: "auto" } });

    const controls = h("div", { class: "row", style: { marginBottom: "10px" } },
      refreshBtn, allLabel, statusHost);

    // -- content region (rebuilt on every render) ----------------------------
    const content = h("div", { class: "stack", style: { gap: "12px" } });

    body.appendChild(h("div", { class: "stack", style: { gap: "0" } }, controls, content));

    // -- status pill ---------------------------------------------------------
    function setStatus(kind, text) {
      statusHost.innerHTML = "";
      statusHost.appendChild(api.pill(text, kind));
    }

    // -- table builders ------------------------------------------------------
    function podsBox(pods, showAll) {
      const readyN = pods.filter((p) => podIsReady(p.ready)).length;
      const rows = pods.length
        ? pods.map((p) =>
            h("tr", {},
              h("td", { class: "mono" }, p.ns == null ? "-" : String(p.ns)),
              h("td", { class: "mono" }, p.name == null ? "-" : String(p.name)),
              h("td", {}, api.pill(p.ready == null ? "-" : String(p.ready), podIsReady(p.ready) ? "ok" : "warn")),
              h("td", {}, p.status == null ? "-" : String(p.status)),
              h("td", { class: "right tnum" }, String(p.restarts == null ? 0 : p.restarts))))
        : [h("tr", {}, h("td", { colspan: 5, class: "muted" },
            showAll ? "No pods reported by the cluster." : "No pods in olly-replica or flux-system."))];

      return api.groupbox("Pods",
        h("div", { class: "tablewrap", style: { maxHeight: "220px" } },
          h("table", { class: "grid" },
            h("thead", {}, h("tr", {},
              h("th", {}, "NS"), h("th", {}, "Name"), h("th", {}, "Ready"),
              h("th", {}, "Status"), h("th", { class: "right" }, "Restarts"))),
            h("tbody", {}, ...rows))),
        h("div", { class: "muted", style: { marginTop: "6px", fontSize: "11px" } },
          `${readyN}/${pods.length} pods ready`));
    }

    function fluxBox(flux, showAll) {
      const readyN = flux.filter((f) => fluxKind(f.ready) === "ok").length;
      const rows = flux.length
        ? flux.map((f) =>
            h("tr", {},
              h("td", { class: "mono" }, f.kind == null ? "-" : String(f.kind)),
              h("td", { class: "mono" }, f.ns == null ? "-" : String(f.ns)),
              h("td", { class: "mono" }, f.name == null ? "-" : String(f.name)),
              h("td", {}, api.pill(fluxLabel(f.ready), fluxKind(f.ready))),
              h("td", {}, f.status == null ? "-" : String(f.status))))
        : [h("tr", {}, h("td", { colspan: 5, class: "muted" },
            showAll ? "No Flux resources reported." : "No Flux resources in olly-replica or flux-system."))];

      return api.groupbox("Flux reconciliation",
        h("div", { class: "tablewrap", style: { maxHeight: "220px" } },
          h("table", { class: "grid" },
            h("thead", {}, h("tr", {},
              h("th", {}, "Kind"), h("th", {}, "NS"), h("th", {}, "Name"),
              h("th", {}, "Ready"), h("th", {}, "Status"))),
            h("tbody", {}, ...rows))),
        h("div", { class: "muted", style: { marginTop: "6px", fontSize: "11px" } },
          `reconciled: ${readyN}/${flux.length} ready`));
    }

    // -- render (pure: reads lastData/lastError + the checkbox) ---------------
    function renderData() {
      content.innerHTML = "";

      if (lastError && !lastData) {
        const detail = lastError.body && lastError.body.detail;
        content.appendChild(h("div", { class: "notice err" },
          h("div", { class: "stack", style: { gap: "3px" } },
            h("strong", {}, "Cluster not ready"),
            h("div", {}, lastError.message || "Could not reach the cluster overview."),
            detail ? h("div", { class: "muted" }, String(detail)) : null,
            h("div", { class: "muted", style: { fontSize: "11px" } }, "Still polling. This pane will fill in once the cluster answers."))));
        return;
      }

      if (!lastData) {
        content.appendChild(h("div", { class: "notice" }, "Loading cluster overview…"));
        return;
      }

      const showAll = chk.checked;
      const pods = (lastData.pods || []).filter((p) => showAll || ALLOWED.has(p && p.ns));
      const flux = (lastData.flux || []).filter((f) => showAll || ALLOWED.has(f && f.ns));

      // A live cluster can still report itself not-ready (booting / mid-reconcile).
      if (lastData.ready === false) {
        content.appendChild(h("div", { class: "notice" },
          "The cluster reports it is not fully ready yet. Some workloads may still be starting."));
      }
      if (lastError) {
        content.appendChild(h("div", { class: "notice err" },
          "Last refresh failed (" + (lastError.message || "unreachable") + "). Showing the previous snapshot."));
      }

      content.appendChild(podsBox(pods, showAll));
      content.appendChild(fluxBox(flux, showAll));
    }

    // -- fetch loop ----------------------------------------------------------
    async function load() {
      if (loading) return;
      loading = true;
      refreshBtn.disabled = true;
      try {
        const data = await api.get("/api/cluster/overview");
        lastData = data || {};
        lastError = null;
        setStatus(lastData.ready === false ? "warn" : "ok", "live · updated " + nowStr());
      } catch (err) {
        lastError = err;
        setStatus("crit", (err && err.status === 503) ? "cluster not ready" : "refresh failed");
      } finally {
        loading = false;
        refreshBtn.disabled = false;
        renderData();
      }
    }

    // -- boot + auto-refresh -------------------------------------------------
    setStatus("plain", "connecting…");
    load();
    const t = setInterval(load, 5000);
    api.onClose(() => clearInterval(t));
  },
});

