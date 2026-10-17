// Offline inventory for sl-upgrade-scan: every pinned version in the tree,
// with the exact file:line to change. No network.

import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { basename, dirname, join, relative } from "node:path";

export type Ecosystem =
  | "oci-image"
  | "oci-artifact"
  | "go-module"
  | "runtime"
  | "pypi"
  | "npm"
  | "github-action"
  | "tool-pin";

export interface Location {
  file: string;
  line: number;
}

export interface Item {
  ecosystem: Ecosystem;
  name: string;
  current: string;
  locations: Location[];
  notes: string[];
  digest?: string;
  /** Built from this repo (or an org registry): there is no upstream to bump to. */
  firstParty?: boolean;
}

// Org registries and local-build tags. A docker.io/library/<x> image whose
// <x> is a directory holding a Dockerfile in this repo is a local build too.
export const FIRST_PARTY: RegExp[] = [
  /^zot\.registry\.svc/,
  /^ghcr\.io\/controlplaneio-in-toto\//,
  /^localhost[:/]/,
  /^kind-registry[:/]/,
];
export const LOCAL_TAGS = new Set(["local", "dev"]);

export interface InventoryOptions {
  includeIndirect?: boolean;
  /** Extra path regexes to skip. */
  exclude?: RegExp[];
  /** Replace the default exclusions. */
  noDefaultExcludes?: boolean;
}

// Fixtures, prose and vendored trees never deploy; a pin there is not ours to bump.
export const DEFAULT_EXCLUDES: RegExp[] = [
  /(^|\/)node_modules\//,
  /(^|\/)vendor\//,
  /(^|\/)\.git\//,
  /(^|\/)testdata\//,
  /^test\/fixtures\//,
  /(^|\/)test_helper\//,
  /^docs\//,
  /^MEMORY\//,
  /^Plans\//,
  /(^|\/)\.claude\/worktrees\//,
];

function listFiles(root: string): string[] {
  if (existsSync(join(root, ".git"))) {
    try {
      const out = execFileSync("git", ["-C", root, "ls-files", "-z"], { maxBuffer: 64 << 20 }).toString();
      return out.split("\0").filter(Boolean);
    } catch {
      // fall through to a walk
    }
  }
  const files: string[] = [];
  const walk = (dir: string) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      if (e.name === ".git" || e.name === "node_modules") continue;
      const p = join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.isFile()) files.push(relative(root, p));
    }
  };
  walk(root);
  return files.sort();
}

// --- image references ------------------------------------------------------

export interface ImageRef {
  name: string; // canonical: registry/path
  tag: string | null;
  digest: string | null;
}

