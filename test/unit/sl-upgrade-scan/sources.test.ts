// @id      sl-upgrade-scan-sources
// @target  .agents/skills/sl-upgrade-scan/Tools/fetcher.ts
// @target  .agents/skills/sl-upgrade-scan/Tools/sources.ts
// @doc     .agents/skills/sl-upgrade-scan/SKILL.md
//
// Offline: every network response is a fixture served by a fake Http. The
// fake records each call, so the cache and rate-limit tests count real
// fetches rather than trusting a flag.
import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Fetcher, type Http, type HttpRequest } from "../../../.agents/skills/sl-upgrade-scan/Tools/fetcher.ts";
import type { Item } from "../../../.agents/skills/sl-upgrade-scan/Tools/inventory.ts";
import { eolFor, goProxyPath, resolveLatest } from "../../../.agents/skills/sl-upgrade-scan/Tools/sources.ts";

const NOW = new Date("2026-10-17T09:00:00Z");
type Route = { status?: number; json?: unknown; body?: string; headers?: Record<string, string> };

function fakeHttp(routes: Record<string, Route | Route[]>) {
  const calls: HttpRequest[] = [];
  const seen = new Map<string, number>();
  const http: Http = async (req) => {
    calls.push(req);
    const key = req.method && req.method !== "GET" ? `${req.method} ${req.url}` : req.url;
    let r = routes[key];
    if (Array.isArray(r)) {
      const n = seen.get(key) ?? 0;
      seen.set(key, n + 1);
      r = r[Math.min(n, r.length - 1)];
    }
    if (!r) return { status: 404, headers: {}, body: `no fixture for ${key}` };
    return { status: r.status ?? 200, headers: r.headers ?? {}, body: r.body ?? JSON.stringify(r.json) };
  };
  return { http, calls };
}

const dirs: string[] = [];
function cacheDir() {
  const d = mkdtempSync(join(tmpdir(), "upgrade-scan-cache-"));
  dirs.push(d);
  return d;
}
afterEach(() => {
  while (dirs.length) rmSync(dirs.pop() as string, { recursive: true, force: true });
});

function item(ecosystem: Item["ecosystem"], name: string, current: string, extra: Partial<Item> = {}): Item {
  return { ecosystem, name, current, locations: [{ file: "x.yaml", line: 1 }], notes: [], ...extra };
}

const GH_BAO = "https://api.github.com/repos/openbao/openbao/releases?per_page=100";
const QUAY_BAO = "https://quay.io/v2/openbao/openbao/tags/list?n=1000";
const baoRoutes: Record<string, Route> = {
  [QUAY_BAO]: { json: { tags: ["2.1.1", "2.7.1", "2.7.1-amd64", "2.8.0-rc1", "latest"] } },
  [GH_BAO]: {
    json: [
      { tag_name: "v2.8.0-rc.1", prerelease: true, draft: false, html_url: "https://github.com/openbao/openbao/releases/tag/v2.8.0-rc.1", published_at: "2026-10-10T00:00:00Z" },
      { tag_name: "v2.7.1", prerelease: false, draft: false, html_url: "https://github.com/openbao/openbao/releases/tag/v2.7.1", published_at: "2026-10-01T12:00:00Z" },
      { tag_name: "api/v2.9.0", prerelease: false, draft: false, html_url: "x", published_at: "2026-10-02T00:00:00Z" },
      { tag_name: "v2.6.0", prerelease: false, draft: false, html_url: "x", published_at: "2026-08-01T00:00:00Z" },
    ],
    headers: { "x-ratelimit-remaining": "4999" },
  },
};

