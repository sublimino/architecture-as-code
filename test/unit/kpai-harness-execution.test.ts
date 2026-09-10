/**
 * kpai-harness-execution.test.ts — behavioural test over the probe script itself.
 *
 * Subject: `scripts/test-kpai-harness.sh`.
 *
 * Where the contract test asserts the artifact's shape, this file asserts that the
 * generator BEHAVES: that every invocation mode works, that the canary derivation
 * is deterministic and independently reproducible, that the probe tally is honest,
 * and that a run leaves no residue in the worktree.
 *
 * The canary assertions are the load-bearing ones. "Deterministic" is tested two
 * ways that fail independently:
 *   1. repeatability — two runs into different directories produce identical bytes;
 *   2. derivation    — the recorded digest equals a SHA-256 this file computes
 *                      itself from the documented seed.
 * Repeatability alone would be satisfied by a hard-coded constant. Only the second
 * assertion proves the digest is actually derived from HEAD.
 *
 * Run: bun test test/unit/kpai-harness-execution.test.ts
 *
 * @id     kpai-harness-execution-test
 * @target scripts/test-kpai-harness.sh
 * @doc    docs/kpai-harness-verification.md
 * @task   KTEST-P1-1
 */

import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const REPO_ROOT = resolve(import.meta.dir, "..", "..");
const SCRIPT_PATH = resolve(REPO_ROOT, "scripts", "test-kpai-harness.sh");
const CANARY_BASENAME = "kpai-harness.canary";
const SHA256_RE = /^[0-9a-f]{64}$/;

const scratchDirs: string[] = [];

function scratch(prefix: string): string {
  const d = mkdtempSync(join(tmpdir(), prefix));
  scratchDirs.push(d);
  return d;
}

afterAll(() => {
  for (const d of scratchDirs) {
    rmSync(d, { recursive: true, force: true });
  }
});

interface RunResult {
  code: number;
  stdout: string;
  stderr: string;
}

