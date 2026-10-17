// sl-upgrade-scan CLI. See ../SKILL.md. Run through ./upgrade-scan.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { Fetcher, fetchHttp, type Http } from "./fetcher.ts";
import { type Ecosystem, type Item, inventory } from "./inventory.ts";
import { execRunner, imageRisk, osvPackage, osvRisk, type RiskResult, type Runner, severityRank } from "./risk.ts";
import { type Finding, maxFixedSeverity, rank, renderMarkdown, toJson } from "./report.ts";
import { eolFor, resolveLatest } from "./sources.ts";
import { distance } from "./version.ts";

const USAGE = `upgrade-scan: ranked upgrade report for this repository

Usage:
  upgrade-scan [scan] [options]     inventory + latest versions + CVEs + EOL (network)
  upgrade-scan inventory [options]  inventory only (no network)

Options:
  --root DIR               repository to scan (default: git top level of the cwd)
  --md FILE|-              write the markdown report (default: - when no --json)
  --json FILE|-            write the JSON report
  --top N                  rows in the markdown top table (default 25)
  --ecosystem LIST         comma list: oci-image,oci-artifact,go-module,runtime,pypi,npm,github-action,tool-pin
  --only REGEX             only items whose name matches
  --include-indirect       include // indirect Go requirements
  --include-prereleases    consider pre-releases as latest
  --no-vulns               skip the OSV lookup
  --image-scanner NAME     grype | trivy | none (default none; scans pull images)
  --image-scan-limit N     scan at most N images, most-behind first (default 10)
  --cache-dir DIR          HTTP cache (default \${XDG_CACHE_HOME:-~/.cache}/sl-upgrade-scan)
  --no-cache               do not read or write the disk cache
  --ttl HOURS              cache lifetime (default 6)
  --concurrency N          parallel lookups (default 8)
  --fail-on SEVERITY       exit 1 if an upgrade fixes a CVE at or above critical|high|medium|low
  --sbom-out DIR           also write SPDX + CycloneDX SBOMs with syft (if installed)
  -h, --help

Environment (for tests and CI):
  UPGRADE_SCAN_HTTP_FIXTURES  JSON file of canned responses keyed by URL ("POST <url>" for POST)
  UPGRADE_SCAN_NOW            fixed ISO time for fetched_at
  GITHUB_TOKEN / GH_TOKEN     GitHub token; else \`gh auth token\` unless UPGRADE_SCAN_NO_GH_CLI=1
  GRYPE, TRIVY, SYFT          scanner binaries

Exit: 0 report written, 1 --fail-on threshold met, 2 usage, 3 environment error.`;

interface Opts {
  cmd: "scan" | "inventory";
  root: string | null;
  md: string | null;
  json: string | null;
  top: number;
  ecosystems: Set<string> | null;
  only: RegExp | null;
  includeIndirect: boolean;
  includePre: boolean;
  vulns: boolean;
  imageScanner: "grype" | "trivy" | "none";
  imageScanLimit: number;
  cacheDir: string | null;
  ttlHours: number;
  concurrency: number;
  failOn: string | null;
  sbomOut: string | null;
}

class UsageError extends Error {}

function parseArgs(argv: string[]): Opts {
  const o: Opts = {
    cmd: "scan",
    root: null,
    md: null,
    json: null,
    top: 25,
    ecosystems: null,
    only: null,
    includeIndirect: false,
    includePre: false,
    vulns: true,
    imageScanner: "none",
    imageScanLimit: 10,
    cacheDir: join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "sl-upgrade-scan"),
    ttlHours: 6,
    concurrency: 8,
    failOn: null,
    sbomOut: null,
  };
  const args = [...argv];
  if (args[0] === "scan" || args[0] === "inventory") o.cmd = args.shift() as Opts["cmd"];
  const val = (flag: string) => {
    const v = args.shift();
    if (v === undefined || (v.startsWith("--") && v !== "-")) throw new UsageError(`${flag} needs a value`);
    return v;
  };
  const int = (flag: string) => {
    const n = Number.parseInt(val(flag), 10);
    if (!Number.isFinite(n) || n < 0) throw new UsageError(`${flag} needs a non-negative integer`);
    return n;
  };
  while (args.length) {
    const a = args.shift() as string;
    switch (a) {
      case "--root": o.root = val(a); break;
      case "--md": o.md = val(a); break;
      case "--json": o.json = val(a); break;
      case "--top": o.top = int(a); break;
      case "--ecosystem": o.ecosystems = new Set(val(a).split(",").map((s) => s.trim())); break;
      case "--only": o.only = new RegExp(val(a)); break;
      case "--include-indirect": o.includeIndirect = true; break;
      case "--include-prereleases": o.includePre = true; break;
      case "--no-vulns": o.vulns = false; break;
      case "--image-scanner": {
        const s = val(a);
        if (s !== "grype" && s !== "trivy" && s !== "none") throw new UsageError("--image-scanner is grype, trivy or none");
        o.imageScanner = s;
        break;
      }
      case "--image-scan-limit": o.imageScanLimit = int(a); break;
      case "--cache-dir": o.cacheDir = val(a); break;
      case "--no-cache": o.cacheDir = null; break;
      case "--ttl": o.ttlHours = int(a); break;
      case "--concurrency": o.concurrency = Math.max(1, int(a)); break;
      case "--fail-on": {
        const s = val(a).toUpperCase();
        if (!["CRITICAL", "HIGH", "MEDIUM", "LOW"].includes(s)) throw new UsageError("--fail-on is critical, high, medium or low");
        o.failOn = s;
        break;
      }
      case "--sbom-out": o.sbomOut = val(a); break;
      case "-h":
      case "--help":
        console.log(USAGE);
        process.exit(0);
        break;
      default:
        throw new UsageError(`unknown option: ${a}`);
    }
  }
  if (!o.md && !o.json) o.md = "-";
  return o;
}