describe("Fetcher cache", () => {
  test("concurrent and repeated fetches of one URL hit the network once", async () => {
    const { http, calls } = fakeHttp({ "https://pypi.org/pypi/fastapi/json": { json: { info: { version: "1.0.0" } } } });
    const f = new Fetcher({ http, cacheDir: cacheDir(), now: () => NOW });
    const [a, b] = await Promise.all([f.get("https://pypi.org/pypi/fastapi/json"), f.get("https://pypi.org/pypi/fastapi/json")]);
    await f.get("https://pypi.org/pypi/fastapi/json");
    expect(calls.length).toBe(1);
    expect(a.status).toBe(200);
    expect(b.fetchedAt).toBe(NOW.toISOString());
  });

  test("a second run reads the disk cache and records the original fetch time", async () => {
    const dir = cacheDir();
    const url = "https://pypi.org/pypi/fastapi/json";
    const one = fakeHttp({ [url]: { json: { info: { version: "1.0.0" } } } });
    await new Fetcher({ http: one.http, cacheDir: dir, now: () => NOW }).get(url);
    const two = fakeHttp({});
    const later = new Date(NOW.getTime() + 60_000);
    const r = await new Fetcher({ http: two.http, cacheDir: dir, now: () => later }).get(url);
    expect(two.calls.length).toBe(0);
    expect(r.fromCache).toBe(true);
    expect(r.fetchedAt).toBe(NOW.toISOString());
  });

  test("an expired cache entry is fetched again", async () => {
    const dir = cacheDir();
    const url = "https://pypi.org/pypi/fastapi/json";
    await new Fetcher({ http: fakeHttp({ [url]: { json: {} } }).http, cacheDir: dir, now: () => NOW, ttlMs: 1000 }).get(url);
    const two = fakeHttp({ [url]: { json: {} } });
    await new Fetcher({ http: two.http, cacheDir: dir, now: () => new Date(NOW.getTime() + 5000), ttlMs: 1000 }).get(url);
    expect(two.calls.length).toBe(1);
  });

  test("server errors are not cached", async () => {
    const dir = cacheDir();
    const url = "https://pypi.org/pypi/x/json";
    await new Fetcher({ http: fakeHttp({ [url]: { status: 503, body: "" } }).http, cacheDir: dir, now: () => NOW }).get(url);
    const two = fakeHttp({ [url]: { json: {} } });
    await new Fetcher({ http: two.http, cacheDir: dir, now: () => NOW }).get(url);
    expect(two.calls.length).toBe(1);
  });

  test("the GitHub token is sent to api.github.com only", async () => {
    const { http, calls } = fakeHttp({ [GH_BAO]: baoRoutes[GH_BAO], "https://pypi.org/pypi/x/json": { json: {} } });
    const f = new Fetcher({ http, cacheDir: null, now: () => NOW, githubToken: "t0k" });
    await f.get(GH_BAO);
    await f.get("https://pypi.org/pypi/x/json");
    expect(calls[0].headers?.authorization).toBe("Bearer t0k");
    expect(calls[1].headers?.authorization).toBeUndefined();
  });
});

describe("GitHub rate limit", () => {
  test("after an exhausted limit no further GitHub call is made and items say rate-limited", async () => {
    const limited: Route = { status: 403, body: "{}", headers: { "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1792227600" } };
    const { http, calls } = fakeHttp({ [GH_BAO]: limited, "https://api.github.com/repos/dexidp/dex/releases?per_page=100": { json: [] } });
    const f = new Fetcher({ http, cacheDir: null, now: () => NOW });
    const a = await resolveLatest(item("github-action", "openbao/openbao", "v2.1.1"), f);
    const b = await resolveLatest(item("github-action", "dexidp/dex", "v2.41.1"), f);
    expect(calls.filter((c) => c.url.startsWith("https://api.github.com")).length).toBe(1);
    expect(a.status).toBe("rate-limited");
    expect(b.status).toBe("rate-limited");
    expect(b.latest).toBeNull();
    expect(f.githubLimited?.resetAt).toBe(new Date(1792227600 * 1000).toISOString());
  });
});

