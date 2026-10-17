// Version parsing, comparison and distance for sl-upgrade-scan.
//
// Three schemes: semver-like (dotted numbers, optional v/prefix, optional
// pre-release, optional image variant suffix), date (calendar tags such as
// 2026.10.01 or 20261001) and none (latest, nonroot, hashes). Versions in
// different schemes never compare: the caller reports them as unknown.

export type Scheme = "semver" | "date" | "none";

export interface ParsedVersion {
  raw: string;
  scheme: Scheme;
  nums: number[];
  pre: string | null; // "-rc.1", "-beta2", Go pseudo-version tail
  suffix: string; // image variant: "-alpine", "-slim", "-alpine3.20"
}

const PRE_RE = /^[-.]?(rc|alpha|beta|pre|preview|dev|snapshot|a|b)[.\-]?\d*(?=$|[-+.])/i;
const PSEUDO_RE = /^-(?:\d+\.)?(?:0\.)?\d{14}-[0-9a-f]{12}$/;
// Prefix before the first digit: letters, "/", "-", "_" (kustomize/v, jq-, go, release-).
const SPLIT_RE = /^([A-Za-z_\-\/]*?)(\d+(?:\.\d+)*)(.*)$/;

export function parseVersion(raw: string): ParsedVersion {
  const none: ParsedVersion = { raw, scheme: "none", nums: [], pre: null, suffix: "" };
  const s = raw.trim().replace(/\+.*$/, ""); // build metadata never orders
  const m = SPLIT_RE.exec(s);
  if (!m) return none;
  const [, prefix, numPart, restRaw] = m;
  let rest = restRaw;
  // A prefix ending in a letter other than v glued to the digits ("src-d303e2")
  // is a hash, not a version. "go1.22" and "release-1" are fine.
  if (prefix && !/(^|[\/\-_])v?$|^go$|^V$/i.test(prefix)) return none;
  // Digits followed directly by letters ("303e20f5867") are a hash.
  if (rest && !/^[-+.]/.test(rest) && !PRE_RE.test(rest)) return none;
  let nums = numPart.split(".").map((n) => Number.parseInt(n, 10));
  let pre: string | null = null;
  let suffix = "";
  if (PSEUDO_RE.test(rest)) {
    pre = rest;
    rest = "";
  } else {
    const p = PRE_RE.exec(rest);
    if (p) {
      pre = p[0];
      rest = rest.slice(p[0].length);
    }
    suffix = rest;
  }
  let scheme: Scheme = "semver";
  if (nums.length === 1 && /^\d{8}$/.test(numPart)) {
    const d = numPart;
    nums = [Number(d.slice(0, 4)), Number(d.slice(4, 6)), Number(d.slice(6, 8))];
    scheme = "date";
  } else if (nums[0] >= 2000 && nums[0] <= 2100) {
    scheme = "date";
  }
  return { raw, scheme, nums, pre, suffix };
}

export function isPrerelease(raw: string): boolean {
  return parseVersion(raw).pre !== null;
}

function comparePre(a: string | null, b: string | null): number {
  if (a === b) return 0;
  if (a === null) return 1;
  if (b === null) return -1;
  return a.localeCompare(b, "en", { numeric: true });
}

/** <0, 0, >0, or NaN when the two are not comparable. */
export function compareVersions(a: string, b: string): number {
  const pa = parseVersion(a);
  const pb = parseVersion(b);
  if (pa.scheme === "none" || pb.scheme === "none" || pa.scheme !== pb.scheme) return Number.NaN;
  const n = Math.max(pa.nums.length, pb.nums.length);
  for (let i = 0; i < n; i++) {
    const d = (pa.nums[i] ?? 0) - (pb.nums[i] ?? 0);
    if (d !== 0) return d;
  }
  return comparePre(pa.pre, pb.pre);
}

export type Level = "none" | "patch" | "minor" | "major" | "date" | "ahead" | "unknown";
export interface Distance {
  level: Level;
  breaking: boolean;
}

/**
 * How far `current` is behind `latest`. A tag with fewer components floats
 * (1.27-alpine tracks 1.27.x), so only the components it pins are compared.
 */
export function distance(current: string, latest: string): Distance {
  const c = parseVersion(current);
  const l = parseVersion(latest);
  if (c.scheme === "none" || c.scheme !== l.scheme) return { level: "unknown", breaking: false };
  const width = Math.min(c.nums.length, l.nums.length);
  let idx = -1;
  for (let i = 0; i < width; i++) {
    if (c.nums[i] !== l.nums[i]) {
      idx = i;
      break;
    }
  }
  if (idx === -1) {
    const pre = c.nums.length >= l.nums.length ? comparePre(c.pre, l.pre) : 0;
    if (pre < 0) return { level: "patch", breaking: false };
    return { level: "none", breaking: false };
  }
  if (c.nums[idx] > l.nums[idx]) return { level: "ahead", breaking: false };
  if (c.scheme === "date") return { level: "date", breaking: false };
  const level: Level = idx === 0 ? "major" : idx === 1 ? "minor" : "patch";
  const breaking = level === "major" || (level === "minor" && c.nums[0] === 0);
  return { level, breaking };
}

export interface PickOptions {
  includePre?: boolean;
  /** Only consider candidates with the same scheme, suffix and precision. */
  shapeOf?: string;
}

export function pickLatest(candidates: string[], opts: PickOptions = {}): string | null {
  const shape = opts.shapeOf ? parseVersion(opts.shapeOf) : null;
  let best: string | null = null;
  for (const c of candidates) {
    const p = parseVersion(c);
    if (p.scheme === "none") continue;
    if (p.pre !== null && !opts.includePre) continue;
    if (shape) {
      if (shape.scheme !== "none" && p.scheme !== shape.scheme) continue;
      if (p.suffix !== shape.suffix) continue;
      if (shape.nums.length && p.nums.length !== shape.nums.length) continue;
    } else if (p.suffix) {
      continue;
    }
    if (best === null) {
      best = c;
      continue;
    }
    const cmp = compareVersions(c, best);
    if (Number.isNaN(cmp)) {
      // Mixed schemes without a shape: semver wins over date.
      if (p.scheme === "semver") best = c;
      continue;
    }
    if (cmp > 0) best = c;
  }
  return best;
}
