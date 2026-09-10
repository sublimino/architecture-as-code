#!/usr/bin/env node
// link-audit.mjs — resolve every internal link in the built docs site to a real
// file on disk.
//
// Why existence and not shape. A regex that only checks a href *looks* like a
// docs URL passes for a page that was never built: it validates the string, not
// the world. This auditor therefore never asserts on the URL text. It maps each
// internal href back to the file Astro would have had to emit, and stats it.
//
// Why a self-test. An auditor that silently finds nothing is indistinguishable
// from a site with no broken links. `--self-test` injects a link that cannot
// resolve and requires the auditor to fail on it; a green run without that
// proof is not evidence.
//
// Usage:
//   node scripts/link-audit.mjs [--dist dist] [--base /docs] [--self-test]

import { readdirSync, statSync, readFileSync, existsSync } from "node:fs";
import { join, resolve, posix } from "node:path";

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i === -1 ? fallback : argv[i + 1];
};

const distDir = resolve(flag("dist", "dist"));
const base = (flag("base", "/docs") || "/").replace(/\/+$/, "");
const selfTest = argv.includes("--self-test");

if (!existsSync(distDir)) {
  console.error(`link-audit: dist directory not found: ${distDir}`);
  console.error("link-audit: run the build before the audit.");
  process.exit(2);
}

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) out.push(...walk(full));
    else if (entry.endsWith(".html")) out.push(full);
  }
  return out;
}

const htmlFiles = walk(distDir);
if (htmlFiles.length === 0) {
  console.error("link-audit: no HTML files under dist. The build produced nothing to audit.");
  process.exit(2);
}

// Every href/src the browser would follow. Anchors, protocol URLs, mail and
// data URIs are out of scope: they resolve outside the built tree.
const HREF = /(?:href|src)\s*=\s*"([^"]+)"/gi;
const EXTERNAL = /^(?:[a-z][a-z0-9+.-]*:|\/\/|#|mailto:|tel:|data:)/i;

/** Map a site-absolute or relative URL to the file Astro must have emitted. */
function targetsFor(href, fromFile) {
  const [pathPart] = href.split("#");
  if (pathPart === "") return null; // pure fragment
  let urlPath;
  if (pathPart.startsWith("/")) {
    urlPath = pathPart;
    if (base && urlPath.startsWith(base + "/")) urlPath = urlPath.slice(base.length);
    else if (base && urlPath === base) urlPath = "/";
    else if (base) return { unbased: true, urlPath: pathPart };
  } else {
    const fromDir = posix.dirname(fromFile.slice(distDir.length).split("\\").join("/"));
    urlPath = posix.resolve(fromDir, pathPart);
  }
  const rel = urlPath.replace(/^\/+/, "");
  return {
    urlPath,
    candidates: [
      join(distDir, rel),
      join(distDir, rel, "index.html"),
      join(distDir, `${rel.replace(/\/+$/, "")}.html`),
    ],
  };
}

function audit(extraLinks = []) {
  const broken = [];
  let checked = 0;
  const scan = (file, html) => {
    for (const m of html.matchAll(HREF)) {
      const href = m[1];
      if (EXTERNAL.test(href)) continue;
      const t = targetsFor(href, file);
      if (t === null) continue;
      checked += 1;
      if (t.unbased) {
        broken.push({ file, href, reason: `site-absolute link outside base "${base}"` });
        continue;
      }
      if (!t.candidates.some((c) => existsSync(c) && statSync(c).isFile())) {
        broken.push({ file, href, reason: "no file on disk for this target" });
      }
    }
  };
  for (const file of htmlFiles) scan(file, readFileSync(file, "utf8"));
  for (const [file, html] of extraLinks) scan(file, html);
  return { broken, checked, pages: htmlFiles.length };
}

if (selfTest) {
  const canary = `<a href="${base}/__link-audit-canary-that-cannot-exist__/">x</a>`;
  const probe = audit([[join(distDir, "index.html"), canary]]);
  const caught = probe.broken.some((b) => b.href.includes("__link-audit-canary-that-cannot-exist__"));
  if (!caught) {
    console.error("link-audit: SELF-TEST FAILED — the auditor did not flag a link that cannot resolve.");
    console.error("link-audit: a pass from this auditor would be vacuous. Fix the auditor before trusting it.");
    process.exit(3);
  }
  console.log("link-audit: self-test passed — a non-resolvable link is detected.");
}

const { broken, checked, pages } = audit();

console.log(`link-audit: base=${base} pages=${pages} internal_links_checked=${checked}`);
if (broken.length > 0) {
  console.error(`link-audit: ${broken.length} unresolved internal link(s):`);
  for (const b of broken) {
    console.error(`  ${b.file.slice(distDir.length) || "/"} -> ${b.href}  (${b.reason})`);
  }
  process.exit(1);
}
console.log("link-audit: 0 unresolved internal links.");
