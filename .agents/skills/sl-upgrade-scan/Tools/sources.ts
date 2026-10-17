// Latest-version and EOL resolution for sl-upgrade-scan. Every answer carries
// the URL it came from and the time it was fetched; anything that cannot be
// resolved is "unknown" with a reason, never a guess.

import type { Fetcher, FetchResult } from "./fetcher.ts";
import type { Item } from "./inventory.ts";
import upstreams from "./upstreams.json";
import { compareVersions, isPrerelease, parseVersion, pickLatest } from "./version.ts";

export interface Latest {
  version: string;
  sourceUrl: string;
  fetchedAt: string;
  via: "registry-tags" | "github-releases" | "github-tags" | "goproxy" | "pypi" | "npm" | "endoflife";
  publishedAt?: string;
}

export type ResolutionStatus = "ok" | "unknown" | "floating" | "first-party" | "rate-limited";

export interface Resolution {
  status: ResolutionStatus;
  latest: Latest | null;
  /** The upstream project's newest release when it differs in source from `latest` (images). */
  upstreamRelease?: Latest | null;
  reason?: string;
}

export interface ResolveOptions {
  includePrereleases?: boolean;
}

interface Upstream {
  github?: string;
  eol?: string;
  tagPrefix?: string;
  latestFrom?: "eol";
  goproxy?: string;
  pypi?: string;
  registry?: boolean;
  note?: string;
}
const IMAGES = (upstreams as { images: Record<string, Upstream> }).images;
const TOOLS = (upstreams as { tools: Record<string, Upstream> }).tools;

function json<T>(r: FetchResult): T | null {
  try {
    return JSON.parse(r.body) as T;
  } catch {
    return null;
  }
}

// --- GitHub ------------------------------------------------------------------

interface GhRelease {
  tag_name: string;
  prerelease: boolean;
  draft: boolean;
  html_url: string;
  published_at: string;
}

async function githubLatest(
  repo: string,
  f: Fetcher,
  opts: ResolveOptions,
  tagPrefix?: string,
): Promise<{ latest: Latest | null; status: ResolutionStatus; reason?: string }> {
  const url = `https://api.github.com/repos/${repo}/releases?per_page=100`;
  const r = await f.get(url);
  if (r.status === 429 || f.githubLimited) {
    return { latest: null, status: "rate-limited", reason: `GitHub API rate limit exhausted until ${f.githubLimited?.resetAt ?? "unknown"}` };
  }
  if (r.status !== 200) return { latest: null, status: "unknown", reason: `GitHub releases for ${repo}: HTTP ${r.status}` };
  const rels = (json<GhRelease[]>(r) ?? []).filter((x) => !x.draft && (opts.includePrereleases || !x.prerelease));
  const byVersion = new Map<string, GhRelease>();
  for (const rel of rels) {
    const tag = rel.tag_name;
    if (tagPrefix) {
      if (tag.startsWith(tagPrefix)) byVersion.set(tag.slice(tagPrefix.length), rel);
    } else if (!tag.includes("/")) {
      byVersion.set(tag, rel);
    }
  }
  let pick = pickLatest([...byVersion.keys()], { includePre: opts.includePrereleases });
  if (pick) {
    const rel = byVersion.get(pick) as GhRelease;
    return {
      status: "ok",
      latest: { version: pick, sourceUrl: rel.html_url, fetchedAt: r.fetchedAt, via: "github-releases", publishedAt: rel.published_at },
    };
  }
  // Some projects tag without publishing releases.
  const turl = `https://api.github.com/repos/${repo}/tags?per_page=100`;
  const t = await f.get(turl);
  if (t.status !== 200) return { latest: null, status: t.status === 429 ? "rate-limited" : "unknown", reason: `no releases; GitHub tags for ${repo}: HTTP ${t.status}` };
  const names = (json<{ name: string }[]>(t) ?? [])
    .map((x) => x.name)
    .filter((n) => (tagPrefix ? n.startsWith(tagPrefix) : !n.includes("/")))
    .map((n) => (tagPrefix ? n.slice(tagPrefix.length) : n));
  pick = pickLatest(names, { includePre: opts.includePrereleases });
  if (!pick) return { latest: null, status: "unknown", reason: `no version-shaped release or tag in ${repo}` };
  return {
    status: "ok",
    latest: { version: pick, sourceUrl: `https://github.com/${repo}/releases/tag/${encodeURIComponent((tagPrefix ?? "") + pick)}`, fetchedAt: t.fetchedAt, via: "github-tags" },
  };
}

