/* ===========================================================================
   Eye in the Sky, Grafana. The control-tower estate view: the "eye-in-the-sky"
   Grafana carrying the tenant dashboards and the Trivy / Aqua security metrics, the telemetry the Olly-Sentinel agent reads from. Embeds Grafana in an iframe
   via /proxy/grafana/ with an honest note that Grafana blocks embedding by
   default (allow_embedding=false) and may prompt for the admin login. Never
   touches the JSON API, so it cannot crash the desktop if the proxy 503s, a
   blank / login panel is handled with a plain-English fallback to a new tab.
   =========================================================================== */
"use strict";

Estate95.register({
  id: "grafana",
  title: "Eye in the Sky",
  icon: "📈",
  short: "Grafana",
  width: 900,
  height: 600,

  open(body, api) {
    const h = api.h;
    const PROXY = "/proxy/grafana/";

    // The body is the flex-filling window pane; lay it out as a column so the
    // iframe host can grow to take all the space under the toolbar + notes.
    body.style.display = "flex";
    body.style.flexDirection = "column";
    body.style.gap = "10px";

    // -- header -------------------------------------------------------------
    body.appendChild(h("div", { class: "stack", style: { gap: "4px", flex: "0 0 auto" } },
      h("div", { class: "eyebrow" }, "Control tower · estate view"),
      h("div", { class: "row", style: { gap: "8px", alignItems: "baseline" } },
        h("h2", { style: { fontSize: "18px" } }, "Eye in the Sky"),
        api.pill("Grafana", "info")),
      h("p", { class: "muted", style: { margin: "0", fontSize: "12px" } },
        "The eye-in-the-sky Grafana over the whole estate: the tenant dashboards ",
        "and the Trivy / Aqua security metrics. This is the telemetry the agent reads from.")));

    // -- status pill (reflects whether the panel has been opened) ------------
    const statusHost = h("span", { class: "row", style: { gap: "8px", marginLeft: "auto" } });
    function setStatus(kind, text) {
      statusHost.innerHTML = "";
      statusHost.appendChild(api.pill(text, kind));
    }

    // -- the iframe host + its "not opened yet" placeholder ------------------
    const placeholder = h("div", {
      class: "stack",
      style: {
        gap: "8px", alignItems: "center", justifyContent: "center",
        height: "100%", textAlign: "center", padding: "24px",
      },
    },
      h("div", { style: { fontSize: "34px", lineHeight: "1" } }, "📈"),
      h("div", { style: { fontWeight: "700" } }, "Grafana isn't loaded yet."),
      h("div", { class: "muted", style: { fontSize: "12px", maxWidth: "460px" } },
        "Press “Open dashboard” to embed the eye-in-the-sky Grafana below, ",
        "or “Open in new tab” to open it directly without the embedding limits."));

    const iframe = h("iframe", {
      title: "Eye in the Sky Grafana",
      style: { display: "none" },
    });
    // The iframe fires 'load' for a real dashboard, a login page, or an error
    // page alike, so treat it only as "the proxy answered", not "it worked".
    iframe.addEventListener("load", () => {
      if (opened) setStatus("warn", "loaded · if blank or a login, use new tab");
    });

    const host = h("div", { class: "frame-host", style: { flex: "1 1 auto", minHeight: "0", position: "relative" } },
      placeholder, iframe);

    // -- toolbar ------------------------------------------------------------
    let opened = false;

    const openBtn = h("button", { class: "btn" }, "Open dashboard");
    const reloadBtn = h("button", { class: "btn", disabled: true }, "Reload");
    const newTab = h("a", {
      class: "btn",
      href: PROXY,
      target: "_blank",
      rel: "noopener noreferrer",
      style: { display: "inline-block", textAlign: "center", textDecoration: "none", lineHeight: "1.5" },
    }, "Open in new tab ↗");

    function openDashboard() {
      opened = true;
      // Cache-bust so a repeat "Open" / "Reload" always re-hits the proxy.
      iframe.src = PROXY + "?ts=" + Date.now();
      iframe.style.display = "block";
      placeholder.style.display = "none";
      reloadBtn.disabled = false;
      openBtn.textContent = "Reopen dashboard";
      setStatus("plain", "loading proxy…");
    }

    openBtn.addEventListener("click", openDashboard);
    reloadBtn.addEventListener("click", () => { if (opened) openDashboard(); });

    const toolbar = h("div", { class: "row", style: { gap: "8px", alignItems: "center", flex: "0 0 auto" } },
      openBtn, reloadBtn, newTab, statusHost);
    // Place the toolbar right under the header (before the notice + host).
    body.appendChild(toolbar);

    // -- honest embedding caveat --------------------------------------------
    body.appendChild(h("div", { class: "notice", style: { flex: "0 0 auto" } },
      h("span", {}, "⚠️"),
      h("div", { class: "stack", style: { gap: "3px" } },
        h("div", {},
          h("b", {}, "Grafana blocks iframe embedding by default "),
          "(", h("code", {}, "allow_embedding=false"), ") and may prompt for the ",
          h("code", {}, "admin"), " login."),
        h("div", { class: "muted", style: { fontSize: "11px" } },
          "If the panel below is blank or shows a login screen, use ",
          h("b", {}, "Open in new tab"), ", or enable ",
          h("code", {}, "allow_embedding"), " + an anonymous viewer role in the ",
          "eye-in-the-sky HelmRelease to embed it here."))));

    // -- the iframe host, last so it fills the remaining height --------------
    body.appendChild(host);

    setStatus("plain", "not opened");

    // Nothing to poll or subscribe to, the proxy is only ever hit inside the
    // iframe, so there is no timer / socket to tear down on close.
  },
});