function run(args: string[]): RunResult {
  const proc = Bun.spawnSync({
    cmd: ["bash", SCRIPT_PATH, ...args],
    cwd: REPO_ROOT,
    env: { ...process.env, KPAI_ALLOW_PRINCIPAL: "1" },
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    code: proc.exitCode ?? -1,
    stdout: new TextDecoder().decode(proc.stdout),
    stderr: new TextDecoder().decode(proc.stderr),
  };
}

function git(args: string[]): string {
  const proc = Bun.spawnSync({
    cmd: ["git", ...args],
    cwd: REPO_ROOT,
    stdout: "pipe",
    stderr: "pipe",
  });
  return new TextDecoder().decode(proc.stdout);
}

const SCRIPT_SOURCE = existsSync(SCRIPT_PATH) ? readFileSync(SCRIPT_PATH, "utf8") : "";

describe("script presence and static shape", () => {
  test("ISC-26a: the script exists", () => {
    expect(existsSync(SCRIPT_PATH)).toBe(true);
  });

  test("ISC-26b: the script is executable by its owner", () => {
    // eslint-disable-next-line no-bitwise
    expect(statSync(SCRIPT_PATH).mode & 0o100).toBe(0o100);
  });

  test("ISC-27: bash -n exits 0 AND emits nothing on stderr", () => {
    // Exit status alone is insufficient. An unterminated heredoc is the one
    // syntax fault bash -n downgrades to a stderr warning while still exiting 0,
    // so asserting only the code would pass a script that cannot run.
    const proc = Bun.spawnSync({
      cmd: ["bash", "-n", SCRIPT_PATH],
      cwd: REPO_ROOT,
      stdout: "pipe",
      stderr: "pipe",
    });
    const stderr = new TextDecoder().decode(proc.stderr);
    expect(proc.exitCode).toBe(0);
    expect(stderr).toBe("");
  });

  test("ISC-33: the script does not enable errexit", () => {
    // Constraint C5. Errexit would abort at the first failing probe, so the suite
    // would report a verdict about the whole from having measured a prefix.
    const offenders = SCRIPT_SOURCE.split("\n")
      .map((line, i) => ({ line: line.trim(), n: i + 1 }))
      .filter(
        ({ line }) =>
          !line.startsWith("#") &&
          (/^set\s+-[a-z]*e[a-z]*(\s|$)/.test(line) || /^set\s+-o\s+errexit\b/.test(line)),
      );
    expect(offenders.map((o) => `line ${o.n}: ${o.line}`)).toEqual([]);
  });

  test("ISC-34: the script never uses grep -q inside a pipeline", () => {
    // Constraint C6. Under pipefail, grep -q exits on match and the upstream
    // writer takes SIGPIPE, inverting the condition precisely when it is true.
    const offenders = SCRIPT_SOURCE.split("\n")
      .map((line, i) => ({ line: line.trim(), n: i + 1 }))
      .filter(({ line }) => !line.startsWith("#") && /\|\s*grep\s+(-\w*\s+)*-\w*q/.test(line));
    expect(offenders.map((o) => `line ${o.n}: ${o.line}`)).toEqual([]);
  });

  test("the script declares its probe count as a named constant", () => {
    expect(SCRIPT_SOURCE).toMatch(/readonly DECLARED_PROBES=\d+/);
  });
});

describe("invocation modes", () => {
  test("ISC-28: the bare invocation — no arguments at all — exits 0", () => {
    // The production invocation is a test case. A suite whose every check passes
    // a flag never exercises the zero-argument path, which is exactly where an
    // argument-parser bug lives.
    const r = run([]);
    expect(r.code).toBe(0);
  });

  test("ISC-29: --help exits 0 and prints a usage line naming the script", () => {
    const r = run(["--help"]);
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("test-kpai-harness.sh");
    expect(r.stdout).toContain("Usage:");
  });

  test("ISC-32: an unrecognised option exits non-zero and names it on stderr", () => {
    const r = run(["--definitely-not-a-real-flag"]);
    expect(r.code).toBe(2);
    expect(r.stderr).toContain("--definitely-not-a-real-flag");
  });

  test("--emit without a path argument is a usage error, not a crash", () => {
    const r = run(["--emit"]);
    expect(r.code).toBe(2);
    expect(r.stderr).toContain("--emit requires a path");
  });

  test("ISC-35: the tally line reports declared == executed and all passing", () => {
    const r = run(["--quiet"]);
    expect(r.code).toBe(0);
    const m = r.stdout.match(/probes: (\d+)\/(\d+) passed \(declared (\d+), executed (\d+)\)/);
    expect(m).not.toBeNull();
    const [, passed, total, declared, executed] = m as RegExpMatchArray;
    expect(executed).toBe(declared);
    expect(total).toBe(executed);
    expect(passed).toBe(total);
    expect(Number(declared)).toBeGreaterThan(0);
  });

  test("--quiet suppresses the per-probe transcript but keeps the tally", () => {
    const quiet = run(["--quiet"]);
    const loud = run([]);
    expect(quiet.stdout).not.toContain("[PASS]");
    expect(loud.stdout).toContain("[PASS]");
    expect(quiet.stdout).toContain("probes:");
  });
});

describe("ISC-30: --emit writes a well-formed artifact", () => {
  test("the emitted file parses and reports zero failures", () => {
    const dir = scratch("kpai-emit-");
    const out = join(dir, "artifact.json");
    const r = run(["--quiet", "--emit", out]);
    expect(r.code).toBe(0);
    expect(existsSync(out)).toBe(true);
    const parsed = JSON.parse(readFileSync(out, "utf8"));
    expect(parsed.schema).toBe("kpai-harness-verification/v1");
    expect(parsed.summary.failed).toBe(0);
    expect(parsed.summary.total).toBe(parsed.checks.length);
  });

  test("--emit to an unwritable path fails loudly rather than exiting 0", () => {
    const r = run(["--quiet", "--emit", "/proc/definitely/not/writable/artifact.json"]);
    expect(r.code).not.toBe(0);
    expect(r.stderr).toContain("failed to write artifact");
  });
});

describe("ISC-31 / ISC-50: canary generation", () => {
  test("--canary-dir writes the canary into the supplied directory", () => {
    const dir = scratch("kpai-canary-a-");
    const r = run(["--quiet", "--canary-dir", dir]);
    expect(r.code).toBe(0);
    expect(existsSync(join(dir, CANARY_BASENAME))).toBe(true);
  });

  test("the canary is the only file left behind in the canary directory", () => {
    // The intermediate `.2` comparison file and the `.seed` file are both removed;
    // a leftover would mean a cleanup path did not run.
    const dir = scratch("kpai-canary-solo-");
    run(["--quiet", "--canary-dir", dir]);
    const entries = [...new Bun.Glob("*").scanSync({ cwd: dir, onlyFiles: false })];
    expect(entries.sort()).toEqual([CANARY_BASENAME]);
  });

  test("ISC-50: two runs into different directories produce byte-identical canaries", () => {
    const a = scratch("kpai-det-a-");
    const b = scratch("kpai-det-b-");
    expect(run(["--quiet", "--canary-dir", a]).code).toBe(0);
    expect(run(["--quiet", "--canary-dir", b]).code).toBe(0);
    const ca = readFileSync(join(a, CANARY_BASENAME));
    const cb = readFileSync(join(b, CANARY_BASENAME));
    expect(Buffer.compare(ca, cb)).toBe(0);
  });

  test("the canary carries the documented four-line shape", () => {
    const dir = scratch("kpai-shape-");
    run(["--quiet", "--canary-dir", dir]);
    const lines = readFileSync(join(dir, CANARY_BASENAME), "utf8").trimEnd().split("\n");
    expect(lines.length).toBe(4);
    expect(lines[0]).toBe("kpai-harness-canary/v1");
    expect(lines[1]).toBe("task=KTEST-P1-1");
    expect(lines[2]).toMatch(/^head=[0-9a-f]{40}$/);
    expect(lines[3]).toMatch(/^digest=[0-9a-f]{64}$/);
  });

  test("ISC-52: the digest is genuinely derived from HEAD, not a constant", () => {
    // Repeatability alone would be satisfied by a hard-coded string. Recomputing
    // the SHA-256 from the documented seed is what makes this assertion live:
    // change the derivation in the script and this test turns red immediately.
    const dir = scratch("kpai-derive-");
    run(["--quiet", "--canary-dir", dir]);
    const content = readFileSync(join(dir, CANARY_BASENAME), "utf8");
    const head = content.match(/^head=([0-9a-f]{40})$/m)?.[1];
    const digest = content.match(/^digest=([0-9a-f]{64})$/m)?.[1];
    expect(head).toBeDefined();
    expect(digest).toMatch(SHA256_RE);

    const expected = new Bun.CryptoHasher("sha256")
      .update(`kpai-harness-canary|v1|${head}`)
      .digest("hex");
    expect(digest).toBe(expected);
  });

  test("the canary head matches the worktree's actual HEAD", () => {
    const dir = scratch("kpai-head-");
    run(["--quiet", "--canary-dir", dir]);
    const content = readFileSync(join(dir, CANARY_BASENAME), "utf8");
    const head = content.match(/^head=([0-9a-f]{40})$/m)?.[1];
    expect(head).toBe(git(["rev-parse", "HEAD"]).trim());
  });
});

describe("ISC-59: the run leaves no residue in the worktree", () => {
  test("git status is byte-identical before and after a full run", () => {
    const before = git(["status", "--porcelain"]);
    const r = run(["--quiet"]);
    const after = git(["status", "--porcelain"]);
    expect(r.code).toBe(0);
    expect(after).toBe(before);
  });

  test("the transient write-probe file does not survive the run", () => {
    run(["--quiet"]);
    const leftovers = [...new Bun.Glob(".kpai-write-probe.*").scanSync({ cwd: REPO_ROOT, dot: true })];
    expect(leftovers).toEqual([]);
  });
});

describe("sibling-suite arity", () => {
  // A test file that fails to load -- a syntax error, a bad import, a committed
  // conflict marker -- drops its tests out of the tally silently while the runner
  // still exits 0. A check that never ran is indistinguishable from a check that
  // passed. This asserts the contract suite's arity from outside it.
  //
  // Known asymmetry, stated rather than hidden: nothing outside THIS file guards
  // THIS file's arity, because a mutual guard would recurse. The script's own
  // DECLARED_PROBES tally covers the probe layer; the execution suite's arity is
  // the one uncovered link, and is checked by hand at review time.
  const CONTRACT_MIN_TESTS = 50;

  test(`the contract suite loads and reports at least ${CONTRACT_MIN_TESTS} passing tests`, () => {
    const proc = Bun.spawnSync({
      cmd: ["bun", "test", "test/unit/kpai-harness-contract.test.ts"],
      cwd: REPO_ROOT,
      stdout: "pipe",
      stderr: "pipe",
    });
    // bun writes its summary to stderr; read both so a format change cannot make
    // this assertion silently unfindable.
    const out =
      new TextDecoder().decode(proc.stdout) + new TextDecoder().decode(proc.stderr);
    const pass = Number(out.match(/^\s*(\d+) pass$/m)?.[1] ?? -1);
    const fail = Number(out.match(/^\s*(\d+) fail$/m)?.[1] ?? -1);
    expect(proc.exitCode).toBe(0);
    expect(fail).toBe(0);
    expect(pass).toBeGreaterThanOrEqual(CONTRACT_MIN_TESTS);
  });
});
