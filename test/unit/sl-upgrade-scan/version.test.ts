// @id      sl-upgrade-scan-version
// @target  .agents/skills/sl-upgrade-scan/Tools/version.ts
// @doc     .agents/skills/sl-upgrade-scan/SKILL.md
import { describe, expect, test } from "bun:test";
import {
  compareVersions,
  distance,
  isPrerelease,
  parseVersion,
  pickLatest,
} from "../../../.agents/skills/sl-upgrade-scan/Tools/version.ts";

describe("parseVersion", () => {
  test("strips a v prefix and reads three numbers", () => {
    const v = parseVersion("v2.7.1");
    expect(v.scheme).toBe("semver");
    expect(v.nums).toEqual([2, 7, 1]);
    expect(v.pre).toBeNull();
  });

  test("keeps an image variant suffix apart from the version", () => {
    const v = parseVersion("1.27-alpine");
    expect(v.nums).toEqual([1, 27]);
    expect(v.suffix).toBe("-alpine");
    expect(v.pre).toBeNull();
  });

  test("reads a pre-release marker and does not confuse it with -alpine", () => {
    expect(parseVersion("v2.8.0-rc.1").pre).toBe("-rc.1");
    expect(parseVersion("1.0.0-beta2").pre).toBe("-beta2");
    expect(parseVersion("3.12-alpine3.20").pre).toBeNull();
  });

  test("a date tag is the date scheme, not semver", () => {
    expect(parseVersion("2026.10.01").scheme).toBe("date");
    expect(parseVersion("20261001").scheme).toBe("date");
    expect(parseVersion("20261001").nums).toEqual([2026, 10, 1]);
  });

  test("a hash-shaped or floating tag has no version", () => {
    expect(parseVersion("src-d303e20f5867").scheme).toBe("none");
    expect(parseVersion("latest").scheme).toBe("none");
    expect(parseVersion("nonroot").scheme).toBe("none");
  });

  test("a Go pseudo-version is a pre-release", () => {
    const v = parseVersion("v0.0.0-20240101000000-abcdef123456");
    expect(v.nums).toEqual([0, 0, 0]);
    expect(isPrerelease(v.raw)).toBe(true);
  });

  test("a tag prefix such as kustomize/v or jq- is stripped", () => {
    expect(parseVersion("kustomize/v5.8.1").nums).toEqual([5, 8, 1]);
    expect(parseVersion("jq-1.7.1").nums).toEqual([1, 7, 1]);
  });
});

describe("compareVersions", () => {
  test("numeric, not lexical: 1.10 > 1.9", () => {
    expect(compareVersions("1.10.0", "1.9.9")).toBeGreaterThan(0);
  });
  test("v prefix does not matter", () => {
    expect(compareVersions("2.1.1", "v2.1.1")).toBe(0);
  });
  test("a release outranks its own pre-release", () => {
    expect(compareVersions("2.8.0", "2.8.0-rc.1")).toBeGreaterThan(0);
    expect(compareVersions("2.8.0-rc.2", "2.8.0-rc.10")).toBeLessThan(0);
  });
  test("dates compare as dates", () => {
    expect(compareVersions("2026.10.01", "2026.9.30")).toBeGreaterThan(0);
  });
  test("different schemes are incomparable", () => {
    expect(Number.isNaN(compareVersions("2026.10.01", "1.2.3"))).toBe(true);
    expect(Number.isNaN(compareVersions("latest", "1.2.3"))).toBe(true);
  });
});

describe("distance", () => {
  test("OpenBao 2.1.1 to v2.7.1 is a minor bump, not breaking", () => {
    expect(distance("2.1.1", "v2.7.1")).toEqual({ level: "minor", breaking: false });
  });
  test("a major bump is breaking", () => {
    expect(distance("v3.18.4", "v4.0.1")).toEqual({ level: "major", breaking: true });
  });
  test("a 0.x minor bump is breaking under semver", () => {
    expect(distance("v0.29.0", "v0.30.0")).toEqual({ level: "minor", breaking: true });
  });
  test("patch", () => {
    expect(distance("1.11.1", "1.11.3")).toEqual({ level: "patch", breaking: false });
  });
  test("a floating 1.27 tag is current against 1.27.3", () => {
    expect(distance("1.27-alpine", "1.27.3-alpine").level).toBe("none");
  });
  test("current newer than the reported latest is reported, not hidden", () => {
    expect(distance("2.0.0", "1.9.0").level).toBe("ahead");
  });
  test("incomparable schemes are unknown", () => {
    expect(distance("latest", "1.2.3").level).toBe("unknown");
  });
  test("a date tag reports a date distance", () => {
    expect(distance("2026.01.01", "2026.10.01").level).toBe("date");
  });
});

describe("pickLatest", () => {
  test("skips pre-releases unless asked", () => {
    const tags = ["v2.7.1", "v2.8.0-rc.1", "v2.6.9"];
    expect(pickLatest(tags)).toBe("v2.7.1");
    expect(pickLatest(tags, { includePre: true })).toBe("v2.8.0-rc.1");
  });
  test("keeps the image shape: same suffix and same precision", () => {
    const tags = ["1.28-alpine", "1.28.1-alpine", "1.29", "1.29-bookworm", "1.27-alpine", "latest", "alpine"];
    expect(pickLatest(tags, { shapeOf: "1.27-alpine" })).toBe("1.28-alpine");
  });
  test("returns null when nothing is comparable", () => {
    expect(pickLatest(["latest", "nonroot", "src-abcdef1234"])).toBeNull();
  });
  test("does not mix date tags into a semver series", () => {
    expect(pickLatest(["1.2.3", "20261001"], { shapeOf: "1.2.0" })).toBe("1.2.3");
  });
});
