/* ===========================================================================
   Estate 95 core, window manager, desktop, taskbar, start menu, and the API
   every window module builds on. Window modules call Estate95.register({...})
   at load; Estate95.boot() wires the desktop after they've all registered.
   =========================================================================== */
"use strict";

const Estate95 = (() => {
  const REGISTRY = [];
  const OPEN = new Map(); // id -> {def, el, body, cleanups[]}
  const DESK_ICONS = new Map(); // id -> desktop icon element (for badging)
  const TOASTS = new Map();      // key -> toast element (dedupe)
  let zTop = 10;
  let cascade = 0;

  // -- tiny hyperscript DOM helper ------------------------------------------
  function h(tag, props, ...kids) {
    const el = document.createElement(tag);
    if (props) {
      for (const [k, v] of Object.entries(props)) {
        if (k === "class") el.className = v;
        else if (k === "html") el.innerHTML = v;
        else if (k === "style" && typeof v === "object") Object.assign(el.style, v);
        else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2).toLowerCase(), v);
        else if (v === true) el.setAttribute(k, "");
        else if (v !== false && v != null) el.setAttribute(k, v);
      }
    }
    for (const kid of kids.flat()) {
      if (kid == null || kid === false) continue;
      el.appendChild(typeof kid === "string" ? document.createTextNode(kid) : kid);
    }
    return el;
  }

  // -- per-window API surface -----------------------------------------------
  function makeApi(entry) {
    const track = (closer) => { entry.cleanups.push(closer); return closer; };
    return {
      h,
      pill: (text, kind = "plain") => h("span", { class: "pill " + kind }, text),
      groupbox: (legend, ...kids) => h("div", { class: "gb" }, h("span", { class: "lg" }, legend), ...kids),
      async get(path) {
        const r = await fetch(path);
        const t = await r.text();
        let body; try { body = JSON.parse(t); } catch { body = t; }
        if (!r.ok) throw Object.assign(new Error((body && body.error) || r.statusText), { status: r.status, body });
        return body;
      },
      // POST JSON and parse the reply. Throws with the server's error text on a
      // non-2xx, so callers can surface a real reason (e.g. an approval denial).
      async post(path, payload) {
        const r = await fetch(path, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload || {}),
        });
        const t = await r.text();
        let body; try { body = JSON.parse(t); } catch { body = t; }
        if (!r.ok) throw Object.assign(new Error((body && body.error) || t || r.statusText), { status: r.status, body });
        return body;
      },
      sse(path, handlers) {
        const es = new EventSource(path);
        for (const [ev, fn] of Object.entries(handlers)) {
          if (ev === "error") es.onerror = fn;
          else es.addEventListener(ev, (e) => fn(safeJSON(e.data), e));
        }
        return track(() => es.close());
      },
      ws(path) {
        const proto = location.protocol === "https:" ? "wss" : "ws";
        const sock = new WebSocket(`${proto}://${location.host}${path}`);
        track(() => { try { sock.close(); } catch (_) {} });
        return sock;
      },
      // Run a steps.json action and stream its output into a .console element.
      async runAction(actionId, consoleEl, onDone) {
        consoleEl.innerHTML = "";
        const line = (t, cls) => { consoleEl.appendChild(h("span", cls ? { class: cls } : {}, t + "\n")); consoleEl.scrollTop = consoleEl.scrollHeight; };
        let res;
        try {
          res = await fetch("/api/runs", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: actionId }) });
        } catch { line("broker unreachable", "r"); return; }
        if (!res.ok) { line("rejected: " + (await res.text()).trim(), "r"); return; }
        const { id } = await res.json();
        const es = new EventSource(`/api/runs/${id}/events`);
        track(() => es.close());
        es.addEventListener("line", (e) => line(safeJSON(e.data)));
        es.addEventListener("exit", (e) => {
          const code = safeJSON(e.data);
          line(code === 0 ? "✓ exit 0" : "✗ exit " + code, code === 0 ? "g" : "r");
          es.close();
          if (onDone) onDone(code);
        });
        es.onerror = () => { line("stream lost", "r"); es.close(); };
      },
      onClose: track,
    };
  }

  function safeJSON(s) { try { return JSON.parse(s); } catch { return s; } }

  // -- window lifecycle ------------------------------------------------------
  function register(def) { REGISTRY.push(def); }

  function focusWin(id) {
    for (const [wid, e] of OPEN) e.el.classList.toggle("active", wid === id);
    const entry = OPEN.get(id);
    if (entry) { entry.el.style.zIndex = ++zTop; }
    for (const b of document.querySelectorAll(".task")) b.classList.toggle("active", b.dataset.win === id);
  }

  function open(id) {
    if (OPEN.has(id)) {
      const e = OPEN.get(id);
      e.el.classList.remove("min");
      focusWin(id);
      return e;
    }
    const def = REGISTRY.find((d) => d.id === id);
    if (!def) return;
    const desktop = document.getElementById("desktop");
    const w = def.width || 560, ht = def.height || 400;
    const maxX = Math.max(20, desktop.clientWidth - w - 20);
    const maxY = Math.max(20, desktop.clientHeight - ht - 20);
    const x = Math.min(def.x != null ? def.x : 120 + cascade * 26, maxX);
    const y = Math.min(def.y != null ? def.y : 40 + cascade * 26, maxY);
    cascade = (cascade + 1) % 8;

    const body = h("div", { class: "win-body" });
    const minBtn = h("button", { class: "tbtn", title: "Minimize" }, "_");
    const closeBtn = h("button", { class: "tbtn", title: "Close" }, "✕");
    const titlebar = h("div", { class: "titlebar" },
      h("span", { class: "t-ico" }, def.icon || "▣"),
      h("span", { class: "t-name" }, def.title),
      h("div", { class: "tbtns" }, minBtn, closeBtn));
    const resize = h("div", { class: "resize" });
    const el = h("div", { class: "win", style: { left: x + "px", top: y + "px", width: w + "px", height: ht + "px" } }, titlebar, body, resize);
    desktop.appendChild(el);

    const entry = { def, el, body, cleanups: [] };
    OPEN.set(id, entry);

    el.addEventListener("mousedown", () => focusWin(id), true);
    minBtn.addEventListener("click", (e) => { e.stopPropagation(); el.classList.toggle("min"); });
    titlebar.addEventListener("dblclick", () => el.classList.toggle("min"));
    closeBtn.addEventListener("click", (e) => { e.stopPropagation(); close(id); });
    dragify(el, titlebar, desktop);
    resizify(el, resize, desktop);
    addTask(def);

    try { def.open(body, makeApi(entry)); }
    catch (err) { body.appendChild(h("div", { class: "notice err" }, "window error: " + err.message)); }

    focusWin(id);
    return entry;
  }

  function close(id) {
    const e = OPEN.get(id);
    if (!e) return;
    for (const c of e.cleanups) { try { c(); } catch (_) {} }
    e.el.remove();
    OPEN.delete(id);
    const t = document.querySelector(`.task[data-win="${id}"]`);
    if (t) t.remove();
  }

  function dragify(el, handle, bounds) {
    let sx, sy, ox, oy, dragging = false;
    handle.addEventListener("mousedown", (e) => {
      if (e.target.closest(".tbtn")) return;
      dragging = true; sx = e.clientX; sy = e.clientY; ox = el.offsetLeft; oy = el.offsetTop;
      e.preventDefault();
    });
    window.addEventListener("mousemove", (e) => {
      if (!dragging) return;
      const nx = Math.max(0, Math.min(ox + e.clientX - sx, bounds.clientWidth - 40));
      const ny = Math.max(0, Math.min(oy + e.clientY - sy, bounds.clientHeight - 24));
      el.style.left = nx + "px"; el.style.top = ny + "px";
    });
    window.addEventListener("mouseup", () => { dragging = false; });
  }

  function resizify(el, handle, bounds) {
    let sx, sy, ow, oh, sizing = false;
    handle.addEventListener("mousedown", (e) => {
      sizing = true; sx = e.clientX; sy = e.clientY; ow = el.offsetWidth; oh = el.offsetHeight;
      e.preventDefault(); e.stopPropagation();
    });
    window.addEventListener("mousemove", (e) => {
      if (!sizing) return;
      el.style.width = Math.max(260, ow + e.clientX - sx) + "px";
      el.style.height = Math.max(120, oh + e.clientY - sy) + "px";
    });
    window.addEventListener("mouseup", () => { sizing = false; });
  }

  // -- taskbar + start menu + desktop icons ---------------------------------
  function addTask(def) {
    const tasks = document.getElementById("tasks");
    const btn = h("button", { class: "task", "data-win": def.id, title: def.title },
      h("span", {}, def.icon || "▣"), h("span", { class: "t-name" }, def.title));
    btn.addEventListener("click", () => {
      const e = OPEN.get(def.id);
      if (e && e.el.classList.contains("active") && !e.el.classList.contains("min")) e.el.classList.add("min");
      else open(def.id);
    });
    tasks.appendChild(btn);
  }

  function buildChrome() {
    const icons = document.getElementById("icons");
    const menuItems = document.getElementById("startitems");
    for (const def of REGISTRY) {
      if (def.desktop !== false) {
        const ic = h("button", { class: "desk-icon", title: def.title },
          h("span", { class: "glyph" }, def.icon || "▣"),
          h("span", { class: "cap" }, def.short || def.title));
        ic.addEventListener("dblclick", () => open(def.id));
        ic.addEventListener("keydown", (e) => { if (e.key === "Enter") open(def.id); });
        icons.appendChild(ic);
        DESK_ICONS.set(def.id, ic);
      }
      const mi = h("button", { class: "mi" }, h("span", { class: "g" }, def.icon || "▣"), def.title);
      mi.addEventListener("click", () => { open(def.id); toggleStart(false); });
      menuItems.appendChild(mi);
    }
  }

  // -- notifications + icon badges ------------------------------------------
  function setBadge(el, n) {
    if (!el) return;
    let b = el.querySelector(".badge");
    if (n <= 0) { if (b) b.remove(); return; }
    if (!b) { b = h("span", { class: "badge" }); el.appendChild(b); }
    b.textContent = n > 99 ? "99+" : String(n);
  }

  // Badge a window's desktop icon and taskbar button with a count.
  function badge(id, count) {
    const n = Number(count) || 0;
    setBadge(DESK_ICONS.get(id), n);
    setBadge(document.querySelector(`.task[data-win="${id}"]`), n);
  }

  // Show a Windows-95 toast (bottom-right). Returns { dismiss }.
  function notify(opts = {}) {
    let host = document.getElementById("toasts");
    if (!host) { host = h("div", { id: "toasts" }); document.body.appendChild(host); }
    const key = opts.key || ("t" + zTop++);
    if (TOASTS.has(key)) return { dismiss: () => {} };

    const closeBtn = h("button", { class: "tbtn", title: "Dismiss" }, "✕");
    const actionBtn = opts.actionLabel ? h("button", { class: "btn" }, opts.actionLabel) : null;
    const toast = h("div", { class: "toast" },
      h("div", { class: "toast-title" },
        h("span", { class: "t-ico" }, opts.icon || "🔔"),
        h("span", { class: "t-name", style: { flex: "1 1 auto" } }, opts.title || "Notification"),
        h("div", { class: "tbtns" }, closeBtn)),
      h("div", { class: "toast-body" }, opts.message || ""),
      actionBtn ? h("div", { class: "toast-actions" }, actionBtn) : null);

    const dismiss = () => { toast.remove(); TOASTS.delete(key); };
    closeBtn.addEventListener("click", dismiss);
    if (actionBtn) actionBtn.addEventListener("click", () => { try { opts.onAction && opts.onAction(); } finally { dismiss(); } });
    host.appendChild(toast);
    TOASTS.set(key, toast);
    requestAnimationFrame(() => toast.classList.add("show"));
    if (opts.timeout) setTimeout(dismiss, opts.timeout);
    return { dismiss };
  }

  function toggleStart(force) {
    const menu = document.getElementById("startmenu");
    const btn = document.getElementById("startbtn");
    const on = force != null ? force : !menu.classList.contains("on");
    menu.classList.toggle("on", on);
    btn.classList.toggle("on", on);
  }

  function clock() {
    const d = new Date();
    let h12 = d.getHours() % 12; if (h12 === 0) h12 = 12;
    const mm = String(d.getMinutes()).padStart(2, "0");
    const ap = d.getHours() >= 12 ? "PM" : "AM";
    const el = document.getElementById("clock");
    if (el) el.textContent = `${h12}:${mm} ${ap}`;
  }

  function boot(opts = {}) {
    buildChrome();
    const btn = document.getElementById("startbtn");
    btn.addEventListener("click", (e) => { e.stopPropagation(); toggleStart(); });
    document.addEventListener("click", (e) => {
      const menu = document.getElementById("startmenu");
      if (!menu.contains(e.target) && e.target !== btn && !btn.contains(e.target)) toggleStart(false);
    });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") toggleStart(false); });
    document.getElementById("themebtn").addEventListener("click", () => {
      const cur = document.documentElement.getAttribute("data-theme");
      const prefersDark = matchMedia("(prefers-color-scheme: dark)").matches;
      document.documentElement.setAttribute("data-theme", cur ? (cur === "dark" ? "light" : "dark") : (prefersDark ? "light" : "dark"));
    });
    clock(); setInterval(clock, 15000);
    for (const id of (opts.openOnBoot || [])) open(id);
  }

  return { register, open, close, boot, h, notify, badge };
})();
window.Estate95 = Estate95;
