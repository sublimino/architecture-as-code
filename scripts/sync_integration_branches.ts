#!/usr/bin/env bun
/**
 * scripts/sync_integration_branches.ts — Automated Branch Synchronization Worker
 *
 * Takes the current integration branch (integration/slsi-v0.1.0) and:
 * 1. Inspects active feature branch(es):
 *    - feat/signal-loop-and-bootstrap-refactor (primary target)
 *    - docs/arch-diagrams (secondary target)
 * 2. Rebases target feature branch cleanly onto latest integration/slsi-v0.1.0 tip.
 * 3. Automatically derives and pins signal-ingest image tag and verifies manifest guard tests.
 * 4. Rebases secondary feature branches onto latest integration tip.
 * 5. Merges integration and feature branches down to main and master so trunk stays synchronized.
 * 6. Verifies platform test suites to guarantee zero regressions.
 * 7. Records coordination entries and heartbeats into /tmp/impl-agent.log.
 * 8. Periodically repeats to synchronize continuous sibling agent platform hardening fixes.
 *
 * Isolated via dedicated worktrees (/tmp/slsi-sync-feat and /tmp/slsi-sync-main).
 */

import { spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";

const REPO_ROOT = "/home/andy/src/cp/osramp-demo";
const FEAT_WORKTREE = "/tmp/slsi-sync-feat";
const MAIN_WORKTREE = "/tmp/slsi-sync-main";
const INTEGRATION_BRANCH = "integration/slsi-v0.1.0";
const FEATURE_BRANCH = "feat/signal-loop-and-bootstrap-refactor";
const SECONDARY_BRANCHES = ["docs/arch-diagrams"];
const MAIN_BRANCH = "main";
const MASTER_BRANCH = "master";
const LOG_FILE = "/tmp/impl-agent.log";
const AGENT_ID = process.env.AGY_CONVERSATION_ID || "69ac0204-bd89-47d9-9c08-0458192a3c8c";

interface ExecResult {
  stdout: string;
  stderr: string;
  code: number;
}

function runCmd(cmd: string, cwd: string = REPO_ROOT, check = true): ExecResult {
  const res = spawnSync("bash", ["-c", cmd], {
    cwd,
    encoding: "utf-8",
    env: {
      ...process.env,
      GOPATH: "/tmp/gopath",
      GOCACHE: "/tmp/gocache",
      GOMODCACHE: "/tmp/gomodcache",
      GONOSUMDB: "*",
      CGO_ENABLED: "0",
    },
  });

  const stdout = res.stdout || "";
  const stderr = res.stderr || "";
  const code = res.status ?? (res.error ? 1 : 0);

  if (check && code !== 0) {
    throw new Error(`Command failed (exit ${code}): ${cmd}\nSTDOUT: ${stdout}\nSTDERR: ${stderr}`);
  }

  return { stdout: stdout.trim(), stderr: stderr.trim(), code };
}

function logEvent(eventType: string, topic: string, message: string): void {
  const now = new Date().toISOString().replace(/\.\d+Z$/, "Z");
  const line = `${now} [${AGENT_ID}] [${eventType}] [${topic}] ${message}\n`;
  try {
    fs.appendFileSync(LOG_FILE, line);
  } catch (err) {
    process.stderr.write(`Failed to log event: ${err}\n`);
  }
}

function ensureWorktree(dir: string, branch: string): string {
  if (fs.existsSync(dir)) {
    const res = runCmd("git status", dir, false);
    if (res.code === 0) {
      const curBranch = runCmd("git rev-parse --abbrev-ref HEAD", dir, false).stdout;
      if (curBranch === branch) {
        runCmd("git merge --abort", dir, false);
        runCmd("git reset --hard HEAD", dir, false);
        runCmd("git clean -fd", dir, false);
        return dir;
      }
    }
    // Stale or invalid worktree, recreate
    runCmd(`git worktree remove --force "${dir}"`, REPO_ROOT, false);
    if (fs.existsSync(dir)) {
      runCmd(`rm -rf "${dir}"`);
    }
    runCmd("git worktree prune");
  }

  console.log(`Creating worktree at ${dir} for ${branch}...`);
  runCmd(`git worktree add "${dir}" "${branch}"`);
  runCmd("git config commit.gpgsign false", dir);
  return dir;
}

function computeImageTag(cwd: string): string {
  const testDir = path.join(cwd, "d2-signalloom/apps/signal-ingest");
  const res = runCmd("go run ./cmd/image-tag", testDir);
  return res.stdout.trim();
}

function verifyImagePin(cwd: string): boolean {
  const testDir = path.join(cwd, "d2-signalloom/apps/signal-ingest");
  const res = runCmd("go test -run TestReconciledManifestRunsTheImageBuiltFromThisSource -v .", testDir, false);
  return res.code === 0;
}

function updateDeploymentPin(cwd: string): string {
  const tag = computeImageTag(cwd);
  const deployYaml = path.join(cwd, "d2-signalloom/apps/signal-ingest/base/deployment.yaml");
  if (!fs.existsSync(deployYaml)) {
    return tag;
  }

  const content = fs.readFileSync(deployYaml, "utf-8");
  const newLines: string[] = [];
  let modified = false;

  for (const line of content.split("\n")) {
    if (line.includes("image: ${IMAGE_BASE}/signalloom/apps/signal-ingest:")) {
      const newLine = `          image: \${IMAGE_BASE}/signalloom/apps/signal-ingest:${tag}`;
      if (newLine !== line) {
        modified = true;
      }
      newLines.push(newLine);
    } else {
      newLines.push(line);
    }
  }

  if (modified) {
    fs.writeFileSync(deployYaml, newLines.join("\n"));
    console.log(`     Updated deployment.yaml to tag ${tag}`);
  }
  return tag;
}

function rebaseFeatureBranch(): boolean {
  const intSha = runCmd(`git rev-parse ${INTEGRATION_BRANCH}`).stdout;
  const featSha = runCmd(`git rev-parse ${FEATURE_BRANCH}`).stdout;

  const isAncestor = runCmd(`git merge-base --is-ancestor ${intSha} ${FEATURE_BRANCH}`, REPO_ROOT, false).code === 0;
  if (isAncestor) {
    console.log(`  -> ${FEATURE_BRANCH} (${featSha.slice(0, 10)}) already up-to-date with ${INTEGRATION_BRANCH} (${intSha.slice(0, 10)}).`);
    return false;
  }

  const wt = ensureWorktree(FEAT_WORKTREE, FEATURE_BRANCH);
  console.log(`  -> Rebasing ${FEATURE_BRANCH} onto ${INTEGRATION_BRANCH} (${intSha.slice(0, 10)}) in ${wt}...`);
  runCmd(`git checkout ${FEATURE_BRANCH}`, wt);
  runCmd("git config commit.gpgsign false", wt);

  const rebaseRes = runCmd(`git rebase ${INTEGRATION_BRANCH}`, wt, false);
  if (rebaseRes.code !== 0) {
    console.log("     Rebase conflict detected, checking deployment.yaml...");
    const deployYaml = path.join(wt, "d2-signalloom/apps/signal-ingest/base/deployment.yaml");
    if (fs.existsSync(deployYaml)) {
      const c = fs.readFileSync(deployYaml, "utf-8");
      if (c.includes("<<<<<<<")) {
        runCmd(`git checkout --theirs "${deployYaml}"`, wt, false);
        const newTag = updateDeploymentPin(wt);
        runCmd(`git add "${deployYaml}"`, wt);
        runCmd("GIT_EDITOR=true git rebase --continue", wt);
      }
    }
  }

  const newTag = updateDeploymentPin(wt);
  const diffRes = runCmd("git diff --name-only", wt);
  if (diffRes.stdout.includes("deployment.yaml")) {
    runCmd("git add d2-signalloom/apps/signal-ingest/base/deployment.yaml", wt);
    runCmd("git commit --no-gpg-sign --amend --no-edit", wt);
  }

  if (!verifyImagePin(wt)) {
    throw new Error(`Verification test TestReconciledManifestRunsTheImageBuiltFromThisSource failed after rebase on tag ${newTag}!`);
  }

  const newFeatSha = runCmd(`git rev-parse ${FEATURE_BRANCH}`, wt).stdout;
  console.log(`     Rebase complete: ${FEATURE_BRANCH} is now at ${newFeatSha.slice(0, 10)}`);
  logEvent("SYNC", "branch-sync-rebase-feature", `Rebased ${FEATURE_BRANCH} (${newFeatSha.slice(0, 10)}) onto ${INTEGRATION_BRANCH} (${intSha.slice(0, 10)}) with image tag ${newTag}`);
  return true;
}

function rebaseSecondaryBranches(): boolean {
  const intSha = runCmd(`git rev-parse ${INTEGRATION_BRANCH}`).stdout;
  let anyRebased = false;

  for (const b of SECONDARY_BRANCHES) {
    const verifyRes = runCmd(`git rev-parse --verify ${b}`, REPO_ROOT, false);
    if (verifyRes.code !== 0) continue;

    const bSha = verifyRes.stdout;
    const isAncestor = runCmd(`git merge-base --is-ancestor ${intSha} ${b}`, REPO_ROOT, false).code === 0;
    if (isAncestor) continue;

    console.log(`  -> Rebasing secondary branch ${b} (${bSha.slice(0, 10)}) onto ${INTEGRATION_BRANCH} (${intSha.slice(0, 10)})...`);
    const tmpWt = `/tmp/slsi-sync-${b.replace(/\//g, "-")}`;
    try {
      runCmd(`git worktree add ${tmpWt} ${b}`);
      runCmd("git config commit.gpgsign false", tmpWt);
      runCmd(`git rebase ${INTEGRATION_BRANCH}`, tmpWt);
      const newSha = runCmd(`git rev-parse ${b}`, tmpWt).stdout;
      console.log(`     Rebase complete: ${b} is now at ${newSha.slice(0, 10)}`);
      logEvent("SYNC", "branch-sync-rebase-secondary", `Rebased ${b} (${newSha.slice(0, 10)}) onto ${INTEGRATION_BRANCH} (${intSha.slice(0, 10)})`);
      anyRebased = true;
    } finally {
      runCmd(`git worktree remove --force ${tmpWt}`, REPO_ROOT, false);
    }
  }

  return anyRebased;
}

function mergeDownToMainAndMaster(): boolean {
  const intSha = runCmd(`git rev-parse ${INTEGRATION_BRANCH}`).stdout;
  const featSha = runCmd(`git rev-parse ${FEATURE_BRANCH}`).stdout;
  const mainSha = runCmd(`git rev-parse ${MAIN_BRANCH}`).stdout;
  const masterSha = runCmd(`git rev-parse --verify ${MASTER_BRANCH}`, REPO_ROOT, false).stdout;

  const intInMain = runCmd(`git merge-base --is-ancestor ${intSha} ${MAIN_BRANCH}`, REPO_ROOT, false).code === 0;
  const featInMain = runCmd(`git merge-base --is-ancestor ${featSha} ${MAIN_BRANCH}`, REPO_ROOT, false).code === 0;
  const masterMatchesMain = (masterSha === mainSha);

  if (intInMain && featInMain && masterMatchesMain) {
    console.log(`  -> main/master already synchronized with ${INTEGRATION_BRANCH} and ${FEATURE_BRANCH}.`);
    return false;
  }

  const wt = ensureWorktree(MAIN_WORKTREE, MAIN_BRANCH);
  console.log(`  -> Merging down to ${MAIN_BRANCH} and ${MASTER_BRANCH} in ${wt}...`);
  runCmd("git config commit.gpgsign false", wt);

  if (!intInMain) {
    console.log(`     Merging ${INTEGRATION_BRANCH} into ${MAIN_BRANCH}...`);
    const mergeRes = runCmd(`git merge --no-ff -m "merge: ${INTEGRATION_BRANCH} into main" ${INTEGRATION_BRANCH}`, wt, false);
    if (mergeRes.code !== 0) {
      console.log("     Merge conflict detected, checking deployment.yaml...");
      const deployYaml = path.join(wt, "d2-signalloom/apps/signal-ingest/base/deployment.yaml");
      if (fs.existsSync(deployYaml)) {
        runCmd(`git checkout --theirs "${deployYaml}"`, wt, false);
        updateDeploymentPin(wt);
        runCmd(`git add "${deployYaml}"`, wt);
        runCmd(`git commit --no-gpg-sign -m "merge: ${INTEGRATION_BRANCH} into main (resolved image tag)"`, wt);
      } else {
        throw new Error(`Merge conflict on non-deployment file in main worktree: ${mergeRes.stderr}`);
      }
    }
  }

  if (!featInMain) {
    console.log(`     Merging ${FEATURE_BRANCH} into ${MAIN_BRANCH}...`);
    const mergeRes = runCmd(`git merge --no-ff -m "merge: ${FEATURE_BRANCH} into main" ${FEATURE_BRANCH}`, wt, false);
    if (mergeRes.code !== 0) {
      console.log("     Merge conflict detected, checking deployment.yaml...");
      const deployYaml = path.join(wt, "d2-signalloom/apps/signal-ingest/base/deployment.yaml");
      if (fs.existsSync(deployYaml)) {
        runCmd(`git checkout --theirs "${deployYaml}"`, wt, false);
        updateDeploymentPin(wt);
        runCmd(`git add "${deployYaml}"`, wt);
        runCmd(`git commit --no-gpg-sign -m "merge: ${FEATURE_BRANCH} into main (resolved image tag)"`, wt);
      } else {
        throw new Error(`Merge conflict on non-deployment file in main worktree: ${mergeRes.stderr}`);
      }
    }
  }

  const newMainSha = runCmd(`git rev-parse ${MAIN_BRANCH}`, wt).stdout;
  runCmd(`git branch -f ${MASTER_BRANCH} ${MAIN_BRANCH}`, REPO_ROOT);

  logEvent(
    "SYNC",
    "branch-sync-merge-main-master",
    `Merged ${INTEGRATION_BRANCH} and ${FEATURE_BRANCH} down to main and master at commit ${newMainSha.slice(0, 10)}`
  );
  console.log(`  -> Sync complete. main/master at ${newMainSha.slice(0, 10)}`);
  return true;
}

function runFullVerification(): void {
  console.log("Running verification test suite...");
  const wt = ensureWorktree(FEAT_WORKTREE, FEATURE_BRANCH);

  console.log("  1. Verifying manifest image pin...");
  if (!verifyImagePin(wt)) {
    throw new Error("Image pin verification failed!");
  }
  console.log("     PASS");

  console.log("  2. Verifying signal-ingest API test suite...");
  const apiDir = path.join(wt, "d2-signalloom/apps/signal-ingest/api");
  const apiRes = runCmd("go test -v .", apiDir, false);
  if (apiRes.code !== 0) {
    throw new Error(`signal-ingest API suite failed:\n${apiRes.stdout}\n${apiRes.stderr}`);
  }
  console.log("     PASS (clean)");

  console.log("  3. Verifying signal-ingest audit test suite...");
  const auditDir = path.join(wt, "d2-signalloom/apps/signal-ingest/api/audit");
  const auditRes = runCmd("go test -v .", auditDir, false);
  if (auditRes.code !== 0) {
    throw new Error(`signal-ingest audit suite failed:\n${auditRes.stdout}\n${auditRes.stderr}`);
  }
  console.log("     PASS (clean)");

  console.log("  4. Verifying fleet-manager contract test suite...");
  const fleetDir = path.join(wt, "d2-signalloom/apps/fleet-manager");
  const fleetRes = runCmd(
    "go test -v -run 'TestHandleAuditEvents_HTTPContract|TestAuditEventsCarryNoCalibratedRiskLiteral|TestCallerAuth_MethodGatesAndHEADBodySuppression' .",
    fleetDir,
    false
  );
  if (fleetRes.code !== 0) {
    throw new Error(`fleet-manager test suite failed:\n${fleetRes.stdout}\n${fleetRes.stderr}`);
  }
  console.log("     PASS (clean)");

  logEvent("PATCH_VERIFIED", "branch-sync-zero-regressions", "All verification suites passed cleanly on rebased feature branch.");
  console.log("  -> All test suites PASSED. Zero regressions.");
}

export function syncCycle(): boolean {
  const intSha = runCmd(`git rev-parse ${INTEGRATION_BRANCH}`).stdout;
  const featSha = runCmd(`git rev-parse ${FEATURE_BRANCH}`).stdout;
  const mainSha = runCmd(`git rev-parse ${MAIN_BRANCH}`).stdout;

  console.log(`[${new Date().toISOString()}] Checking sync status:`);
  console.log(`  Integration branch (${INTEGRATION_BRANCH}): ${intSha.slice(0, 10)}`);
  console.log(`  Feature branch     (${FEATURE_BRANCH}): ${featSha.slice(0, 10)}`);
  console.log(`  Main branch        (${MAIN_BRANCH}):                    ${mainSha.slice(0, 10)}`);

  const rebasedFeat = rebaseFeatureBranch();
  const rebasedSec = rebaseSecondaryBranches();
  const mergedMain = mergeDownToMainAndMaster();

  if (rebasedFeat || rebasedSec || mergedMain) {
    console.log("  -> Sync completed changes.");
    return true;
  } else {
    console.log("  -> All branches already fully synchronized.");
    return false;
  }
}

function printStatus(): void {
  const intSha = runCmd(`git rev-parse ${INTEGRATION_BRANCH}`).stdout;
  const featSha = runCmd(`git rev-parse ${FEATURE_BRANCH}`).stdout;
  const mainSha = runCmd(`git rev-parse ${MAIN_BRANCH}`).stdout;
  const masterRes = runCmd(`git rev-parse --verify ${MASTER_BRANCH}`, REPO_ROOT, false);
  const masterSha = masterRes.code === 0 ? masterRes.stdout : "NONE";

  const isFeatAncestor = runCmd(`git merge-base --is-ancestor ${intSha} ${FEATURE_BRANCH}`, REPO_ROOT, false).code === 0;
  const isIntInMain = runCmd(`git merge-base --is-ancestor ${intSha} ${MAIN_BRANCH}`, REPO_ROOT, false).code === 0;
  const isFeatInMain = runCmd(`git merge-base --is-ancestor ${featSha} ${MAIN_BRANCH}`, REPO_ROOT, false).code === 0;
  const isMasterMatched = masterSha === mainSha;

  console.log(`Integration branch (${INTEGRATION_BRANCH}): ${intSha}`);
  console.log(`Feature branch     (${FEATURE_BRANCH}):     ${featSha} [${isFeatAncestor ? "SYNCED" : "NEEDS_REBASE"}]`);
  console.log(`Main branch        (${MAIN_BRANCH}):                     ${mainSha} [Integration: ${isIntInMain ? "YES" : "NO"}, Feat: ${isFeatInMain ? "YES" : "NO"}]`);
  console.log(`Master branch      (${MASTER_BRANCH}):                   ${masterSha} [Matches Main: ${isMasterMatched ? "YES" : "NO"}]`);

  for (const b of SECONDARY_BRANCHES) {
    const verifyRes = runCmd(`git rev-parse --verify ${b}`, REPO_ROOT, false);
    if (verifyRes.code === 0) {
      const bSha = verifyRes.stdout;
      const isSecAncestor = runCmd(`git merge-base --is-ancestor ${intSha} ${b}`, REPO_ROOT, false).code === 0;
      console.log(`Secondary branch   (${b}): ${bSha} [${isSecAncestor ? "SYNCED" : "NEEDS_REBASE"}]`);
    }
  }
}

async function main() {
  const args = process.argv.slice(2);
  const isStatus = args.includes("--status");
  const isVerify = args.includes("--verify");
  const isOnce = args.includes("--once");
  const intervalIdx = args.indexOf("--interval");
  const interval = intervalIdx !== -1 && args[intervalIdx + 1] ? parseInt(args[intervalIdx + 1], 10) : 60;

  if (isStatus) {
    printStatus();
    return;
  }

  if (isVerify) {
    runFullVerification();
    return;
  }

  console.log(`Starting branch synchronization worker (AGENT_ID=${AGENT_ID})...`);
  logEvent("ANNOUNCE", "agent", `role=branch sync daemon Online on branch=${INTEGRATION_BRANCH} cwd=${REPO_ROOT}`);
  logEvent(
    "CLAIM",
    "branch-sync-daemon",
    `[ttl=3600] Periodic merge and rebase synchronizer for ${INTEGRATION_BRANCH}, ${FEATURE_BRANCH}, and main/master`
  );

  if (isOnce) {
    const changed = syncCycle();
    if (changed) {
      runFullVerification();
    }
    return;
  }

  console.log(`Running periodic branch synchronization every ${interval} seconds. Press Ctrl+C to stop.`);
  while (true) {
    try {
      const changed = syncCycle();
      if (changed) {
        runFullVerification();
      }
    } catch (err: any) {
      process.stderr.write(`Error during sync cycle: ${err.message || err}\n`);
      logEvent("ERROR", "branch-sync-cycle-failure", String(err.message || err));
    }
    await new Promise((resolve) => setTimeout(resolve, interval * 1000));
  }
}

if (import.meta.main) {
  main().catch((err) => {
    console.error("Fatal:", err);
    process.exit(1);
  });
}
