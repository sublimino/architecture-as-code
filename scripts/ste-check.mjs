#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const scriptPath = path.join(repoRoot, "d2-signalloom/apps/docs-signalloom/scripts/ste-check.mjs");
const defaultDocs = path.join(repoRoot, "d2-signalloom/apps/docs-signalloom/dev-docs/src/content/docs");

const args = process.argv.slice(2);
if (args.length === 0) {
  args.push(defaultDocs);
}

const result = spawnSync(process.execPath, [scriptPath, ...args], { stdio: "inherit" });
process.exit(result.status ?? 1);
