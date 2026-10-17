// @id      sl-upgrade-scan-risk-rank
// @target  .agents/skills/sl-upgrade-scan/Tools/risk.ts
// @target  .agents/skills/sl-upgrade-scan/Tools/report.ts
// @doc     .agents/skills/sl-upgrade-scan/SKILL.md
import { describe, expect, test } from "bun:test";
import { Fetcher, type Http } from "../../../.agents/skills/sl-upgrade-scan/Tools/fetcher.ts";
import type { Item } from "../../../.agents/skills/sl-upgrade-scan/Tools/inventory.ts";
import { type Finding, rank, renderMarkdown } from "../../../.agents/skills/sl-upgrade-scan/Tools/report.ts";
import { cvss3, imageRisk, osvRisk, type Runner } from "../../../.agents/skills/sl-upgrade-scan/Tools/risk.ts";

const NOW = new Date("2026-10-17T09:00:00Z");
function item(ecosystem: Item["ecosystem"], name: string, current: string): Item {
  return { ecosystem, name, current, locations: [{ file: "go.mod", line: 7 }], notes: [] };
}

describe("cvss3", () => {
  test("network DoS vector is 7.5 HIGH", () => {
    expect(cvss3("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H")).toEqual({ score: 7.5, severity: "HIGH" });
  });
  test("full compromise vector is 9.8 CRITICAL", () => {
    expect(cvss3("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")).toEqual({ score: 9.8, severity: "CRITICAL" });
  });
  test("scope changed is scored with the 1.08 multiplier", () => {
    expect(cvss3("CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:L/A:N")?.score).toBe(6.1);
  });
  test("not a v3 vector", () => {
    expect(cvss3("CVSS:4.0/AV:N")).toBeNull();
  });
});

