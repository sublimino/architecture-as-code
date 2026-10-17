// Ranking and rendering for sl-upgrade-scan.
//
// Order: highest severity of a CVE the upgrade fixes, then end-of-life, then
// how far behind (major > minor > patch), then how many CVEs it fixes.

import type { Item } from "./inventory.ts";
import { type RiskResult, type Severity, severityRank } from "./risk.ts";
import type { EolInfo, Resolution } from "./sources.ts";
import type { Distance } from "./version.ts";

export interface Finding {
  item: Item;
  resolution: Resolution;
  recommended: string | null;
  distance: Distance;
  eol: EolInfo | null;
  risk: RiskResult | null;
}

const DIST: Record<Distance["level"], number> = { major: 3, minor: 2, patch: 1, date: 1, none: 0, ahead: 0, unknown: 0 };

export function maxFixedSeverity(f: Finding): Severity | null {
  let best: Severity | null = null;
  for (const v of f.risk?.fixedByUpgrade ?? []) if (best === null || severityRank(v.severity) > severityRank(best)) best = v.severity;
  return best;
}

export function rankKey(f: Finding): number[] {
  const sev = maxFixedSeverity(f);
  return [sev ? severityRank(sev) : 0, f.eol?.eol ? 1 : 0, DIST[f.distance.level], f.risk?.fixedByUpgrade.length ?? 0];
}

export function rank(findings: Finding[]): Finding[] {
  return [...findings].sort((a, b) => {
    const ka = rankKey(a);
    const kb = rankKey(b);
    for (let i = 0; i < ka.length; i++) if (ka[i] !== kb[i]) return kb[i] - ka[i];
    return a.item.name.localeCompare(b.item.name) || a.item.current.localeCompare(b.item.current);
  });
}

/** Actionable: a recommended upgrade exists, or the pin is end-of-life. */
export function actionable(f: Finding): boolean {
  return (f.recommended !== null && DIST[f.distance.level] > 0) || f.eol?.eol === true || (f.risk?.fixedByUpgrade.length ?? 0) > 0;
}

function where(it: Item): string {
  const first = it.locations[0];
  const more = it.locations.length > 1 ? ` (+${it.locations.length - 1} more)` : "";
  return first ? `${first.file}:${first.line}${more}` : "";
}

function cell(s: string): string {
  return s.replace(/\|/g, "\\|").replace(/\n/g, " ");
}

function eolCell(e: EolInfo | null): string {
  if (!e || e.eol === null) return "";
  if (e.eol) return `**EOL** ${e.product} ${e.cycle}${e.eolDate ? ` (${e.eolDate})` : ""}`;
  return e.eolDate ? `supported to ${e.eolDate}` : "supported";
}

function cveCell(r: RiskResult | null): string {
  if (!r) return "";
  if (r.error) return `scan error: ${r.error}`;
  const fx = r.fixedByUpgrade;
  if (!fx.length) return r.currentCount ? `0 fixed (${r.currentCount} open)` : "none known";
  const ids = fx.slice(0, 3).map((v) => `${v.aliases.find((a) => a.startsWith("CVE-")) ?? v.id} ${v.severity}`);
  return `${fx.length} fixed: ${ids.join(", ")}${fx.length > 3 ? ", ..." : ""}`;
}

export interface RenderInput {
  generatedAt: string;
  root: string;
  findings: Finding[];
  top: number;
  notes?: string[];
}

export function renderMarkdown(r: RenderInput): string {
  const out: string[] = [];
  const act = r.findings.filter(actionable);
  const by = (s: Resolution["status"]) => r.findings.filter((f) => f.resolution.status === s);
  out.push(`# Upgrade scan: ${r.root}`, "");
  out.push(`Generated ${r.generatedAt}. ${r.findings.length} pinned items, ${act.length} actionable.`);
  out.push(
    `Resolved ${by("ok").length}, unknown upstream ${by("unknown").length}, floating ${by("floating").length}, first-party ${by("first-party").length}, rate-limited ${by("rate-limited").length}.`,
    "",
  );
  for (const n of r.notes ?? []) out.push(`> ${n}`, "");
  out.push(`## Top ${Math.min(r.top, act.length)} upgrades`, "");
  out.push("Each recommended version names the source it was read from and when.", "");
  out.push("| # | Item | Current | Recommended | Behind | EOL | CVEs fixed by upgrade | Change at | Source (fetched) |");
  out.push("|---|------|---------|-------------|--------|-----|-----------------------|-----------|------------------|");
  act.slice(0, r.top).forEach((f, i) => {
    const l = f.resolution.latest;
    const behind = `${f.distance.level}${f.distance.breaking ? " (breaking?)" : ""}`;
    const up = f.resolution.upstreamRelease;
    const upNote = up && l && up.sourceUrl !== l.sourceUrl ? `; release ${up.version} ${up.sourceUrl}${up.publishedAt ? ` published ${up.publishedAt.slice(0, 10)}` : ""}` : "";
    const src = l ? `${l.sourceUrl} (${l.fetchedAt})${upNote}` : "";
    out.push(
      `| ${i + 1} | ${cell(`${f.item.ecosystem} ${f.item.name}`)} | ${cell(f.item.current)} | ${cell(f.recommended ?? "")} | ${behind} | ${cell(eolCell(f.eol))} | ${cell(cveCell(f.risk))} | ${cell(where(f.item))} | ${cell(src)} |`,
    );
  });
  const unknown = r.findings.filter((f) => f.resolution.status === "unknown" || f.resolution.status === "rate-limited");
  if (unknown.length) {
    out.push("", "## Unknown upstream", "", "No latest version is claimed for these. The reason says what failed.", "");
    for (const f of unknown) out.push(`- ${f.item.ecosystem} ${f.item.name} ${f.item.current} at ${where(f.item)}: ${f.resolution.status}: ${f.resolution.reason ?? ""}`);
  }
  const floating = by("floating");
  if (floating.length) {
    out.push("", "## Floating tags", "", "These pins are not versions. They change without a commit, so no upgrade is computed.", "");
    for (const f of floating) out.push(`- ${f.item.name}:${f.item.current} at ${where(f.item)}${f.eol?.eol ? ` (EOL ${f.eol.product} ${f.eol.cycle})` : ""}`);
  }
  const fp = by("first-party");
  if (fp.length) {
    out.push("", "## First-party images", "", "Built from this repository. Rebuild them; there is no upstream tag.", "");
    out.push(fp.map((f) => `\`${f.item.name}:${f.item.current}\``).join(", "));
  }
  return `${out.join("\n")}\n`;
}

export function toJson(r: RenderInput & { extra?: Record<string, unknown> }) {
  return {
    generated_at: r.generatedAt,
    root: r.root,
    ...(r.extra ?? {}),
    findings: r.findings.map((f, i) => ({
      rank: i + 1,
      actionable: actionable(f),
      ecosystem: f.item.ecosystem,
      name: f.item.name,
      current: f.item.current,
      recommended: f.recommended,
      distance: f.distance.level,
      breaking_hint: f.distance.breaking,
      status: f.resolution.status,
      reason: f.resolution.reason ?? null,
      latest: f.resolution.latest,
      upstream_release: f.resolution.upstreamRelease ?? null,
      eol: f.eol,
      vulns: f.risk,
      locations: f.item.locations,
      notes: f.item.notes,
      first_party: !!f.item.firstParty,
    })),
  };
}