function fixtureHttp(file: string): Http {
  const routes = JSON.parse(readFileSync(file, "utf8")) as Record<string, { status?: number; json?: unknown; body?: string; headers?: Record<string, string> }>;
  return async (req) => {
    const key = req.method && req.method !== "GET" ? `${req.method} ${req.url}` : req.url;
    const r = routes[key];
    if (!r) return { status: 404, headers: {}, body: `no fixture for ${key}` };
    return { status: r.status ?? 200, headers: r.headers ?? {}, body: r.body ?? JSON.stringify(r.json) };
  };
}

function githubToken(fixtures: boolean): string | null {
  const env = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  if (env) return env;
  if (fixtures || process.env.UPGRADE_SCAN_NO_GH_CLI === "1") return null;
  try {
    return execFileSync("gh", ["auth", "token"], { stdio: ["ignore", "pipe", "ignore"], timeout: 5000 }).toString().trim() || null;
  } catch {
    return null;
  }
}

async function pool<T, R>(xs: T[], n: number, fn: (x: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(xs.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(n, xs.length) }, async () => {
      while (next < xs.length) {
        const i = next++;
        out[i] = await fn(xs[i]);
      }
    }),
  );
  return out;
}

function emit(target: string, text: string) {
  if (target === "-") process.stdout.write(text);
  else writeFileSync(target, text);
}

async function sbom(root: string, dir: string, run: Runner): Promise<Record<string, unknown>> {
  const bin = process.env.SYFT || Bun.which("syft");
  if (!bin) {
    return { status: "unavailable", reason: "syft is not installed; no SBOM written. Install anchore/syft to produce SPDX and CycloneDX for kusari-ingest or GUAC." };
  }
  mkdirSync(dir, { recursive: true });
  const spdx = join(dir, "sbom.spdx.json");
  const cdx = join(dir, "sbom.cdx.json");
  const r = await run(bin, ["scan", `dir:${root}`, "-q", "-o", `spdx-json=${spdx}`, "-o", `cyclonedx-json=${cdx}`], 900_000);
  if (r.code !== 0) return { status: "error", reason: `syft exit ${r.code}: ${r.stderr.trim().slice(0, 200)}` };
  return { status: "written", files: [spdx, cdx], tool: bin };
}