// --- OCI registries -----------------------------------------------------------

export function registryEndpoint(name: string): { host: string; path: string } {
  const [first, ...rest] = name.split("/");
  if (first === "docker.io") return { host: "registry-1.docker.io", path: rest.join("/") };
  return { host: first, path: rest.join("/") };
}

function parseChallenge(h: string): Record<string, string> | null {
  if (!/^Bearer\s/i.test(h)) return null;
  const out: Record<string, string> = {};
  for (const m of h.matchAll(/(\w+)="([^"]*)"/g)) out[m[1]] = m[2];
  return out.realm ? out : null;
}

async function registryTags(
  name: string,
  f: Fetcher,
): Promise<{ tags: string[]; url: string; fetchedAt: string; reason?: string }> {
  const { host, path } = registryEndpoint(name);
  const url = `https://${host}/v2/${path}/tags/list?n=1000`;
  let headers: Record<string, string> | undefined;
  let r = await f.get(url);
  if (r.status === 401) {
    const c = parseChallenge(r.headers["www-authenticate"] ?? "");
    if (!c) return { tags: [], url, fetchedAt: r.fetchedAt, reason: `registry ${host}: HTTP 401 with no Bearer challenge` };
    const q = new URLSearchParams();
    if (c.service) q.set("service", c.service);
    if (c.scope) q.set("scope", c.scope);
    const tok = await f.get(`${c.realm}?${q.toString()}`, { noCache: true });
    const tj = json<{ token?: string; access_token?: string }>(tok);
    const token = tj?.token ?? tj?.access_token;
    if (!token) return { tags: [], url, fetchedAt: r.fetchedAt, reason: `registry ${host}: anonymous token refused (HTTP ${tok.status})` };
    headers = { authorization: `Bearer ${token}` };
    r = await f.get(url, { headers });
  }
  if (r.status !== 200) {
    return { tags: [], url, fetchedAt: r.fetchedAt, reason: `registry ${host}/${path}: HTTP ${r.status} (not found, private, or not a registry)` };
  }
  const tags = [...(json<{ tags?: string[] }>(r)?.tags ?? [])];
  let next = r.headers.link;
  for (let page = 0; next && page < 20; page++) {
    const m = /<([^>]+)>;\s*rel="next"/.exec(next);
    if (!m) break;
    const nurl = m[1].startsWith("http") ? m[1] : `https://${host}${m[1]}`;
    const p = await f.get(nurl, { headers });
    if (p.status !== 200) break;
    tags.push(...(json<{ tags?: string[] }>(p)?.tags ?? []));
    next = p.headers.link;
  }
  return { tags, url, fetchedAt: r.fetchedAt };
}

// --- package registries ---------------------------------------------------------

export function goProxyPath(mod: string): string {
  return mod.replace(/[A-Z]/g, (c) => `!${c.toLowerCase()}`);
}

async function goproxyLatest(mod: string, f: Fetcher): Promise<Resolution> {
  const url = `https://proxy.golang.org/${goProxyPath(mod)}/@latest`;
  const r = await f.get(url);
  const j = r.status === 200 ? json<{ Version: string; Time?: string }>(r) : null;
  if (!j?.Version) return { status: "unknown", latest: null, reason: `Go proxy ${mod}: HTTP ${r.status}` };
  return { status: "ok", latest: { version: j.Version, sourceUrl: url, fetchedAt: r.fetchedAt, via: "goproxy", publishedAt: j.Time } };
}

