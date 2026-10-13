// @target  test/acceptance/helpers.ts (classifyApiCalls)
//
// Unit tests for the /api health rule used by signalloom-login.spec.ts. These
// run without a cluster (`bun test test/acceptance/api-recovery.test.ts`), so
// the rule itself is proven even when the estate is down.
//
// The sequences below are not invented. They are what a real login produced on
// 2026-10-13 against the live tailnet: /api/v1/features took four 401s before
// a 200 while the OIDC token resolved, and /api/signals/observations returned
// a bare 502 that never recovered.

import { describe, expect, test } from "bun:test";
import { classifyApiCalls, type ApiCall } from "./helpers";

const call = (key: string, ...statuses: number[]): ApiCall[] =>
  statuses.map((status) => ({ key, status }));

describe("classifyApiCalls", () => {
  test("tolerates a client error that later succeeds on the same endpoint", () => {
    const r = classifyApiCalls(call("GET /api/v1/features", 401, 401, 401, 401, 200));
    expect(r.serverErrors).toEqual([]);
    expect(r.unrecovered).toEqual([]);
    expect(r.transient).toEqual(["GET /api/v1/features → 401,401,401,401,200"]);
  });

  test("fails a client error that never succeeds", () => {
    const r = classifyApiCalls(call("GET /api/agents", 403, 403));
    expect(r.unrecovered).toEqual(["GET /api/agents → 403,403"]);
    expect(r.transient).toEqual([]);
  });

  test("fails a server error even when a later call to it succeeds", () => {
    // A 502 is the backend falling over, not a token race. A retry that happens
    // to land does not make it healthy, so recovery must not excuse it.
    const r = classifyApiCalls(call("GET /api/signals/observations", 502, 200));
    expect(r.serverErrors).toEqual(["GET /api/signals/observations → 502,200"]);
    expect(r.unrecovered).toEqual([]);
    expect(r.transient).toEqual([]);
  });

  test("a clean session classifies as nothing at all", () => {
    const r = classifyApiCalls([...call("GET /api/agents", 200, 200), ...call("GET /api/audit", 200)]);
    expect(r).toEqual({ serverErrors: [], unrecovered: [], transient: [] });
  });

  test("recovery is per endpoint, so one healthy path cannot mask a broken one", () => {
    const r = classifyApiCalls([
      ...call("GET /api/v1/features", 401, 200),
      ...call("GET /api/signals/observations", 401),
    ]);
    expect(r.transient).toEqual(["GET /api/v1/features → 401,200"]);
    expect(r.unrecovered).toEqual(["GET /api/signals/observations → 401"]);
  });

  test("a success before the failure does not count as recovery", () => {
    // Ordering matters: 200 then 401 means it broke and stayed broken.
    const r = classifyApiCalls(call("GET /api/agents", 200, 401));
    expect(r.unrecovered).toEqual(["GET /api/agents → 200,401"]);
    expect(r.transient).toEqual([]);
  });
});