describe("resolveLatest: images", () => {
  test("OpenBao 2.1.1: registry tag 2.7.1 and upstream release v2.7.1 with URL and time", async () => {
    const { http } = fakeHttp(baoRoutes);
    const f = new Fetcher({ http, cacheDir: null, now: () => NOW });
    const r = await resolveLatest(item("oci-image", "quay.io/openbao/openbao", "2.1.1"), f);
    expect(r.status).toBe("ok");
    expect(r.latest?.version).toBe("2.7.1");
    expect(r.latest?.sourceUrl).toBe(QUAY_BAO);
    expect(r.latest?.fetchedAt).toBe(NOW.toISOString());
    expect(r.upstreamRelease?.version).toBe("v2.7.1");
    expect(r.upstreamRelease?.sourceUrl).toBe("https://github.com/openbao/openbao/releases/tag/v2.7.1");
    expect(r.upstreamRelease?.publishedAt).toBe("2026-10-01T12:00:00Z");
  });

  test("pre-releases are skipped unless asked", async () => {
    const { http } = fakeHttp(baoRoutes);
    const f = new Fetcher({ http, cacheDir: null, now: () => NOW });
    const r = await resolveLatest(item("oci-image", "quay.io/openbao/openbao", "2.1.1"), f, { includePrereleases: true });
    expect(r.upstreamRelease?.version).toBe("v2.8.0-rc.1");
  });

  test("anonymous registry token challenge, then paginated tags", async () => {
    const tags1 = "https://registry-1.docker.io/v2/library/redis/tags/list?n=1000";
    const tags2 = "https://registry-1.docker.io/v2/library/redis/tags/list?last=7.2-alpine&n=1000";
    const tok = "https://auth.docker.io/token?service=registry.docker.io&scope=repository%3Alibrary%2Fredis%3Apull";
    const { http, calls } = fakeHttp({
      [tags1]: [
        { status: 401, body: "", headers: { "www-authenticate": 'Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/redis:pull"' } },
        { json: { tags: ["7-alpine", "7.2-alpine"] }, headers: { link: '</v2/library/redis/tags/list?last=7.2-alpine&n=1000>; rel="next"' } },
      ],
      [tok]: { json: { token: "anon" } },
      [tags2]: { json: { tags: ["8-alpine", "8.2-alpine", "8", "9-rc-alpine"] } },
      "https://endoflife.date/api/redis.json": { json: [{ cycle: "8.2", eol: false, latest: "8.2.2" }, { cycle: "7.2", eol: "2026-02-28", latest: "7.2.11" }] },
    });
    const f = new Fetcher({ http, cacheDir: null, now: () => NOW });
    const r = await resolveLatest(item("oci-image", "docker.io/library/redis", "7-alpine"), f);
    expect(r.latest?.version).toBe("8-alpine");
    expect(calls.find((c) => c.url === tags2)?.headers?.authorization).toBe("Bearer anon");
  });

  test("an image the registry does not know is unknown, with the reason, never a guess", async () => {
    const { http } = fakeHttp({});
    const f = new Fetcher({ http, cacheDir: null, now: () => NOW });
    const r = await resolveLatest(item("oci-image", "docker.io/library/kubesec-afm", "1.0.0"), f);
    expect(r.status).toBe("unknown");
    expect(r.latest).toBeNull();
    expect(r.reason).toContain("404");
  });

  test("floating and first-party tags make no network call", async () => {
    const { http, calls } = fakeHttp({});
    const f = new Fetcher({ http, cacheDir: null, now: () => NOW });
    expect((await resolveLatest(item("oci-image", "gcr.io/distroless/static-debian12", "nonroot"), f)).status).toBe("floating");
    expect((await resolveLatest(item("oci-image", "docker.io/library/cardvault", "local", { firstParty: true }), f)).status).toBe("first-party");
    expect(calls.length).toBe(0);
  });
});