async function pypiLatest(name: string, f: Fetcher, opts: ResolveOptions): Promise<Resolution> {
  const url = `https://pypi.org/pypi/${name}/json`;
  const r = await f.get(url);
  const j = r.status === 200 ? json<{ info: { version: string }; releases?: Record<string, unknown> }>(r) : null;
  if (!j?.info?.version) return { status: "unknown", latest: null, reason: `PyPI ${name}: HTTP ${r.status}` };
  let v = j.info.version;
  if (isPrerelease(v) && !opts.includePrereleases) v = pickLatest(Object.keys(j.releases ?? {})) ?? v;
  return { status: "ok", latest: { version: v, sourceUrl: url, fetchedAt: r.fetchedAt, via: "pypi" } };
}

async function npmLatest(name: string, f: Fetcher): Promise<Resolution> {
  const url = `https://registry.npmjs.org/${name.replace("/", "%2F")}`;
  const r = await f.get(url, { headers: { accept: "application/vnd.npm.install-v1+json" } });
  const v = r.status === 200 ? json<{ "dist-tags"?: { latest?: string } }>(r)?.["dist-tags"]?.latest : undefined;
  if (!v) return { status: "unknown", latest: null, reason: `npm ${name}: HTTP ${r.status}` };
  return { status: "ok", latest: { version: v, sourceUrl: url, fetchedAt: r.fetchedAt, via: "npm" } };
}

// --- endoflife.date --------------------------------------------------------------

interface Cycle {
  cycle: string;
  eol: boolean | string;
  latest?: string;
}

async function cycles(product: string, f: Fetcher): Promise<{ list: Cycle[]; r: FetchResult } | null> {
  const r = await f.get(`https://endoflife.date/api/${product}.json`);
  const list = r.status === 200 ? json<Cycle[]>(r) : null;
  return list ? { list, r } : null;
}

async function eolLatest(product: string, f: Fetcher): Promise<Resolution> {
  const c = await cycles(product, f);
  if (!c) return { status: "unknown", latest: null, reason: `endoflife.date ${product}: no data` };
  let best: string | null = null;
  for (const x of c.list) if (x.latest && (best === null || compareVersions(x.latest, best) > 0)) best = x.latest;
  if (!best) return { status: "unknown", latest: null, reason: `endoflife.date ${product}: no latest field` };
  return { status: "ok", latest: { version: best, sourceUrl: c.r.url, fetchedAt: c.r.fetchedAt, via: "endoflife" } };
}

export interface EolInfo {
  product: string;
  cycle: string | null;
  eol: boolean | null;
  eolDate: string | null;
  latestInCycle: string | null;
  sourceUrl: string;
  fetchedAt: string;
}

export function eolProduct(it: Item): string | null {
  if (it.ecosystem === "runtime") return it.name === "go" ? "go" : null;
  if (it.ecosystem === "oci-image" || it.ecosystem === "oci-artifact") return IMAGES[it.name]?.eol ?? null;
  if (it.ecosystem === "tool-pin") return TOOLS[it.name]?.eol ?? null;
  return null;
}

