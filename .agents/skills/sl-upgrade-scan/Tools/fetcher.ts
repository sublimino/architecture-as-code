// HTTP for sl-upgrade-scan: one injectable transport, a disk + in-memory
// cache, request de-duplication, and GitHub rate-limit awareness.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export interface HttpRequest {
  url: string;
  method?: string;
  headers?: Record<string, string>;
  body?: string;
}
export interface HttpResponse {
  status: number;
  headers: Record<string, string>;
  body: string;
}
export type Http = (req: HttpRequest) => Promise<HttpResponse>;

export interface FetchResult extends HttpResponse {
  url: string;
  fetchedAt: string;
  fromCache: boolean;
}

export interface FetcherOptions {
  http: Http;
  /** null disables the disk cache. */
  cacheDir?: string | null;
  ttlMs?: number;
  now?: () => Date;
  githubToken?: string | null;
}

const CACHEABLE = new Set([200, 404, 410]);
const KEEP_HEADERS = ["link", "www-authenticate", "x-ratelimit-remaining", "x-ratelimit-reset", "content-type"];

/** Real transport: fetch with a timeout. */
export const fetchHttp: Http = async (req) => {
  const res = await fetch(req.url, {
    method: req.method ?? "GET",
    headers: { "user-agent": "sl-upgrade-scan", ...(req.headers ?? {}) },
    body: req.body,
    signal: AbortSignal.timeout(30_000),
    redirect: "follow",
  });
  const headers: Record<string, string> = {};
  res.headers.forEach((v, k) => {
    headers[k.toLowerCase()] = v;
  });
  return { status: res.status, headers, body: await res.text() };
};

export class Fetcher {
  networkCalls = 0;
  githubLimited: { resetAt: string } | null = null;
  private inflight = new Map<string, Promise<FetchResult>>();
  private http: Http;
  private cacheDir: string | null;
  private ttlMs: number;
  private now: () => Date;
  private token: string | null;

  constructor(o: FetcherOptions) {
    this.http = o.http;
    this.cacheDir = o.cacheDir ?? null;
    this.ttlMs = o.ttlMs ?? 6 * 3600_000;
    this.now = o.now ?? (() => new Date());
    this.token = o.githubToken ?? null;
    if (this.cacheDir) {
      try {
        mkdirSync(this.cacheDir, { recursive: true });
      } catch (e) {
        // A sandbox or read-only home must not stop the scan; it only costs repeat fetches.
        this.cacheWarning = `disk cache disabled: cannot create ${this.cacheDir} (${(e as Error).message})`;
        this.cacheDir = null;
      }
    }
  }

  cacheWarning: string | null = null;

  /** Fetch with caching. `noCache` is for short-lived responses such as registry tokens. */
  get(url: string, req: Omit<HttpRequest, "url"> & { noCache?: boolean } = {}): Promise<FetchResult> {
    // Auth presence (never its value) is part of the key: an authenticated retry
    // after a 401 challenge must not be served the in-flight 401.
    const authed = req.headers?.authorization ? "auth" : "anon";
    const key = createHash("sha256").update(`${req.method ?? "GET"} ${url} ${req.body ?? ""} ${authed}`).digest("hex");
    const pending = this.inflight.get(key);
    if (pending && !req.noCache) return pending;
    const p = this.load(key, url, req);
    if (!req.noCache) this.inflight.set(key, p);
    return p;
  }

  private async load(key: string, url: string, req: Omit<HttpRequest, "url"> & { noCache?: boolean }): Promise<FetchResult> {
    const file = this.cacheDir ? join(this.cacheDir, `${key}.json`) : null;
    if (file && !req.noCache && existsSync(file)) {
      try {
        const c = JSON.parse(readFileSync(file, "utf8")) as FetchResult;
        if (this.now().getTime() - Date.parse(c.fetchedAt) < this.ttlMs) return { ...c, fromCache: true };
      } catch {
        // corrupt entry: refetch
      }
    }
    const isGithub = url.startsWith("https://api.github.com/");
    if (isGithub && this.githubLimited) {
      return { url, status: 429, headers: {}, body: "", fetchedAt: this.now().toISOString(), fromCache: false };
    }
    const headers = { ...(req.headers ?? {}) };
    if (isGithub) {
      headers.accept ??= "application/vnd.github+json";
      if (this.token) headers.authorization = `Bearer ${this.token}`;
    }
    this.networkCalls++;
    let res: HttpResponse;
    try {
      res = await this.http({ url, method: req.method, headers, body: req.body });
    } catch (e) {
      return { url, status: 599, headers: {}, body: String(e), fetchedAt: this.now().toISOString(), fromCache: false };
    }
    const h: Record<string, string> = {};
    for (const k of KEEP_HEADERS) if (res.headers[k] !== undefined) h[k] = res.headers[k];
    const out: FetchResult = { url, status: res.status, headers: h, body: res.body, fetchedAt: this.now().toISOString(), fromCache: false };
    if (isGithub && (res.status === 403 || res.status === 429) && h["x-ratelimit-remaining"] === "0") {
      const reset = Number(h["x-ratelimit-reset"]);
      this.githubLimited = { resetAt: Number.isFinite(reset) ? new Date(reset * 1000).toISOString() : "unknown" };
    }
    if (file && !req.noCache && CACHEABLE.has(res.status)) writeFileSync(file, JSON.stringify(out));
    return out;
  }
}
