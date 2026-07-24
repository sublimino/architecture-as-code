/* ===========================================================================
   Pipeline Panopticon. The client incident flow across the architecture, from
   an estate event through NOI's subscription and automation gates to Olly's
   triage and the ServiceNow INC. Each gate on the flow (subscription,
   automation-eligibility, triage, HITL, publish, ticket-write) is a node, and
   the branch an incident takes lights up per correlation-ID from the
   olly.pipeline.decisions bus. Every path terminates at ServiceNow: an
   unsubscribed event raises a raw INC directly, a self-healed event returns an
   automation result, and an enriched or parked event lands an enriched INC.
   Internal guards that only fire on replayed or malformed test data (schema
   validation, source filtering, dedup, loop-guard) still stream to the decision
   feed but are not drawn as branches, so the diagram reads as the client flow.
   Each decision carries its real Kafka coordinates (topic, partition, offset,
   key) and the gate reason; clicking a decision shows the raw record and
   clicking a node shows the real logs, Kafka messages, or tickets behind it.
   Reads /api/pipeline/events (SSE: hello, stage, decision, ticket, ping).
   =========================================================================== */
"use strict";

Estate95.register({
  id: "pipeline",
  title: "Pipeline Panopticon",
  icon: "🗼",
  short: "Pipeline",
  width: 1060,
  height: 740,

  open(body, api) {
    const h = api.h;

    // -- the decision graph: nodes and the branch edges between them ---------
    // id -> { label, sub, col, row, kind }.  kind colours the node.
    const NODES = {
      event:     { label: "Infra / App event", sub: "monitored estate", col: 0, row: 3, kind: "src" },
      noi:       { label: "NOI", sub: "normalise · dedup · subscription", col: 1, row: 3, kind: "proc" },
      raw:       { label: "Raw INC", sub: "no subscription · unenriched", col: 2, row: 0, kind: "term" },
      queue:     { label: "netcool.io.events", sub: "NOI event queue", col: 2, row: 4, kind: "topic" },
      auto:      { label: "IO Automation", sub: "Ansible AAP · self-heal", col: 3, row: 2, kind: "proc" },
      declined:  { label: "netcool.io.events.declined", sub: "routed to Olly", col: 3, row: 5, kind: "topic" },
      olly:      { label: "Olly Sentinel", sub: "7-tool MCP · RCA", col: 4, row: 5, kind: "agent" },
      parked:    { label: "Parked → Orbit", sub: "awaiting approval", col: 5, row: 6, kind: "hitl" },
      response:  { label: "event_response", sub: "enrichment / automation result", col: 5, row: 3, kind: "topic" },
      ticket:    { label: "ServiceNow INC", sub: "Mapping Service writes", col: 6, row: 2, kind: "sink" },
    };

    // The client incident flow. Each edge is a hop between components; the ones
    // that carry a (gate, branch) are the decisions the bus reports and light up
    // per correlation-ID. Internal guards that only fire on replayed or malformed
    // test data (schema_validate, source_filter/skip, dedup, loop_guard) still
    // stream to the decision feed below, but are not drawn here so the diagram
    // stays the client flow and does not read as routine rejection.
    const EDGES = [
      { from: "event", to: "noi" },
      { gate: "subscription", branch: "reject", from: "noi", to: "raw", label: "not subscribed" },
      { gate: "subscription", branch: "pass", from: "noi", to: "queue", label: "subscribed" },
      { gate: "automation_eligibility", branch: "auto_remediated", from: "queue", to: "auto", label: "eligible" },
      { gate: "automation_eligibility", branch: "pass", from: "queue", to: "declined", label: "declined" },
      { from: "auto", to: "response", label: "result" },
      { from: "raw", to: "ticket", label: "raise INC" },
      { gate: "source_filter", branch: "pass", from: "declined", to: "olly", label: "triage" },
      { gate: "hitl", branch: "parked", from: "olly", to: "parked", label: "low-confidence / restart" },
      { gate: "publish", branch: "complete", from: "olly", to: "response", label: "enriched" },
      { gate: "ticket_write", branch: "complete", from: "response", to: "ticket", label: "write" },
    ];

    // colour per node kind
    const KIND = {
      src: "#1466b8", proc: "#6b4fbb", topic: "#b3760a", agent: "#0a7d0a",
      hitl: "#8a6d00", term: "#8b0000", sink: "#0a5a8a",
    };

    // -- layout scaffolding -------------------------------------------------
    body.style.display = "flex";
    body.style.flexDirection = "column";
    body.style.gap = "8px";

    const statusHolder = h("span", {});
    const header = h("div", { style: { display: "flex", justifyContent: "space-between", alignItems: "flex-end", gap: "10px", flexWrap: "wrap" } },
      h("div", {},
        h("div", { class: "eyebrow" }, "Incident decision tree · live"),
        h("div", { style: { fontSize: "13px", lineHeight: "1.35" } },
          "Each edge is a gate on ", h("code", {}, "olly.pipeline.decisions"),
          "; the branch an incident takes lights up as it happens.")),
      h("div", { style: { display: "flex", gap: "8px", alignItems: "center" } }, statusHolder));

    const errorSlot = h("div", {});
    const hint = h("div", { class: "notice" },
      h("span", {}, "Nothing moving? Open ", h("strong", {}, "Control Plane"),
        " and replay an event, or ", h("code", {}, "make -C olly-replica replay APP=payments-api"),
        ". Try an unsubscribed app or an OOM incident to light the other branches."));

    // The graph canvas. Edges (SVG) and nodes (divs) share one coordinate space
    // that scales as a unit: the SVG stretches its viewBox to fill the container
    // (preserveAspectRatio none) and the nodes are positioned as percentages of
    // the same space, so they stay aligned at any window size. An aspect-ratio
    // container keeps the scaling uniform.
    const COLW = 134, ROWH = 74, PADX = 10, PADY = 10, NODEW = 120, NODEH = 54;
    const cols = 7, rows = 7;
    const canvasW = PADX * 2 + cols * COLW;
    const canvasH = PADY * 2 + rows * ROWH;
    const svgNS = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(svgNS, "svg");
    svg.setAttribute("viewBox", `0 0 ${canvasW} ${canvasH}`);
    svg.setAttribute("preserveAspectRatio", "none");
    svg.style.cssText = "position:absolute;inset:0;width:100%;height:100%;display:block;";

    const inner = h("div", { style: {
      position: "relative", width: "100%", minWidth: "720px",
      aspectRatio: canvasW + " / " + canvasH,
    } });
    const nodeLayer = h("div", { style: { position: "absolute", inset: "0", pointerEvents: "none" } });
    inner.append(svg, nodeLayer);
    const graphWrap = h("div", { style: {
      boxShadow: "var(--bevel-thin-in)", background: "rgba(255,255,255,.4)",
      overflow: "auto", flex: "1 1 auto", minWidth: "0",
    } }, inner);

    // Percentages of the shared coordinate space, so nodes track the viewBox.
    const px = (v) => (v / canvasW * 100) + "%";
    const py = (v) => (v / canvasH * 100) + "%";
    const nx = (c) => PADX + c * COLW + (COLW - NODEW) / 2;
    const ny = (r) => PADY + r * ROWH + (ROWH - NODEH) / 2;
    const cx = (c) => nx(c) + NODEW;               // right edge
    const cxl = (c) => nx(c);                       // left edge
    const cyc = (r) => ny(r) + NODEH / 2;           // vertical centre

    // Edges that share the same endpoints (e.g. the two ways into "Duplicate /
    // loop-guarded") would otherwise draw one line over another and stack their
    // labels; count them so each parallel run can bow apart by a fixed offset.
    const pairSize = {};
    for (const e of EDGES) { const k = e.from + ">" + e.to; pairSize[k] = (pairSize[k] || 0) + 1; }
    const pairSeen = {};

    // draw edges
    const edgeEls = [];
    for (const e of EDGES) {
      const a = NODES[e.from], b = NODES[e.to];
      if (!a || !b) continue;
      const pk = e.from + ">" + e.to;
      const gi = pairSeen[pk] = (pairSeen[pk] || 0);
      pairSeen[pk] = gi + 1;
      const bow = pairSize[pk] > 1 ? (gi - (pairSize[pk] - 1) / 2) * 18 : 0; // vertical spread for parallels
      const x1 = cx(a.col), y1 = cyc(a.row), x2 = cxl(b.col), y2 = cyc(b.row);
      const midx = (x1 + x2) / 2;
      const path = document.createElementNS(svgNS, "path");
      path.setAttribute("d", `M ${x1} ${y1} C ${midx} ${y1 + bow}, ${midx} ${y2 + bow}, ${x2} ${y2}`);
      path.setAttribute("fill", "none");
      path.setAttribute("stroke", "#9aa0a6");
      path.setAttribute("stroke-width", "1.4");
      path.setAttribute("opacity", "0.55");
      svg.appendChild(path);
      let labelEl = null;
      if (e.label) {
        labelEl = document.createElementNS(svgNS, "text");
        labelEl.setAttribute("x", midx);
        labelEl.setAttribute("y", (y1 + y2) / 2 + bow - 3);
        labelEl.setAttribute("text-anchor", "middle");
        labelEl.setAttribute("font-size", "9");
        labelEl.setAttribute("fill", "#3a3a3a");
        // White halo (stroke painted under the fill) so labels stay legible
        // over the edge lines and the translucent graph background.
        labelEl.setAttribute("stroke", "#ffffff");
        labelEl.setAttribute("stroke-width", "3");
        labelEl.setAttribute("stroke-linejoin", "round");
        labelEl.setAttribute("paint-order", "stroke");
        labelEl.textContent = e.label;
        svg.appendChild(labelEl);
      }
      edgeEls.push({ e, path, labelEl, count: 0 });
    }

    // draw nodes (clickable: each opens the real data behind it)
    const nodeEls = {};
    for (const [id, n] of Object.entries(NODES)) {
      const el = h("div", {
        title: "Click to see the real logs / Kafka messages behind this node",
        style: {
          position: "absolute", left: px(nx(n.col)), top: py(ny(n.row)),
          width: px(NODEW), height: py(NODEH),
          boxShadow: "var(--bevel-thin-out)", background: "#ececec",
          borderLeft: "4px solid " + (KIND[n.kind] || "#888"),
          padding: "3px 5px", fontSize: "10px", lineHeight: "1.15", overflow: "hidden",
          boxSizing: "border-box", pointerEvents: "auto", cursor: "pointer",
        },
      },
        h("div", { style: { fontWeight: "700", fontSize: "11px", lineHeight: "1.15", overflow: "hidden", paddingRight: "14px",
          display: "-webkit-box", WebkitLineClamp: "2", WebkitBoxOrient: "vertical" } }, n.label),
        h("div", { class: "muted", style: { fontSize: "9px", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" } }, n.sub),
        h("span", { class: "pill plain tnum", style: { fontSize: "9px", padding: "0 4px", position: "absolute", right: "3px", top: "3px" } }, "0"));
      el.addEventListener("click", () => inspectNode(id, n.label));
      nodeLayer.appendChild(el);
      nodeEls[id] = { el, badge: el.lastChild, count: 0 };
    }

    // -- decision feed + kafka detail ---------------------------------------
    const feedBody = h("tbody", {});
    const feedEmpty = h("div", { class: "muted", style: { fontSize: "11px", padding: "4px 2px" } }, "Waiting for the first decision…");
    const feed = h("div", { class: "tablewrap", style: { maxHeight: "150px" } },
      h("table", { class: "grid" },
        h("thead", {}, h("tr", {},
          h("th", {}, "Time"), h("th", {}, "Component"), h("th", {}, "Gate"), h("th", {}, "Branch"),
          h("th", {}, "part/off"), h("th", {}, "Correlation"))),
        feedBody));
    const feedGb = api.groupbox("Decision bus · olly.pipeline.decisions (click a row for the raw record)", feedEmpty, feed);
    feedGb.style.margin = "0";
    feedGb.style.flex = "1 1 380px";

    // Bottom console: the raw decision record, opened by clicking a decision row.
    const detail = h("div", { class: "console", style: { minHeight: "150px", maxHeight: "150px", fontSize: "11px" } },
      h("span", { class: "dim" }, "Click a decision row above to inspect its raw Kafka record.\n"));
    const detailGb = api.groupbox("Decision record", detail);
    detailGb.style.margin = "0";
    detailGb.style.flex = "1 1 320px";

    const bottom = h("div", { style: { display: "flex", gap: "10px", flexWrap: "wrap" } }, feedGb, detailGb);

    // Right-side node pane: opens beside the diagram when a node is clicked,
    // and closes with the ✕. Holds the real logs / Kafka messages behind a node.
    const nodeTitle = h("span", { class: "t-name", style: { flex: "1 1 auto", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" } }, "Node");
    const nodeConsole = h("div", { class: "console", style: { flex: "1 1 auto", fontSize: "11px", overflow: "auto", minHeight: "0" } });
    const nodeClose = h("button", { class: "tbtn", title: "Close" }, "✕");
    const nodePane = h("div", {
      style: {
        display: "none", flexDirection: "column", flex: "0 0 320px", minWidth: "260px",
        boxShadow: "var(--bevel-out)", background: "var(--silver)", padding: "2px",
      },
    },
      h("div", { class: "titlebar", style: { display: "flex", alignItems: "center", gap: "6px", flex: "0 0 auto" } },
        h("span", { class: "t-ico" }, "🔎"), nodeTitle, h("div", { class: "tbtns" }, nodeClose)),
      h("div", { style: { flex: "1 1 auto", display: "flex", flexDirection: "column", padding: "3px", minHeight: "0" } }, nodeConsole));
    nodeClose.addEventListener("click", () => { nodePane.style.display = "none"; });

    // The decision tree with the node pane docked on its right.
    const graphRow = h("div", { style: { display: "flex", gap: "8px", alignItems: "stretch", flex: "0 0 auto", minHeight: "0" } }, graphWrap, nodePane);

    body.append(header, errorSlot, hint, graphRow, bottom);

    // -- helpers ------------------------------------------------------------
    function setStatus(kind) {
      const map = { live: ["live", "ok"], waiting: ["waiting for events…", "plain"], down: ["cluster not ready", "crit"], connecting: ["connecting…", "plain"] };
      const conf = map[kind] || map.connecting;
      statusHolder.innerHTML = "";
      statusHolder.appendChild(api.pill(conf[0], conf[1]));
    }
    function showError() {
      errorSlot.innerHTML = "";
      errorSlot.appendChild(h("div", { class: "notice err" },
        h("span", {}, "Cluster not ready. The decision stream is unavailable (namespace or Redpanda down). Bring the stack up from Control Plane; this view reconnects.")));
    }
    const clearError = () => { errorSlot.innerHTML = ""; };
    const shortId = (c, n) => { const s = c == null ? "" : String(c); const lim = n || 12; return s.length > lim + 1 ? s.slice(0, lim) + "…" : (s || "-"); };
    const fmtTime = (ts) => new Date(Number(ts) || Date.now()).toLocaleTimeString([], { hour12: false });

    // edge lookup by (gate, branch)
    const edgeFor = (gate, branch) => edgeEls.find((x) => x.e.gate === gate && x.e.branch === branch);

    // light an edge + its endpoint node, briefly pulse
    let pulseTimers = new Set();
    function lightEdge(rec) {
      const found = edgeFor(rec.gate, rec.branch);
      if (!found) return;
      found.count += 1;
      found.path.setAttribute("stroke", KIND[NODES[found.e.to].kind] || "#0a7d0a");
      found.path.setAttribute("stroke-width", "2.6");
      found.path.setAttribute("opacity", "1");
      const tn = nodeEls[found.e.to];
      if (tn) { tn.count += 1; tn.badge.textContent = String(tn.count); tn.el.style.boxShadow = "0 0 0 2px " + (KIND[NODES[found.e.to].kind] || "#0a7d0a") + ", var(--bevel-thin-out)"; }
      const id = setTimeout(() => {
        found.path.setAttribute("stroke", "#9aa0a6");
        found.path.setAttribute("stroke-width", "1.4");
        found.path.setAttribute("opacity", "0.55");
        if (tn) tn.el.style.boxShadow = "var(--bevel-thin-out)";
        pulseTimers.delete(id);
      }, 1400);
      pulseTimers.add(id);
    }

    // Clicking a node opens the right-side pane with the real data behind it
    // (Kafka messages, pod logs, or the ticket store), so the flow can be
    // proven against live systems.
    async function inspectNode(id, label) {
      nodePane.style.display = "flex";
      nodeTitle.textContent = label;
      nodeConsole.innerHTML = "";
      nodeConsole.appendChild(h("span", { class: "dim" }, "Fetching real records for " + label + "…\n"));
      let data;
      try {
        data = await api.get("/api/pipeline/node/" + id);
      } catch (err) {
        nodeConsole.innerHTML = "";
        nodeConsole.appendChild(h("span", { class: "r" },
          (err && err.status === 503 ? "Cluster not reachable. Bring the demo up from Control Plane.\n"
            : "Could not load node data: " + ((err && err.message) || "unknown") + "\n")));
        return;
      }
      nodeConsole.innerHTML = "";
      const kindLabel = { topic: "kafka topic", logs: "pod logs", incidents: "ServiceNow store" }[data.kind] || data.kind;
      nodeConsole.appendChild(h("span", { class: "dim" }, "// " + (data.title || label) + "\n// [" + kindLabel +
        (data.source ? " · " + data.source : "") + "]\n\n"));
      for (const ln of (data.lines || [])) {
        nodeConsole.appendChild(h("span", {}, String(ln) + "\n"));
      }
      nodeConsole.scrollTop = 0;
    }

    function showDetail(rec) {
      detail.innerHTML = "";
      const kv = (k, v) => detail.appendChild(h("span", {}, h("span", { class: "dim" }, (k + ":").padEnd(15)), (v == null ? "" : String(v)) + "\n"));
      kv("topic", rec.topic);
      kv("partition", rec.partition);
      kv("offset", rec.offset);
      kv("key", rec.key);
      kv("component", rec.component);
      kv("gate", rec.gate);
      kv("branch", rec.branch);
      kv("correlation_id", rec.correlation_id);
      kv("event_id", rec.event_id);
      kv("app_id", rec.app_id);
      if (rec.fault_domain) kv("fault_domain", rec.fault_domain);
      kv("reason", rec.reason);
      if (rec.detail) detail.appendChild(h("span", {}, h("span", { class: "dim" }, "detail:         "), JSON.stringify(rec.detail) + "\n"));
    }

    const branchKind = (b) => ({
      pass: "ok", complete: "ok", auto_remediated: "info", reject: "crit",
      skip: "plain", duplicate: "warn", loop_guarded: "warn", parked: "warn", engaged: "info", fail: "crit",
    }[b] || "plain");

    function pushFeed(rec) {
      const tr = h("tr", { class: "clickable" },
        h("td", { class: "tnum muted", style: { whiteSpace: "nowrap" } }, fmtTime(rec.ts)),
        h("td", { style: { fontSize: "11px" } }, (rec.component || "").replace("noi_mapping_service", "mapping").replace("olly_sentinel", "olly")),
        h("td", { style: { fontSize: "11px" } }, rec.gate || "-"),
        h("td", {}, api.pill(rec.branch || "-", branchKind(rec.branch))),
        h("td", { class: "mono", style: { fontSize: "10px" } }, (rec.partition || "0") + "/" + (rec.offset || "-")),
        h("td", { class: "mono", style: { fontSize: "10px" } }, shortId(rec.correlation_id, 14)));
      tr.addEventListener("click", () => showDetail(rec));
      feedBody.insertBefore(tr, feedBody.firstChild);
      while (feedBody.children.length > 40) feedBody.removeChild(feedBody.lastChild);
      feedEmpty.style.display = "none";
    }

    function onDecision(rec) {
      if (!rec) return;
      lightEdge(rec);
      pushFeed(rec);
    }

    // -- legend -------------------------------------------------------------
    const legend = h("div", { class: "row", style: { gap: "10px", flexWrap: "wrap", fontSize: "10px", marginTop: "2px" } },
      ...Object.entries({ "self-heal (automation)": "info", "enriched (Olly)": "ok", "raw INC · no subscription": "crit", "parked (Orbit HITL)": "warn" })
        .map(([t, k]) => h("span", { class: "row", style: { gap: "4px", alignItems: "center" } }, api.pill("", k), h("span", { class: "muted" }, t))));
    body.insertBefore(legend, bottom);

    // -- live stream --------------------------------------------------------
    setStatus("waiting");
    api.sse("/api/pipeline/events", {
      hello: () => { clearError(); setStatus("live"); },
      decision: (d) => { clearError(); setStatus("live"); onDecision(d); },
      stage: () => { clearError(); setStatus("live"); },
      ticket: () => { clearError(); },
      ping: () => { clearError(); setStatus("live"); },
      error: () => { setStatus("down"); showError(); },
    });

    api.onClose(() => { for (const id of pulseTimers) clearTimeout(id); pulseTimers.clear(); });
  },
});
