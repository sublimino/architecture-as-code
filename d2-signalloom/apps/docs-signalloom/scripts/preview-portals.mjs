// Offline build harness. Redirects come from the runtime nginx configuration.
import { readFileSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const app = fileURLToPath(new URL("../", import.meta.url));
const nginx = readFileSync(resolve(app, "nginx.conf"), "utf8");
const csp = nginx.match(/add_header Content-Security-Policy "([^"]+)"/)?.[1];
const redirects = new Map([...nginx.matchAll(/location = (\S+)\s*\{\s*return (301|308) (\S+);\s*\}/g)]
  .map(([, path, status, location]) => [path, { status: Number(status), location }]));
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".json": "application/json" };
createServer((req, res) => {
  if (csp) res.setHeader("Content-Security-Policy", csp);
  let path;
  try {
    path = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
  } catch { res.writeHead(400); res.end(); return; }
  const redirect = redirects.get(path);
  if (redirect) { res.writeHead(redirect.status, { Location: redirect.location }); res.end(); return; }
  const base = path.startsWith("/dev-docs/") ? "/dev-docs" : path.startsWith("/docs/") ? "/docs" : null;
  if (!base) { res.writeHead(404); res.end(); return; }
  const root = resolve(app, base === "/docs" ? "dist" : "dist-dev-docs");
  let file = resolve(root, "." + path.slice(base.length));
  if (file !== root && !file.startsWith(root + sep)) { res.writeHead(403); res.end(); return; }
  try {
    if (statSync(file).isDirectory()) file = resolve(file, "index.html");
    const body = readFileSync(file);
    const ext = file.slice(file.lastIndexOf("."));
    res.writeHead(200, { "Content-Type": types[ext] ?? "application/octet-stream" });
    res.end(req.method === "HEAD" ? undefined : body);
  } catch { res.writeHead(404); res.end(); }
}).listen(Number(process.env.DOCS_PREVIEW_PORT ?? 4325), "127.0.0.1");
