/* ===========================================================================
   Estate95 window harness.

   Renders one ui/windows/*.js module headlessly against a minimal DOM shim and
   a scripted api.get/api.post, then prints the resulting text so a test can
   assert on what an operator would actually see. Used to prove that a window
   refuses honestly when its backend route is not served, instead of serving a
   fabricated dataset from a bare catch.

   Usage:
     node test/helpers/estate95-window-harness.mjs <module.js> <scenario.json>

   The scenario file is a JSON object:
     { "get": { "<path-prefix>": {"ok": {...}} | {"status": 404, "error": "..."} },
       "getDefault": {"status": 404, "error": "no such route"} }

   Output: the rendered text content, one node per line, on stdout.
   =========================================================================== */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";

const [moduleArg, scenarioArg] = process.argv.slice(2);
if (!moduleArg || !scenarioArg) {
  console.error("usage: estate95-window-harness.mjs <module.js> <scenario.json>");
  process.exit(2);
}
const scenario = JSON.parse(readFileSync(resolve(scenarioArg), "utf8"));

// ---- minimal DOM shim ------------------------------------------------------
class El {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase();
    this.children = [];
    this.attrs = {};
    this.style = {};
    this.className = "";
    this.text = "";
    this.listeners = {};
  }
  appendChild(kid) { this.children.push(kid); return kid; }
  addEventListener(ev, fn) { (this.listeners[ev] ||= []).push(fn); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  set innerHTML(v) { this.children = []; this.text = v ? String(v) : ""; }
  get innerHTML() { return this.text; }
  set textContent(v) { this.children = []; this.text = String(v); }
  get textContent() {
    return [this.text, ...this.children.map((k) => k.textContent)].filter(Boolean).join(" ");
  }
  lines() {
    const own = [this.text, this.className ? "[class=" + this.className + "]" : ""]
      .filter(Boolean).join(" ");
    return [own, ...this.children.flatMap((k) => k.lines())].filter((s) => s.trim());
  }
}
class TextNode {
  constructor(t) { this.text = String(t); }
  get textContent() { return this.text; }
  lines() { return [this.text]; }
}

globalThis.document = {
  createElement: (tag) => new El(tag),
  createTextNode: (t) => new TextNode(t),
};

// ---- scripted api ----------------------------------------------------------
function match(path) {
  const table = scenario.get || {};
  for (const prefix of Object.keys(table)) {
    if (path.startsWith(prefix)) return table[prefix];
  }
  return scenario.getDefault || { status: 404, error: "route not served" };
}

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

const api = {
  h,
  pill: (text, kind = "plain") => h("span", { class: "pill " + kind }, String(text)),
  groupbox: (legend, ...kids) => h("div", { class: "gb" }, h("span", { class: "lg" }, String(legend)), ...kids),
  async get(path) {
    const r = match(path);
    if (Object.prototype.hasOwnProperty.call(r, "ok")) return r.ok;
    throw Object.assign(new Error(r.error || "request failed"), { status: r.status || 500 });
  },
  async post(path) {
    const r = match(path);
    if (Object.prototype.hasOwnProperty.call(r, "ok")) return r.ok;
    throw Object.assign(new Error(r.error || "request failed"), { status: r.status || 500 });
  },
  sse: () => () => {},
  ws: () => ({ close() {} }),
  runAction: async () => {},
};

// ---- load the module -------------------------------------------------------
let def = null;
const src = readFileSync(resolve(moduleArg), "utf8");
const sandbox = {
  Estate95: { register: (d) => { def = d; } },
  document: globalThis.document,
  console,
  fetch: async () => { throw new Error("harness: raw fetch is not available"); },
  location: { protocol: "http:", host: "localhost", href: "http://localhost/" },
  setTimeout, clearTimeout, setInterval, clearInterval,
  Number, Math, JSON, String, Object, Array, Boolean, Date, Error, Promise,
};
vm.createContext(sandbox);
vm.runInContext(src, sandbox, { filename: moduleArg });

if (!def || typeof def.open !== "function") {
  console.error("harness: module did not register a window with an open()");
  process.exit(3);
}

const body = document.createElement("div");
await def.open(body, api);
console.log(body.lines().join("\n"));