export async function main(argv: string[]): Promise<number> {
  let o: Opts;
  try {
    o = parseArgs(argv);
  } catch (e) {
    if (e instanceof UsageError) {
      console.error(`upgrade-scan: ${e.message}\n\n${USAGE}`);
      return 2;
    }
    throw e;
  }
  let root = o.root;
  if (!root) {
    try {
      root = execFileSync("git", ["rev-parse", "--show-toplevel"], { stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
    } catch {
      root = process.cwd();
    }
  }
  root = resolve(root);
  if (!existsSync(root)) {
    console.error(`upgrade-scan: no such directory: ${root}`);
    return 3;
  }
  const nowFixed = process.env.UPGRADE_SCAN_NOW;
  const now = () => (nowFixed ? new Date(nowFixed) : new Date());

  let items: Item[] = inventory(root, { includeIndirect: o.includeIndirect });
  if (o.ecosystems) items = items.filter((i) => o.ecosystems?.has(i.ecosystem as Ecosystem));
  if (o.only) items = items.filter((i) => o.only?.test(i.name));

  if (o.cmd === "inventory") {
    const rows = items.map((i) => ({ ecosystem: i.ecosystem, name: i.name, current: i.current, locations: i.locations, notes: i.notes, first_party: !!i.firstParty }));
    if (o.json) emit(o.json, `${JSON.stringify({ generated_at: now().toISOString(), root, items: rows }, null, 2)}\n`);
    if (o.md) {
      const lines = ["| Ecosystem | Name | Current | Where |", "|---|---|---|---|"];
      for (const i of items) lines.push(`| ${i.ecosystem} | ${i.name} | ${i.current} | ${i.locations.map((l) => `${l.file}:${l.line}`).join(", ")} |`);
      emit(o.md, `${lines.join("\n")}\n`);
    }
    return 0;
  }

  const fixtures = process.env.UPGRADE_SCAN_HTTP_FIXTURES;
  const f = new Fetcher({
    http: fixtures ? fixtureHttp(fixtures) : fetchHttp,
    cacheDir: o.cacheDir,
    ttlMs: o.ttlHours * 3600_000,
    now,
    githubToken: githubToken(!!fixtures),
  });
  const run: Runner = execRunner;
  if (f.cacheWarning) console.error(`upgrade-scan: ${f.cacheWarning}`);
  console.error(`upgrade-scan: ${items.length} items; resolving latest versions...`);
  const resolutions = await pool(items, o.concurrency, (it) => resolveLatest(it, f, { includePrereleases: o.includePre }));
  const eols = await pool(items, o.concurrency, (it) => eolFor(it, f));
  const findings: Finding[] = items.map((item, i) => {
    const res = resolutions[i];
    const d = res.latest ? distance(item.current, res.latest.version) : { level: "unknown" as const, breaking: false };
    const behind = ["major", "minor", "patch", "date"].includes(d.level);
    return { item, resolution: res, recommended: behind && res.latest ? res.latest.version : null, distance: d, eol: eols[i], risk: null };
  });

  if (o.vulns) {
    console.error("upgrade-scan: querying OSV...");
    const eligible = findings.filter((x) => osvPackage(x.item));
    const risk = await osvRisk(eligible.map((x) => ({ item: x.item, recommended: x.recommended })), f);
    for (const x of eligible) x.risk = risk.get(x.item) ?? null;
  }
  if (o.imageScanner !== "none") {
    const bin = (o.imageScanner === "grype" ? process.env.GRYPE : process.env.TRIVY) || Bun.which(o.imageScanner);
    const imgs = rank(findings.filter((x) => x.item.ecosystem === "oci-image" && x.recommended)).slice(0, o.imageScanLimit);
    if (!bin) console.error(`upgrade-scan: ${o.imageScanner} is not installed; image CVEs skipped`);
    else {
      console.error(`upgrade-scan: scanning ${imgs.length} images with ${o.imageScanner}...`);
      await pool(imgs, 2, async (x) => {
        x.risk = (await imageRisk(x.item, x.recommended as string, o.imageScanner as "grype" | "trivy", run, bin)) as RiskResult;
      });
    }
  }

  const ranked = rank(findings);
  const notes: string[] = [];
  if (f.cacheWarning) notes.push(f.cacheWarning);
  if (f.githubLimited) notes.push(`GitHub API rate limit exhausted (resets ${f.githubLimited.resetAt}); affected items are listed as rate-limited, not guessed.`);
  if (o.imageScanner === "none") notes.push("Image CVEs were not scanned (use --image-scanner grype). Package CVEs come from OSV.");
  const sbomInfo = o.sbomOut ? await sbom(root, o.sbomOut, run) : null;
  if (sbomInfo && sbomInfo.status !== "written") notes.push(`SBOM: ${sbomInfo.reason}`);
  const generatedAt = now().toISOString();
  const input = { generatedAt, root, findings: ranked, top: o.top, notes };
  if (o.md) emit(o.md, renderMarkdown(input));
  if (o.json) {
    const extra = { network_calls: f.networkCalls, github_rate_limited: f.githubLimited, sbom: sbomInfo };
    emit(o.json, `${JSON.stringify(toJson({ ...input, extra }), null, 2)}\n`);
  }
  if (sbomInfo) console.error(`upgrade-scan: sbom ${sbomInfo.status}${sbomInfo.reason ? `: ${sbomInfo.reason}` : ""}`);
  console.error(`upgrade-scan: done; ${f.networkCalls} network calls`);
  if (o.failOn) {
    const threshold = severityRank(o.failOn as "CRITICAL");
    if (ranked.some((x) => {
      const s = maxFixedSeverity(x);
      return s !== null && s !== "UNKNOWN" && severityRank(s) >= threshold;
    })) return 1;
  }
  return 0;
}

if (import.meta.main) {
  main(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (e) => {
      console.error(`upgrade-scan: ${e?.stack ?? e}`);
      process.exit(3);
    },
  );
}