export async function eolFor(it: Item, f: Fetcher): Promise<EolInfo | null> {
  const product = eolProduct(it);
  if (!product) return null;
  const cur = parseVersion(it.current);
  if (cur.scheme === "none") return null;
  const c = await cycles(product, f);
  if (!c) return null;
  const prefixOf = (a: number[], b: number[]) => a.length <= b.length && a.every((n, i) => n === b[i]);
  let match: Cycle | null = null;
  let matchLen = -1;
  // Longest cycle that the pinned version sits in (1.27 for 1.27.2) ...
  for (const x of c.list) {
    const cn = parseVersion(x.cycle).nums;
    if (cn.length && prefixOf(cn, cur.nums) && cn.length > matchLen) {
      match = x;
      matchLen = cn.length;
    }
  }
  // ... else a floating tag (redis:7) tracks the newest cycle under it.
  if (!match) {
    for (const x of c.list) {
      if (prefixOf(cur.nums, parseVersion(x.cycle).nums) && (!match || compareVersions(x.cycle, match.cycle) > 0)) match = x;
    }
  }
  const base = { product, sourceUrl: c.r.url, fetchedAt: c.r.fetchedAt };
  if (!match) return { ...base, cycle: null, eol: null, eolDate: null, latestInCycle: null };
  const eolDate = typeof match.eol === "string" ? match.eol : null;
  const eol = match.eol === true || (eolDate !== null && Date.parse(eolDate) <= Date.parse(c.r.fetchedAt));
  return { ...base, cycle: match.cycle, eol, eolDate, latestInCycle: match.latest ?? null };
}

// --- dispatcher --------------------------------------------------------------------

async function viaUpstream(u: Upstream, f: Fetcher, opts: ResolveOptions): Promise<Resolution> {
  if (u.latestFrom === "eol" && u.eol) return eolLatest(u.eol, f);
  if (u.github) return githubLatest(u.github, f, opts, u.tagPrefix);
  if (u.goproxy) return goproxyLatest(u.goproxy, f);
  if (u.pypi) return pypiLatest(u.pypi, f, opts);
  if (u.eol) return eolLatest(u.eol, f);
  return { status: "unknown", latest: null, reason: "upstream mapping has no source" };
}

async function resolveImage(it: Item, f: Fetcher, opts: ResolveOptions): Promise<Resolution> {
  const u = IMAGES[it.name];
  const gh = u?.github ? await githubLatest(u.github, f, opts, u.tagPrefix) : null;
  let latest: Latest | null = null;
  let reason: string | undefined;
  if (u?.registry !== false) {
    const reg = await registryTags(it.name, f);
    const pick = pickLatest(reg.tags, { shapeOf: it.current, includePre: opts.includePrereleases });
    if (pick) latest = { version: pick, sourceUrl: reg.url, fetchedAt: reg.fetchedAt, via: "registry-tags" };
    else reason = reg.reason ?? `no registry tag shaped like "${it.current}"`;
  }
  if (!latest && gh?.latest) {
    latest = gh.latest;
    reason = `${reason}; using the GitHub release, which may not be published as an image tag`;
  }
  if (latest) return { status: "ok", latest, upstreamRelease: gh?.latest ?? null, reason: latest.via === "registry-tags" ? undefined : reason };
  if (gh?.status === "rate-limited") return { status: "rate-limited", latest: null, upstreamRelease: null, reason: gh.reason };
  return { status: "unknown", latest: null, upstreamRelease: null, reason: [reason, gh?.reason].filter(Boolean).join("; ") };
}

export async function resolveLatest(it: Item, f: Fetcher, opts: ResolveOptions = {}): Promise<Resolution> {
  if (it.firstParty) return { status: "first-party", latest: null, reason: "built from this repository" };
  if (parseVersion(it.current).scheme === "none") {
    return { status: "floating", latest: null, reason: `"${it.current}" is not a version: the pin moves without a commit` };
  }
  switch (it.ecosystem) {
    case "oci-image":
    case "oci-artifact":
      return resolveImage(it, f, opts);
    case "github-action":
      return githubLatest(it.name, f, opts);
    case "go-module":
      return goproxyLatest(it.name, f);
    case "pypi":
      return pypiLatest(it.name, f, opts);
    case "npm":
      return npmLatest(it.name, f);
    case "runtime":
      return it.name === "go" ? eolLatest("go", f) : { status: "unknown", latest: null, reason: `no source for runtime ${it.name}` };
    case "tool-pin": {
      const u = TOOLS[it.name];
      if (!u) return { status: "unknown", latest: null, reason: `no upstream mapping for tool "${it.name}" (add it to Tools/upstreams.json)` };
      return viaUpstream(u, f, opts);
    }
  }
}
