// Vulnerability data for sl-upgrade-scan: OSV for packages and the Go
// standard library, grype or trivy for images. The question answered per
// item is "which CVEs does the recommended upgrade fix?".

import type { Fetcher } from "./fetcher.ts";
import type { Item } from "./inventory.ts";
import { compareVersions } from "./version.ts";

export type Severity = "CRITICAL" | "HIGH" | "MEDIUM" | "LOW" | "UNKNOWN";

export interface Vuln {
  id: string;
  aliases: string[];
  severity: Severity;
  fixedIn: string | null;
  url: string;
}

export interface RiskResult {
  source: "osv" | "grype" | "trivy";
  /** null when the scan could not run. */
  currentCount: number | null;
  fixedByUpgrade: Vuln[];
  notFixed: Vuln[];
  error?: string;
}

// --- CVSS v3 base score -------------------------------------------------------

const W: Record<string, Record<string, number>> = {
  AV: { N: 0.85, A: 0.62, L: 0.55, P: 0.2 },
  AC: { L: 0.77, H: 0.44 },
  UI: { N: 0.85, R: 0.62 },
  CIA: { H: 0.56, L: 0.22, N: 0 },
};

function roundUp(x: number): number {
  const i = Math.round(x * 100000);
  return i % 10000 === 0 ? i / 100000 : (Math.floor(i / 10000) + 1) / 10;
}

export function qualitative(score: number): Severity {
  if (score >= 9) return "CRITICAL";
  if (score >= 7) return "HIGH";
  if (score >= 4) return "MEDIUM";
  return "LOW";
}