describe("osvRisk", () => {
  const jwt = item("go-module", "github.com/golang-jwt/jwt/v5", "v5.2.0");
  const http: Http = async (req) => {
    if (req.method === "POST" && req.url === "https://api.osv.dev/v1/querybatch") {
      const q = JSON.parse(req.body ?? "{}");
      expect(q.queries[0]).toEqual({ package: { name: "github.com/golang-jwt/jwt/v5", ecosystem: "Go" }, version: "v5.2.0" });
      return { status: 200, headers: {}, body: JSON.stringify({ results: [{ vulns: [{ id: "GHSA-fix" }, { id: "GO-open" }] }] }) };
    }
    if (req.url === "https://api.osv.dev/v1/vulns/GHSA-fix") {
      return {
        status: 200,
        headers: {},
        body: JSON.stringify({
          id: "GHSA-fix",
          aliases: ["CVE-2025-30204"],
          database_specific: { severity: "HIGH" },
          affected: [{ package: { name: "github.com/golang-jwt/jwt/v5", ecosystem: "Go" }, ranges: [{ type: "SEMVER", events: [{ introduced: "5.0.0-rc.1" }, { fixed: "5.2.2" }] }] }],
        }),
      };
    }
    if (req.url === "https://api.osv.dev/v1/vulns/GO-open") {
      return {
        status: 200,
        headers: {},
        body: JSON.stringify({
          id: "GO-open",
          aliases: [],
          severity: [{ type: "CVSS_V3", score: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H" }],
          affected: [{ package: { name: "github.com/golang-jwt/jwt/v5", ecosystem: "Go" }, ranges: [{ type: "SEMVER", events: [{ introduced: "0" }, { fixed: "5.9.0" }] }] }],
        }),
      };
    }
    return { status: 404, headers: {}, body: "" };
  };

  test("a CVE fixed at or below the recommended version is fixed by the upgrade; one fixed later is not", async () => {
    const f = new Fetcher({ http, cacheDir: null, now: () => NOW });
    const out = await osvRisk([{ item: jwt, recommended: "v5.3.0" }], f);
    const r = out.get(jwt);
    expect(r?.currentCount).toBe(2);
    expect(r?.fixedByUpgrade.map((v) => [v.id, v.severity, v.fixedIn, v.aliases[0]])).toEqual([["GHSA-fix", "HIGH", "5.2.2", "CVE-2025-30204"]]);
    expect(r?.notFixed.map((v) => [v.id, v.severity, v.fixedIn])).toEqual([["GO-open", "CRITICAL", "5.9.0"]]);
  });

  test("records that alias each other (GHSA and PYSEC for one CVE) count once", async () => {
    const rec = (id: string, aliases: string[]) => ({
      id,
      aliases,
      database_specific: { severity: "HIGH" },
      affected: [{ package: { name: "pyjwt", ecosystem: "PyPI" }, ranges: [{ type: "ECOSYSTEM", events: [{ introduced: "0" }, { fixed: "2.14.0" }] }] }],
    });
    const f = new Fetcher({
      http: async (req) => {
        if (req.method === "POST") return { status: 200, headers: {}, body: JSON.stringify({ results: [{ vulns: [{ id: "GHSA-a" }, { id: "PYSEC-a" }, { id: "GHSA-b" }, { id: "PYSEC-b" }] }] }) };
        const id = req.url.split("/").pop() as string;
        const body = id === "GHSA-a" ? rec(id, ["CVE-1", "PYSEC-a"]) : id === "PYSEC-a" ? rec(id, ["CVE-1", "GHSA-a"]) : rec(id, ["CVE-2"]); // GHSA-b and PYSEC-b share only CVE-2
        return { status: 200, headers: {}, body: JSON.stringify(body) };
      },
      cacheDir: null,
      now: () => NOW,
    });
    const it = item("pypi", "pyjwt", "2.10.1");
    const r = (await osvRisk([{ item: it, recommended: "2.15.1" }], f)).get(it);
    expect(r?.currentCount).toBe(2);
    expect(r?.fixedByUpgrade.map((v) => v.id)).toEqual(["GHSA-a", "GHSA-b"]);
    expect(r?.fixedByUpgrade[0].aliases).toEqual(["CVE-1", "PYSEC-a"]);
  });

  test("Go runtime pins are queried as stdlib", async () => {
    let seen: unknown = null;
    const f = new Fetcher({
      http: async (req) => {
        seen = JSON.parse(req.body ?? "{}").queries[0];
        return { status: 200, headers: {}, body: JSON.stringify({ results: [{}] }) };
      },
      cacheDir: null,
      now: () => NOW,
    });
    await osvRisk([{ item: item("runtime", "go", "1.24.5"), recommended: "1.27.2" }], f);
    expect(seen).toEqual({ package: { name: "stdlib", ecosystem: "Go" }, version: "1.24.5" });
  });
});

describe("imageRisk", () => {
  test("CVEs in the current image and absent from the recommended image are fixed by the upgrade", async () => {
    const calls: string[][] = [];
    const run: Runner = async (_cmd, args) => {
      calls.push(args);
      const ref = args[0];
      const ids = ref.endsWith(":2.1.1") ? [["CVE-1", "Critical"], ["CVE-2", "Medium"], ["CVE-3", "Negligible"]] : [["CVE-2", "Medium"]];
      return { code: 0, stderr: "", stdout: JSON.stringify({ matches: ids.map(([id, s]) => ({ vulnerability: { id, severity: s } })) }) };
    };
    const r = await imageRisk(item("oci-image", "quay.io/openbao/openbao", "2.1.1"), "2.7.1", "grype", run);
    expect(calls.map((a) => a[0])).toEqual(["registry:quay.io/openbao/openbao:2.1.1", "registry:quay.io/openbao/openbao:2.7.1"]);
    expect(r.currentCount).toBe(3);
    expect(r.fixedByUpgrade.map((v) => [v.id, v.severity])).toEqual([["CVE-1", "CRITICAL"], ["CVE-3", "LOW"]]);
    expect(r.notFixed.map((v) => v.id)).toEqual(["CVE-2"]);
  });

  test("a failed scan is an error on the item, not an empty clean result", async () => {
    const run: Runner = async () => ({ code: 1, stdout: "", stderr: "unauthorized" });
    const r = await imageRisk(item("oci-image", "quay.io/openbao/openbao", "2.1.1"), "2.7.1", "trivy", run);
    expect(r.error).toContain("unauthorized");
    expect(r.currentCount).toBeNull();
  });
});

function finding(name: string, over: Partial<Finding>): Finding {
  return {
    item: item("oci-image", name, "1.0.0"),
    resolution: { status: "ok", latest: { version: "2.0.0", sourceUrl: `https://x/${name}`, fetchedAt: NOW.toISOString(), via: "registry-tags" } },
    recommended: "2.0.0",
    distance: { level: "minor", breaking: false },
    eol: null,
    risk: null,
    ...over,
  };
}
const fixed = (sev: "CRITICAL" | "HIGH" | "LOW", n = 1) => ({
  source: "osv" as const,
  currentCount: n,
  fixedByUpgrade: Array.from({ length: n }, (_, i) => ({ id: `V-${sev}-${i}`, aliases: [], severity: sev, fixedIn: "2.0.0", url: "u" })),
  notFixed: [],
});
const eol = { product: "go", cycle: "1.22", eol: true, eolDate: "2025-02-11", latestInCycle: "1.22.12", sourceUrl: "u", fetchedAt: "t" };

describe("rank", () => {
  test("fixed-CVE severity, then EOL, then distance, then fixed count", () => {
    const out = rank([
      finding("major-only", { distance: { level: "major", breaking: true } }),
      finding("eol-minor", { eol }),
      finding("high-patch", { distance: { level: "patch", breaking: false }, risk: fixed("HIGH") }),
      finding("critical-minor", { risk: fixed("CRITICAL") }),
      finding("high-patch-3", { distance: { level: "patch", breaking: false }, risk: fixed("HIGH", 3) }),
      finding("unknown", { resolution: { status: "unknown", latest: null, reason: "registry 404" }, recommended: null, distance: { level: "unknown", breaking: false } }),
    ]);
    expect(out.map((f) => f.item.name)).toEqual(["critical-minor", "high-patch-3", "high-patch", "eol-minor", "major-only", "unknown"]);
  });
});

describe("renderMarkdown", () => {
  test("every recommended version carries its source URL and fetch time; unknowns are listed with their reason", () => {
    const md = renderMarkdown({
      generatedAt: NOW.toISOString(),
      root: "/repo",
      findings: rank([
        finding("quay.io/openbao/openbao", { distance: { level: "minor", breaking: false } }),
        finding("docker.io/library/kubesec-afm", { resolution: { status: "unknown", latest: null, reason: "registry 401" }, recommended: null, distance: { level: "unknown", breaking: false } }),
      ]),
      top: 10,
    });
    const row = md.split("\n").find((l) => l.includes("quay.io/openbao/openbao")) ?? "";
    expect(row).toContain("2.0.0");
    expect(row).toContain("https://x/quay.io/openbao/openbao");
    expect(row).toContain(NOW.toISOString());
    expect(row).toContain("go.mod:7");
    expect(md).toContain("## Unknown upstream");
    const unk = md.split("\n").find((l) => l.includes("kubesec-afm")) ?? "";
    expect(unk).toContain("registry 401");
    expect(unk).not.toContain("2.0.0");
  });
});