describe("resolveLatest: packages, actions, tools, runtimes", () => {
  test("Go proxy path escapes capitals", () => {
    expect(goProxyPath("github.com/BurntSushi/toml")).toBe("github.com/!burnt!sushi/toml");
  });

  test("Go module from the proxy @latest", async () => {
    const url = "https://proxy.golang.org/github.com/spf13/cobra/@latest";
    const { http } = fakeHttp({ [url]: { json: { Version: "v1.10.1", Time: "2026-01-01T00:00:00Z" } } });
    const r = await resolveLatest(item("go-module", "github.com/spf13/cobra", "v1.8.0"), new Fetcher({ http, cacheDir: null, now: () => NOW }));
    expect(r.latest).toMatchObject({ version: "v1.10.1", sourceUrl: url });
  });

  test("PyPI and npm", async () => {
    const { http } = fakeHttp({
      "https://pypi.org/pypi/fastapi/json": { json: { info: { version: "0.120.0" } } },
      "https://registry.npmjs.org/react": { json: { "dist-tags": { latest: "19.2.0", next: "20.0.0-rc" } } },
    });
    const f = new Fetcher({ http, cacheDir: null, now: () => NOW });
    expect((await resolveLatest(item("pypi", "fastapi", "0.115.6"), f)).latest?.version).toBe("0.120.0");
    expect((await resolveLatest(item("npm", "react", "18.3.1"), f)).latest?.version).toBe("19.2.0");
  });

  test("GitHub Action from releases", async () => {
    const url = "https://api.github.com/repos/actions/checkout/releases?per_page=100";
    const { http } = fakeHttp({ [url]: { json: [{ tag_name: "v5.0.0", prerelease: false, draft: false, html_url: "https://github.com/actions/checkout/releases/tag/v5.0.0", published_at: "2026-01-01T00:00:00Z" }] } });
    const r = await resolveLatest(item("github-action", "actions/checkout", "v4"), new Fetcher({ http, cacheDir: null, now: () => NOW }));
    expect(r.latest?.version).toBe("v5.0.0");
    expect(r.latest?.sourceUrl).toBe("https://github.com/actions/checkout/releases/tag/v5.0.0");
  });

  test("tool with a tag prefix (kustomize/v5.8.1)", async () => {
    const url = "https://api.github.com/repos/kubernetes-sigs/kustomize/releases?per_page=100";
    const { http } = fakeHttp({
      [url]: { json: [
        { tag_name: "api/v0.20.1", prerelease: false, draft: false, html_url: "x", published_at: "2026-01-01T00:00:00Z" },
        { tag_name: "kustomize/v5.9.0", prerelease: false, draft: false, html_url: "https://github.com/kubernetes-sigs/kustomize/releases/tag/kustomize%2Fv5.9.0", published_at: "2026-01-01T00:00:00Z" },
      ] },
    });
    const r = await resolveLatest(item("tool-pin", "kustomize", "v5.8.1"), new Fetcher({ http, cacheDir: null, now: () => NOW }));
    expect(r.latest?.version).toBe("v5.9.0");
  });

  test("an unmapped tool is unknown", async () => {
    const { http, calls } = fakeHttp({});
    const r = await resolveLatest(item("tool-pin", "chart", "0.9.9"), new Fetcher({ http, cacheDir: null, now: () => NOW }));
    expect(r.status).toBe("unknown");
    expect(r.reason).toContain("no upstream mapping");
    expect(calls.length).toBe(0);
  });

  test("Go runtime: latest from endoflife.date, EOL of the current cycle", async () => {
    const url = "https://endoflife.date/api/go.json";
    const { http } = fakeHttp({
      [url]: { json: [
        { cycle: "1.27", eol: false, latest: "1.27.2" },
        { cycle: "1.26", eol: false, latest: "1.26.9" },
        { cycle: "1.22", eol: "2025-02-11", latest: "1.22.12" },
      ] },
    });
    const f = new Fetcher({ http, cacheDir: null, now: () => NOW });
    const r = await resolveLatest(item("runtime", "go", "1.22.0"), f);
    expect(r.latest).toMatchObject({ version: "1.27.2", sourceUrl: url });
    const eol = await eolFor(item("runtime", "go", "1.22.0"), f);
    expect(eol).toMatchObject({ product: "go", cycle: "1.22", eol: true, eolDate: "2025-02-11" });
    const ok = await eolFor(item("oci-image", "docker.io/library/golang", "1.27-alpine"), f);
    expect(ok).toMatchObject({ cycle: "1.27", eol: false });
  });

  test("EOL is null for an item with no product mapping", async () => {
    const { http } = fakeHttp({});
    expect(await eolFor(item("npm", "react", "18.3.1"), new Fetcher({ http, cacheDir: null, now: () => NOW }))).toBeNull();
  });
});
