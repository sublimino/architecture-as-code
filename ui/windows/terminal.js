/* ===========================================================================
   Estate 95, Scoped Terminal window.
   A dependency-free terminal over the broker's /ws/term WebSocket. The socket
   is a SCOPED, read-only, allow-listed runner (kubectl/flux/helm/rpk) bound to
   localhost, never a full shell. We render minimal ANSI colour and clears.
   =========================================================================== */
Estate95.register({
  id: "terminal",
  title: "Scoped Terminal",
  icon: "🖥️",
  short: "Terminal",
  width: 760,
  height: 460,
  open(body, api) {
    const h = api.h;

    // -- state ---------------------------------------------------------------
    let sock = null;
    let live = false;      // socket usable for sending
    let windowClosing = false;
    let curColor = null;   // current ANSI colour, null = console default
    api.onClose(() => { windowClosing = true; });

    // -- layout --------------------------------------------------------------
    body.style.display = "flex";
    body.style.flexDirection = "column";
    body.style.gap = "8px";
    body.style.overflow = "hidden";

    const notice = h("div", { class: "notice" },
      h("span", {}, "🔒"),
      h("span", {},
        "This is a ", h("b", {}, "scoped, read-only, allow-listed"),
        " terminal (kubectl / flux / helm / rpk) bound to localhost. It is a ",
        "demo convenience. Do not expose it to a network."));

    // Quick read-only commands. rpk won't reach the cluster from the host, // that's expected; kubectl/flux do the real work here.
    const QUICK = [
      "kubectl get pods -n olly-replica",
      "kubectl get kustomizations,ocirepositories,resourcesets -A",
      "flux get kustomizations",
      "rpk topic list",
    ];
    const quickBtns = [];
    const quickRow = h("div", { class: "row" },
      h("span", { class: "eyebrow", style: { margin: "0 4px 0 0" } }, "Quick:"),
      ...QUICK.map((cmd) => {
        const b = h("button", { class: "btn", type: "button", title: cmd,
          style: { minWidth: "0", fontFamily: "var(--font-mono)", fontSize: "11px" } }, cmd);
        b.addEventListener("click", () => run(cmd));
        quickBtns.push(b);
        return b;
      }));

    const out = h("div", { class: "console", style: { flex: "1 1 auto", minHeight: "0" } });

    const input = h("input", { class: "field", type: "text", spellcheck: "false",
      autocomplete: "off", placeholder: "type a read-only command, then Enter…",
      style: { flex: "1 1 auto", width: "auto" } });
    const runBtn = h("button", { class: "btn", type: "button", style: { flex: "0 0 auto" } }, "Run");
    const inputRow = h("div", { class: "row", style: { flexWrap: "nowrap" } }, input, runBtn);

    body.appendChild(notice);
    body.appendChild(quickRow);
    body.appendChild(out);
    body.appendChild(inputRow);

    // -- console writers -----------------------------------------------------
    function emitText(t) {
      if (!t) return;
      // Drop stray control chars we don't render; keep newlines/tabs (pre-wrap).
      t = t.replace(/\x1b/g, "").replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "");
      if (!t) return;
      out.appendChild(h("span", curColor ? { style: { color: curColor } } : {}, t));
    }

    // Handle one CSI escape sequence: colour (m), clear (J), or ignore the rest.
    function handleEscape(seq) {
      const final = seq[seq.length - 1];
      if (final === "J") { out.innerHTML = ""; curColor = null; return; }
      if (final === "m") {
        const raw = seq.slice(2, -1);
        const codes = raw === "" ? ["0"] : raw.split(";");
        for (const c of codes) {
          if (c === "0" || c === "") curColor = null;
          else if (c === "31" || c === "91") curColor = "#ff8a8a"; // red
          else if (c === "36" || c === "96") curColor = "#7fdfff"; // cyan
          else if (c === "32" || c === "92") curColor = "#8fe9a8"; // green
          else if (c === "33" || c === "93") curColor = "#f2d98a"; // yellow (bonus)
          // unknown SGR codes ignored
        }
        return;
      }
      // Cursor moves (H, f, A, G, K, …) and any other escape: strip silently.
    }

    // Split incoming text into escape sequences vs. plain runs and render.
    const CSI = /\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g;
    function write(text) {
      text = String(text).replace(/\r\n/g, "\n").replace(/\r/g, "");
      const nearBottom = out.scrollHeight - out.scrollTop - out.clientHeight < 24;
      let last = 0, m;
      CSI.lastIndex = 0;
      while ((m = CSI.exec(text))) {
        if (m.index > last) emitText(text.slice(last, m.index));
        handleEscape(m[0]);
        last = CSI.lastIndex;
      }
      if (last < text.length) emitText(text.slice(last));
      if (nearBottom) out.scrollTop = out.scrollHeight;
    }

    function echo(line) {
      out.appendChild(h("span", { class: "dim" }, "osramp$ "));
      out.appendChild(h("span", { class: "u" }, line + "\n"));
      out.scrollTop = out.scrollHeight;
    }

    function sysLine(text, cls) {
      out.appendChild(h("span", cls ? { class: cls } : {}, text + "\n"));
      out.scrollTop = out.scrollHeight;
    }

    // -- run a command -------------------------------------------------------
    function run(cmd) {
      const line = (cmd != null ? cmd : input.value);
      if (!line || !line.trim()) return;
      if (!live) { sysLine("not connected, command not sent", "r"); return; }
      echo(line);
      try { sock.send(line); }
      catch (_) { sysLine("send failed, socket not open", "r"); }
      input.value = "";
      input.focus();
    }

    function disableInput() {
      input.disabled = true;
      runBtn.disabled = true;
      for (const b of quickBtns) b.disabled = true;
    }

    runBtn.addEventListener("click", () => run());
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); run(); }
    });

    // -- open the socket -----------------------------------------------------
    try {
      sock = api.ws("/ws/term");
    } catch (err) {
      notice.className = "notice err";
      sysLine("could not open terminal socket: " + (err && err.message || err), "r");
      disableInput();
      return;
    }

    sysLine("connecting to scoped runner…", "dim");

    sock.onopen = () => {
      live = true;
      input.focus();
    };

    sock.onmessage = (ev) => {
      const data = ev.data;
      if (data instanceof Blob) {
        data.text().then(write).catch(() => {});
      } else {
        write(data);
      }
    };

    sock.onerror = () => {
      if (windowClosing) return;
      live = false;
      sysLine("socket error: the terminal connection failed", "r");
      disableInput();
    };

    sock.onclose = () => {
      live = false;
      if (windowClosing) return;
      sysLine("connection closed", "r");
      disableInput();
    };
  },
});

