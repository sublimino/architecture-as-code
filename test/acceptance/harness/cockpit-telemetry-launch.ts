// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Node-side fixture for the two cockpit telemetry specs (SLDC-P4-2).
 *
 * Spawns `bun harness/cockpit-telemetry-server.ts --port 0`, waits for its
 * ready line, and exposes a worker-scoped `harness` plus control helpers.
 * Not a spec file, so both specs can share it without Playwright refusing a
 * test file that imports another.
 */
import { spawn, type ChildProcessByStdio } from "node:child_process";
import { join } from "node:path";
import type { Readable } from "node:stream";
import { test as base, expect, type APIRequestContext } from "@playwright/test";

export interface CockpitHarness {
  url: string;
  child: ChildProcessByStdio<null, Readable, Readable>;
}

export type Phase = "idle" | "spike" | "frozen" | "terminated";

export const CPU_FORMAT = /^[0-9]+\.[0-9]{3} mCPU$/;
export const CPU = "#cockpit-cpu-metric";
export const BADGE = '[data-testid="cockpit-state-badge"]';
export const PILL = '[data-testid="cockpit-containment-pill"]';
export const MEMORY = '[data-testid="cockpit-memory-metric"]';
export const FLATLINE = '[data-testid="cockpit-flatline"]';
export const CONNECTION = '[data-testid="cockpit-connection"]';
export const TOP_BAR = '[data-testid="metrics-top-bar"]';

async function launch(rootDir: string): Promise<CockpitHarness> {
  const script = join(rootDir, "harness", "cockpit-telemetry-server.ts");
  const child = spawn("bun", [script, "--port", "0"], { stdio: ["ignore", "pipe", "pipe"] });
  const stderr: string[] = [];
  child.stderr.on("data", (b: Buffer) => stderr.push(b.toString()));
  const url = await new Promise<string>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`cockpit harness not ready in 90s. stderr:\n${stderr.join("")}`)),
      90_000,
    );
    let out = "";
    child.stdout.on("data", (b: Buffer) => {
      out += b.toString();
      const found = out.match(/^COCKPIT_TELEMETRY_HARNESS_READY (\S+)/m)?.[1];
      if (!found) return;
      clearTimeout(timer);
      resolve(found);
    });
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`cockpit harness exited ${code} before ready. stderr:\n${stderr.join("")}`));
    });
  });
  return { url, child };
}

export const test = base.extend<Record<string, never>, { harness: CockpitHarness }>({
  harness: [
    async ({}, use, workerInfo) => {
      const harness = await launch(workerInfo.config.rootDir);
      await use(harness);
      harness.child.kill("SIGTERM");
    },
    { scope: "worker" },
  ],
});

export { expect };

export async function setPhase(request: APIRequestContext, harness: CockpitHarness, phase: Phase): Promise<void> {
  const res = await request.post(`${harness.url}/harness/phase`, { data: { phase } });
  expect(res.status(), `harness refused phase ${phase}`).toBe(200);
}

export async function resetHarness(request: APIRequestContext, harness: CockpitHarness): Promise<void> {
  const res = await request.post(`${harness.url}/harness/reset`);
  expect(res.status()).toBe(200);
  const state = await (await request.get(`${harness.url}/harness/state`)).json();
  expect(state.phase, "reset did not return the scripted agent to idle").toBe("idle");
}

export interface HarnessLog {
  streams: number;
  perPodStreams: number;
  estateStreams: number;
  unauthenticated: number;
  tokenInUrl: number;
  unmatched: string[];
}

export async function requestLog(request: APIRequestContext, harness: CockpitHarness): Promise<HarnessLog> {
  return (await request.get(`${harness.url}/harness/requests`)).json();
}