export function cvss3(vector: string): { score: number; severity: Severity } | null {
  if (!/^CVSS:3\.[01]\//.test(vector)) return null;
  const m: Record<string, string> = {};
  for (const part of vector.split("/").slice(1)) {
    const [k, v] = part.split(":");
    m[k] = v;
  }
  const changed = m.S === "C";
  const pr = { N: 0.85, L: changed ? 0.68 : 0.62, H: changed ? 0.5 : 0.27 }[m.PR as "N" | "L" | "H"];
  const vals = [W.AV[m.AV], W.AC[m.AC], pr, W.UI[m.UI], W.CIA[m.C], W.CIA[m.I], W.CIA[m.A]];
  if (vals.some((v) => v === undefined)) return null;
  const [av, ac, , ui, c, i, a] = vals as number[];
  const iss = 1 - (1 - c) * (1 - i) * (1 - a);
  const impact = changed ? 7.52 * (iss - 0.029) - 3.25 * (iss - 0.02) ** 15 : 6.42 * iss;
  const exploit = 8.22 * av * ac * (pr as number) * ui;
  const score = impact <= 0 ? 0 : roundUp(Math.min((changed ? 1.08 : 1) * (impact + exploit), 10));
  return { score, severity: score === 0 ? "LOW" : qualitative(score) };
}

// --- OSV ----------------------------------------------------------------------

interface OsvVuln {
  id: string;
  aliases?: string[];
  database_specific?: { severity?: string };
  severity?: { type: string; score: string }[];
  affected?: { package?: { name: string; ecosystem: string }; ranges?: { events: Record<string, string>[] }[] }[];
}

export function osvPackage(it: Item): { name: string; ecosystem: string; version: string } | null {
  switch (it.ecosystem) {
    case "go-module":
      return { name: it.name, ecosystem: "Go", version: it.current };
    case "pypi":
      return { name: it.name, ecosystem: "PyPI", version: it.current };
    case "npm":
      return { name: it.name, ecosystem: "npm", version: it.current };
    case "runtime":
    case "tool-pin":
      return it.name === "go" ? { name: "stdlib", ecosystem: "Go", version: it.current.replace(/^v/, "") } : null;
    default:
      return null;
  }
}

function severityOf(v: OsvVuln): Severity {
  const q = v.database_specific?.severity?.toUpperCase();
  if (q === "MODERATE") return "MEDIUM";
  if (q === "CRITICAL" || q === "HIGH" || q === "MEDIUM" || q === "LOW") return q;
  for (const s of v.severity ?? []) {
    const c = s.type === "CVSS_V3" ? cvss3(s.score) : null;
    if (c) return c.severity;
  }
  return "UNKNOWN";
}

function firstFixAbove(v: OsvVuln, pkg: { name: string; ecosystem: string }, current: string): string | null {
  let best: string | null = null;
  for (const a of v.affected ?? []) {
    if (a.package?.name !== pkg.name || a.package?.ecosystem !== pkg.ecosystem) continue;
    for (const r of a.ranges ?? []) {
      for (const e of r.events) {
        const fx = e.fixed;
        if (!fx || !(compareVersions(current, fx) < 0)) continue;
        if (best === null || compareVersions(fx, best) < 0) best = fx;
      }
    }
  }
  return best;
}

const SEV_ORDER: Record<Severity, number> = { CRITICAL: 5, HIGH: 4, MEDIUM: 3, UNKNOWN: 2, LOW: 1 };
export function severityRank(s: Severity): number {
  return SEV_ORDER[s];
}
const bySeverity = (a: Vuln, b: Vuln) => SEV_ORDER[b.severity] - SEV_ORDER[a.severity] || a.id.localeCompare(b.id);

export async function osvRisk(
  entries: { item: Item; recommended: string | null }[],
  f: Fetcher,
): Promise<Map<Item, RiskResult>> {
  const out = new Map<Item, RiskResult>();
  const q = entries.map((e) => ({ e, pkg: osvPackage(e.item) })).filter((x) => x.pkg) as {
    e: { item: Item; recommended: string | null };
    pkg: { name: string; ecosystem: string; version: string };
  }[];
  for (let i = 0; i < q.length; i += 500) {
    const chunk = q.slice(i, i + 500);
    const body = JSON.stringify({ queries: chunk.map(({ pkg }) => ({ package: { name: pkg.name, ecosystem: pkg.ecosystem }, version: pkg.version })) });
    const r = await f.get("https://api.osv.dev/v1/querybatch", { method: "POST", body, headers: { "content-type": "application/json" } });
    let results: { vulns?: { id: string }[] }[] = [];
    try {
      results = r.status === 200 ? JSON.parse(r.body).results ?? [] : [];
    } catch {
      results = [];
    }
    if (r.status !== 200) {
      for (const { e } of chunk) out.set(e.item, { source: "osv", currentCount: null, fixedByUpgrade: [], notFixed: [], error: `OSV querybatch: HTTP ${r.status}` });
      continue;
    }
    await Promise.all(
      chunk.map(async ({ e, pkg }, j) => {
        const ids = (results[j]?.vulns ?? []).map((v) => v.id);
        const fixed: Vuln[] = [];
        const open: Vuln[] = [];
        for (const id of ids) {
          const vr = await f.get(`https://api.osv.dev/v1/vulns/${encodeURIComponent(id)}`);
          let v: OsvVuln = { id };
          try {
            if (vr.status === 200) v = JSON.parse(vr.body);
          } catch {
            // keep the bare id
          }
          const fixedIn = firstFixAbove(v, pkg, pkg.version);
          const vuln: Vuln = { id, aliases: v.aliases ?? [], severity: severityOf(v), fixedIn, url: `https://osv.dev/vulnerability/${id}` };
          if (fixedIn && e.recommended && compareVersions(fixedIn, e.recommended.replace(/^v/, "")) <= 0) fixed.push(vuln);
          else open.push(vuln);
        }
        out.set(e.item, { source: "osv", currentCount: ids.length, fixedByUpgrade: fixed.sort(bySeverity), notFixed: open.sort(bySeverity) });
      }),
    );
  }
  return out;
}

// --- image scanners ----------------------------------------------------------

export type Runner = (cmd: string, args: string[], timeoutMs: number) => Promise<{ code: number; stdout: string; stderr: string }>;

export const execRunner: Runner = async (cmd, args, timeoutMs) => {
  const p = Bun.spawn([cmd, ...args], { stdout: "pipe", stderr: "pipe", stdin: "ignore" });
  const timer = setTimeout(() => p.kill(), timeoutMs);
  const [stdout, stderr, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  clearTimeout(timer);
  return { code, stdout, stderr };
};

function normSev(s: string | undefined): Severity {
  const u = (s ?? "").toUpperCase();
  if (u === "CRITICAL" || u === "HIGH" || u === "MEDIUM" || u === "LOW") return u;
  if (u === "NEGLIGIBLE") return "LOW";
  return "UNKNOWN";
}

async function scanImage(
  ref: string,
  scanner: "grype" | "trivy",
  run: Runner,
  bin: string,
): Promise<{ vulns: Map<string, Severity> } | { error: string }> {
  const args = scanner === "grype" ? [`registry:${ref}`, "-o", "json", "-q"] : ["image", "-q", "-f", "json", ref];
  const r = await run(bin, args, 600_000);
  if (r.code !== 0) return { error: `${scanner} ${ref}: exit ${r.code}: ${r.stderr.trim().slice(0, 200)}` };
  const vulns = new Map<string, Severity>();
  try {
    const j = JSON.parse(r.stdout);
    if (scanner === "grype") {
      for (const m of j.matches ?? []) vulns.set(m.vulnerability.id, normSev(m.vulnerability.severity));
    } else {
      for (const res of j.Results ?? []) for (const v of res.Vulnerabilities ?? []) vulns.set(v.VulnerabilityID, normSev(v.Severity));
    }
  } catch {
    return { error: `${scanner} ${ref}: unparsable JSON` };
  }
  return { vulns };
}

export async function imageRisk(
  it: Item,
  recommended: string,
  scanner: "grype" | "trivy",
  run: Runner = execRunner,
  bin: string = scanner,
): Promise<RiskResult> {
  const cur = await scanImage(`${it.name}:${it.current}`, scanner, run, bin);
  if ("error" in cur) return { source: scanner, currentCount: null, fixedByUpgrade: [], notFixed: [], error: cur.error };
  const next = await scanImage(`${it.name}:${recommended}`, scanner, run, bin);
  if ("error" in next) return { source: scanner, currentCount: cur.vulns.size, fixedByUpgrade: [], notFixed: [], error: next.error };
  const fixed: Vuln[] = [];
  const open: Vuln[] = [];
  for (const [id, severity] of cur.vulns) {
    const v: Vuln = { id, aliases: [], severity, fixedIn: next.vulns.has(id) ? null : recommended, url: `https://osv.dev/vulnerability/${id}` };
    (next.vulns.has(id) ? open : fixed).push(v);
  }
  return { source: scanner, currentCount: cur.vulns.size, fixedByUpgrade: fixed.sort(bySeverity), notFixed: open.sort(bySeverity) };
}
