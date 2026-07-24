/* ===========================================================================
   ADK Studio, adk web. Embeds Google ADK's developer UI for the Olly Sentinel
   agent. Toolbar: "Launch adk web" runs the background make target that starts
   `adk web` on :8000 (streamed into a mini console), "Open ADK UI" points the
   embedded frame at /proxy/adk/, and "Open in new tab" hits the proxy directly.
   Honest about the embed: adk web is a dev-only Angular SPA and hosting it under
   a subpath is best-effort, if the frame stays blank, open it in a new tab.
   =========================================================================== */
"use strict";

Estate95.register({
  id: "adk-studio",
  title: "ADK Studio",
  icon: "🧪",
  short: "ADK Studio",
  width: 900,
  height: 600,

  open(body, api) {
    const h = api.h;

    // -- header ---------------------------------------------
    const header = h("div", { class: "stack", style: { gap: "3px" } },
      h("div", { class: "eyebrow" }, "Google ADK · adk web dev UI"),
      h("h3", {}, "The Olly Sentinel agent's developer studio"),
      h("p", { class: "muted", style: { marginBottom: "0" } },
        "Google ADK's dev UI for the Olly Sentinel agent. Its ",
        h("b", {}, "Trace"),
        " tab shows the tool trajectory (",
        h("i", {}, "model narrates, code decides"),
        "), and its ",
        h("b", {}, "Eval"),
        " tab runs the ",
        h("code", { class: "mono" }, "rca_readiness"),
        " eval."));

    // -- honesty notice: dev-only server, best-effort embed -----------------
    const notice = h("div", { class: "notice" },
      h("span", {}, "ℹ️"),
      h("div", {},
        h("strong", {}, "adk web is a dev-only server. "),
        "Embedding its Angular single-page app under a subpath (",
        h("code", { class: "mono" }, "/proxy/adk/"),
        ") is best-effort. The SPA may refuse to run framed, or load blank. ",
        "If the panel below stays empty after you ",
        h("b", {}, "Launch"),
        " then ",
        h("b", {}, "Open ADK UI"),
        ", use ",
        h("b", {}, "Open in new tab"),
        " instead."));

    // -- status pill (tracks launch + embed state) --------------------------
    const statusHost = h("span", { class: "row", style: { gap: "0", marginLeft: "auto" } });
    function setStatus(kind, text) {
      statusHost.innerHTML = "";
      statusHost.appendChild(api.pill(text, kind));
    }
    setStatus("plain", "not started");

    // -- the embedded frame + its placeholder -------------------------------
    // Frame host doubles as the flex-grow item so the iframe fills the window.
    const iframe = h("iframe", { title: "adk web developer UI", src: "about:blank" });

    const placeholder = h("div", {
      class: "stack",
      style: {
        height: "100%", alignItems: "center", justifyContent: "center",
        textAlign: "center", padding: "24px", gap: "8px",
      },
    },
      h("div", { style: { fontSize: "34px", lineHeight: "1" } }, "🧪"),
      h("div", {}, h("strong", {}, "The ADK studio isn't loaded yet.")),
      h("div", { class: "muted", style: { fontSize: "12px", maxWidth: "440px" } },
        "Click ",
        h("b", {}, "Launch adk web"),
        " to start the dev server on :8000, then ",
        h("b", {}, "Open ADK UI"),
        " to embed it here. It can take a few seconds for the server to answer."));

    const frameHost = h("div", {
      class: "frame-host",
      style: { flex: "1 1 auto", minHeight: "220px" },
    }, placeholder);

    // -- toolbar buttons ----------------------------------------------------
    const launchBtn = h("button", { class: "btn", title: "make olly-adk-web" }, "Launch adk web");
    const openBtn = h("button", { class: "btn" }, "Open ADK UI");
    const newTab = h("a", {
      class: "btn",
      href: "/proxy/adk/",
      target: "_blank",
      rel: "noopener",
      style: { textDecoration: "none" },
    }, "Open in new tab ↗");

    // -- mini console for the launch output ---------------------------------
    const miniConsole = h("div", {
      class: "console",
      style: { minHeight: "84px", maxHeight: "150px" },
    }, h("span", { class: "dim" },
      "Idle. Click “Launch adk web” to start the dev server on :8000.\n"));

    // Launch: background make target, streamed into the mini console.
    launchBtn.addEventListener("click", () => {
      launchBtn.disabled = true;
      setStatus("info", "starting adk web on :8000…");
      api.runAction("olly-adk-web", miniConsole, (code) => {
        launchBtn.disabled = false;
        if (code === 0) {
          setStatus("ok", "launched, now click Open ADK UI");
        } else {
          setStatus("warn", "launch exited " + code + ", check output");
        }
      });
    });

    // Open ADK UI: swap the placeholder for the embedded frame.
    openBtn.addEventListener("click", () => {
      setStatus("info", "loading /proxy/adk/ …");
      if (!frameHost.contains(iframe)) {
        frameHost.innerHTML = "";
        frameHost.appendChild(iframe);
      }
      // Re-point (or re-point again) so a second click reloads the frame.
      iframe.src = "/proxy/adk/";
    });

    // A load event tells us the proxy answered (not that the SPA is happy, // a framed-refusal still fires load, hence the honesty notice above).
    iframe.addEventListener("load", () => {
      if (iframe.src && iframe.src.indexOf("about:blank") === -1) {
        setStatus("ok", "embedded. If blank, use Open in new tab");
      }
    });

    const toolbar = h("div", { class: "row", style: { alignItems: "center" } },
      launchBtn, openBtn, newTab, statusHost);

    // -- assemble (full-height flex column; frame host grows to fill) -------
    body.appendChild(h("div", { class: "stack", style: { height: "100%", gap: "10px" } },
      header,
      notice,
      toolbar,
      api.groupbox("Launch output", miniConsole),
      frameHost));
  },
});