export function parseImageRef(ref: string): ImageRef | null {
  let r = ref.trim().replace(/^["']|["']$/g, "");
  if (!r || /[${}<>\s]/.test(r)) return null; // templated: never guess
  let digest: string | null = null;
  const at = r.indexOf("@");
  if (at >= 0) {
    digest = r.slice(at + 1);
    r = r.slice(0, at);
  }
  let tag: string | null = null;
  const lastSlash = r.lastIndexOf("/");
  const colon = r.lastIndexOf(":");
  if (colon > lastSlash) {
    tag = r.slice(colon + 1);
    r = r.slice(0, colon);
  }
  if (!/^[a-z0-9]/.test(r)) return null;
  const parts = r.split("/");
  const hasRegistry = parts.length > 1 && /[.:]|^localhost$/.test(parts[0]);
  let name = r;
  if (!hasRegistry) name = parts.length === 1 ? `docker.io/library/${r}` : `docker.io/${r}`;
  return { name: name.toLowerCase(), tag, digest };
}

// --- per-format extractors -------------------------------------------------

type Emit = (it: Omit<Item, "locations" | "notes"> & { notes?: string[] }, line: number) => void;

function emitImage(emit: Emit, ref: string, line: number, eco: Ecosystem = "oci-image") {
  const p = parseImageRef(ref);
  if (!p) return;
  const current = p.tag ?? (p.digest ? `@${p.digest.slice(0, 19)}` : "latest");
  const notes: string[] = [];
  if (!p.tag && !p.digest) notes.push("no tag: resolves to latest");
  emit({ ecosystem: eco, name: p.name, current, digest: p.digest ?? undefined, notes }, line);
}

function yamlFile(lines: string[], emit: Emit) {
  let inImages = false;
  let kzName: string | null = null;
  let kzNewName: string | null = null;
  let ociRepo = false;
  let ociUrl: string | null = null;
  let helmRepo: { name: string; indent: number; line: number } | null = null;
  let watchOnly = false; // Flux ImageRepository: names an image to watch, pins nothing
  lines.forEach((raw, i) => {
    const n = i + 1;
    const line = raw.replace(/\s+#.*$/, "");
    if (/^\s*#/.test(raw)) return;
    if (/^kind:/.test(line)) {
      ociRepo = /^kind:\s*OCIRepository\b/.test(line);
      watchOnly = /^kind:\s*ImageRepository\b/.test(line);
    }
    if (/^---/.test(line)) {
      ociRepo = false;
      watchOnly = false;
      ociUrl = null;
    }
    // image: ref
    const im = /^\s*-?\s*image:\s*(["']?[^\s"']+["']?)\s*$/.exec(line);
    if (im && !watchOnly) emitImage(emit, im[1], n);
    // Helm values: repository: x / tag: y at the same indent
    const rp = /^(\s*)repository:\s*["']?([^\s"']+)["']?\s*$/.exec(line);
    if (rp && /[./]/.test(rp[2]) && !/^https?:/.test(rp[2])) helmRepo = { name: rp[2], indent: rp[1].length, line: n };
    const tg = /^(\s*)tag:\s*["']?([^\s"']+)["']?\s*$/.exec(line);
    if (tg && helmRepo && tg[1].length === helmRepo.indent && n - helmRepo.line <= 3) {
      emitImage(emit, `${helmRepo.name}:${tg[2]}`, n);
      helmRepo = null;
    }
    // Flux OCIRepository
    if (ociRepo) {
      const u = /^\s*url:\s*["']?oci:\/\/([^\s"']+)["']?/.exec(line);
      if (u) ociUrl = u[1];
      if (tg && ociUrl) emitImage(emit, `${ociUrl}:${tg[2]}`, n, "oci-artifact");
    }
    // Kustomize images:
    if (/^images:\s*$/.test(line)) {
      inImages = true;
      return;
    }
    if (inImages && /^\S/.test(line)) inImages = false;
    if (inImages) {
      const nm = /^\s*-\s*name:\s*["']?([^\s"']+)/.exec(line);
      if (nm) {
        kzName = nm[1];
        kzNewName = null;
      }
      const nn = /^\s*newName:\s*["']?([^\s"']+)/.exec(line);
      if (nn) kzNewName = nn[1];
      const nt = /^\s*newTag:\s*["']?([^\s"']+)/.exec(line);
      if (nt && kzName) emitImage(emit, `${kzNewName ?? kzName}:${nt[1]}`, n);
    }
  });
}

function dockerfile(lines: string[], emit: Emit) {
  const stages = new Set<string>();
  lines.forEach((line, i) => {
    const m = /^\s*FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?/i.exec(line);
    if (!m) return;
    const ref = m[1];
    if (m[2]) stages.add(m[2].toLowerCase());
    if (ref === "scratch" || stages.has(ref.toLowerCase()) && !ref.includes(":") && !ref.includes("/")) return;
    emitImage(emit, ref, i + 1);
  });
}

function goMod(lines: string[], emit: Emit, includeIndirect: boolean) {
  let block = false;
  lines.forEach((line, i) => {
    const n = i + 1;
    const g = /^go\s+(\d+\.\d+(?:\.\d+)?)\s*$/.exec(line);
    if (g) emit({ ecosystem: "runtime", name: "go", current: g[1], notes: ["go.mod go directive"] }, n);
    const t = /^toolchain\s+go(\d+\.\d+(?:\.\d+)?)\s*$/.exec(line);
    if (t) emit({ ecosystem: "runtime", name: "go", current: t[1], notes: ["go.mod toolchain"] }, n);
    if (/^require\s*\(\s*$/.test(line)) {
      block = true;
      return;
    }
    if (block && /^\)\s*$/.test(line)) {
      block = false;
      return;
    }
    const m = block ? /^\s+(\S+)\s+(v\S+)(.*)$/.exec(line) : /^require\s+(\S+)\s+(v\S+)(.*)$/.exec(line);
    if (!m) return;
    const indirect = /\/\/\s*indirect/.test(m[3]);
    if (indirect && !includeIndirect) return;
    emit({ ecosystem: "go-module", name: m[1], current: m[2], notes: indirect ? ["indirect"] : [] }, n);
  });
}

function requirements(lines: string[], emit: Emit) {
  lines.forEach((line, i) => {
    const l = line.replace(/#.*$/, "").trim();
    if (!l || l.startsWith("-")) return;
    const m = /^([A-Za-z0-9_.\-]+)(?:\[[^\]]*\])?\s*(==|>=|~=|<=|>|<)?\s*([0-9][^\s;,]*)?/.exec(l);
    if (!m) return;
    const name = m[1].toLowerCase();
    if (m[2] === "==" && m[3]) emit({ ecosystem: "pypi", name, current: m[3] }, i + 1);
    else emit({ ecosystem: "pypi", name, current: m[3] ?? "*", notes: [`not pinned (${m[2] ?? "any"}${m[3] ?? ""})`] }, i + 1);
  });
}

function lockVersions(dir: string, root: string): Map<string, string> {
  const out = new Map<string, string>();
  const pl = join(root, dir, "package-lock.json");
  if (existsSync(pl)) {
    try {
      const j = JSON.parse(readFileSync(pl, "utf8"));
      for (const [k, v] of Object.entries<{ version?: string }>(j.packages ?? {})) {
        const m = /^node_modules\/((?:@[^/]+\/)?[^/]+)$/.exec(k);
        if (m && v.version) out.set(m[1], v.version);
      }
    } catch {
      // unparsable lockfile: leave unresolved
    }
  }
  const bl = join(root, dir, "bun.lock");
  if (existsSync(bl)) {
    const text = readFileSync(bl, "utf8");
    const re = /^\s*"((?:@[^/"]+\/)?[^"/]+)":\s*\[\s*"((?:@[^/"]+\/)?[^"@]+)@([^"]+)"/gm;
    for (let m = re.exec(text); m; m = re.exec(text)) if (!out.has(m[1])) out.set(m[1], m[3]);
  }
  return out;
}

function packageJson(rel: string, root: string, lines: string[], emit: Emit) {
  let pkg: Record<string, Record<string, string>>;
  try {
    pkg = JSON.parse(lines.join("\n"));
  } catch {
    return;
  }
  const locks = lockVersions(dirname(rel), root);
  for (const section of ["dependencies", "devDependencies", "optionalDependencies"]) {
    for (const [name, spec] of Object.entries(pkg[section] ?? {})) {
      if (typeof spec !== "string" || /^(file|link|workspace|git|https?):/.test(spec)) continue;
      const idx = lines.findIndex((l) => l.includes(`"${name}":`));
      const resolved = locks.get(name);
      const notes = [`spec ${spec}`];
      if (!resolved) notes.push("not resolved from a lockfile");
      emit({ ecosystem: "npm", name, current: resolved ?? spec.replace(/^[\^~=>< ]+/, ""), notes }, idx + 1);
    }
  }
}

function workflow(lines: string[], emit: Emit) {
  lines.forEach((line, i) => {
    if (/^\s*#/.test(line)) return;
    const m = /^\s*-?\s*uses:\s*["']?([^\s"'@]+)@([^\s"'#]+)["']?\s*(?:#\s*(\S+))?/.exec(line);
    if (!m) return;
    const [, path, ref, comment] = m;
    if (path.startsWith("./") || path.startsWith("docker://")) return;
    const name = path.split("/").slice(0, 2).join("/");
    const sha = /^[0-9a-f]{40}$/.test(ref);
    const notes: string[] = [];
    if (path !== name) notes.push(`path ${path}`);
    if (sha) notes.push(`pinned to ${ref.slice(0, 12)}`);
    if (sha && !comment) notes.push("SHA pin with no version comment");
    emit({ ecosystem: "github-action", name, current: sha ? (comment ?? ref) : ref, notes }, i + 1);
  });
}

const TOOL_RE =
  /^\s*(?:export\s+)?(?:PIN_)?([A-Z][A-Z0-9_]*?)_VERSION\s*[?:]?=\s*["']?(?:\$\{[A-Z0-9_]+:-)?(v?[0-9][^"'}\s#]*)/;
// Runtime probes, not pins.
const NOT_TOOLS = new Set(["zsh", "bash", "slsi"]);

function toolPins(lines: string[], emit: Emit) {
  lines.forEach((line, i) => {
    const m = TOOL_RE.exec(line);
    if (!m) return;
    const name = m[1].toLowerCase().replace(/_/g, "-");
    if (NOT_TOOLS.has(name)) return;
    emit({ ecosystem: "tool-pin", name, current: m[2] }, i + 1);
  });
}

// --- driver ----------------------------------------------------------------

export function inventory(root: string, opts: InventoryOptions = {}): Item[] {
  const excludes = [...(opts.noDefaultExcludes ? [] : DEFAULT_EXCLUDES), ...(opts.exclude ?? [])];
  const byKey = new Map<string, Item>();
  const files = listFiles(root);
  const localBuilds = new Set(
    files.filter((f) => /(^|\/)Dockerfile[^/]*$/.test(f) && f.includes("/")).map((f) => basename(dirname(f)).toLowerCase()),
  );
  for (const rel of files) {
    if (excludes.some((re) => re.test(rel))) continue;
    const base = basename(rel);
    const isYaml = /\.ya?ml$/.test(base);
    const isDocker = /^Dockerfile/.test(base) || /\.Dockerfile$/.test(base);
    const isGoMod = base === "go.mod";
    const isReq = /^requirements.*\.txt$/.test(base);
    const isPkg = base === "package.json";
    const isWf = /^\.github\/workflows\/[^/]+\.ya?ml$/.test(rel);
    const isTool = base === "Makefile" || /\.(mk|sh)$/.test(base);
    if (!(isYaml || isDocker || isGoMod || isReq || isPkg || isTool)) continue;
    const abs = join(root, rel);
    let text: string;
    try {
      if (statSync(abs).size > 4 << 20) continue;
      text = readFileSync(abs, "utf8");
    } catch {
      continue;
    }
    const lines = text.split("\n");
    const emit: Emit = (it, line) => {
      const key = `${it.ecosystem}|${it.name}|${it.current.replace(/^v(?=\d)/, "")}`;
      let e = byKey.get(key);
      if (!e) {
        e = { ...it, notes: [...(it.notes ?? [])], locations: [] };
        if (it.ecosystem === "oci-image" || it.ecosystem === "oci-artifact") {
          const lib = /^docker\.io\/library\/(.+)$/.exec(it.name)?.[1];
          if (
            FIRST_PARTY.some((re) => re.test(it.name)) ||
            LOCAL_TAGS.has(it.current) ||
            (lib && [...localBuilds].some((b) => lib === b || lib.startsWith(`${b}-`)))
          ) {
            e.firstParty = true;
            e.notes.push("first-party build: no upstream");
          }
        }
        byKey.set(key, e);
      } else {
        for (const n of it.notes ?? []) if (!e.notes.includes(n)) e.notes.push(n);
      }
      if (!e.locations.some((l) => l.file === rel && l.line === line)) e.locations.push({ file: rel, line });
    };
    if (isWf) workflow(lines, emit);
    else if (isYaml) yamlFile(lines, emit);
    if (isDocker) dockerfile(lines, emit);
    if (isGoMod) goMod(lines, emit, !!opts.includeIndirect);
    if (isReq) requirements(lines, emit);
    if (isPkg) packageJson(rel, root, lines, emit);
    if (isTool) toolPins(lines, emit);
  }
  const items = [...byKey.values()];
  for (const it of items) it.locations.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line);
  return items.sort((a, b) => a.ecosystem.localeCompare(b.ecosystem) || a.name.localeCompare(b.name) || a.current.localeCompare(b.current));
}
