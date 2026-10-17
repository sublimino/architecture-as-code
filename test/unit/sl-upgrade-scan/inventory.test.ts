// @id      sl-upgrade-scan-inventory
// @target  .agents/skills/sl-upgrade-scan/Tools/inventory.ts
// @doc     .agents/skills/sl-upgrade-scan/SKILL.md
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { type Item, inventory } from "../../../.agents/skills/sl-upgrade-scan/Tools/inventory.ts";

let root = "";
let items: Item[] = [];

function put(rel: string, body: string) {
  const p = join(root, rel);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, body);
}

function find(eco: string, name: string): Item {
  const it = items.find((i) => i.ecosystem === eco && i.name === name);
  if (!it) throw new Error(`no ${eco} ${name} in ${JSON.stringify(items.map((i) => `${i.ecosystem}:${i.name}`))}`);
  return it;
}

beforeAll(() => {
  root = mkdtempSync(join(tmpdir(), "upgrade-scan-inv-"));
  put(
    "infra/bao/statefulset.yaml",
    [
      "apiVersion: apps/v1",
      "kind: StatefulSet",
      "spec:",
      "  template:",
      "    spec:",
      "      containers:",
      "        - name: bao",
      "          image: quay.io/openbao/openbao:2.1.1",
      "        - name: helper",
      '          image: "redis:7-alpine"',
      "        - name: templated",
      "          image: ${REGISTRY}/thing:1.0.0",
      "        - name: pinned",
      "          image: registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.10.0@sha256:c53535af8a7f7e3164609838c4b191b42b2d81238d75c1b2a2b582ada62a9780",
    ].join("\n"),
  );
  put("infra/other.yaml", "spec:\n  image: quay.io/openbao/openbao:2.1.1\n");
  put(
    "infra/kind/cluster.yaml",
    "kind: Cluster\nnodes:\n  - role: control-plane\n    image: kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5\n",
  );
  put(
    "apps/svc/Dockerfile",
    "FROM golang:1.27-alpine AS build\nRUN go build\nFROM build AS test\nFROM gcr.io/distroless/static-debian12:nonroot\n",
  );
  put(
    "apps/svc/overlay/kustomization.yaml",
    "resources:\n  - ../base\nimages:\n  - name: ghcr.io/dexidp/dex\n    newTag: v2.41.1\n",
  );
  put(
    "apps/svc/go.mod",
    [
      "module example.com/svc",
      "",
      "go 1.24.5",
      "",
      "toolchain go1.25.1",
      "",
      "require (",
      "\tgithub.com/spf13/cobra v1.8.0",
      "\tgolang.org/x/net v0.20.0 // indirect",
      ")",
      "",
      "require github.com/stretchr/testify v1.9.0",
    ].join("\n"),
  );
  put("apps/py/requirements.txt", "# deps\nfastapi==0.110.0\nuvicorn[standard]==0.29.0\nrequests>=2.31\n");
  put(
    "apps/web/package.json",
    JSON.stringify({ name: "web", dependencies: { react: "^18.2.0" }, devDependencies: { vite: "~5.1.0" } }, null, 2),
  );
  put(
    "apps/web/package-lock.json",
    JSON.stringify({ packages: { "node_modules/react": { version: "18.3.1" }, "node_modules/vite": { version: "5.1.4" } } }),
  );
  put(
    "apps/bunweb/package.json",
    JSON.stringify({ name: "bunweb", dependencies: { zod: "^3.22.0" } }, null, 2),
  );
  put("apps/bunweb/bun.lock", '{\n  "packages": {\n    "zod": ["zod@3.23.8", "", {}, "sha512-x"],\n  },\n}\n');
  put(
    ".github/workflows/ci.yaml",
    [
      "jobs:",
      "  a:",
      "    steps:",
      "      - uses: actions/checkout@v4",
      "      - uses: docker/login-action@c94ce9fb468520275223c153574b00df6fe4bcc9 # v3.1.0",
      "      - uses: ./.github/actions/local",
      "      - uses: controlplaneio-fluxcd/distribution/actions/push@main",
    ].join("\n"),
  );
  put(
    "scripts/setup.sh",
    '#!/usr/bin/env bash\nKIND_VERSION="v0.29.0"\nCHART_VERSION="${KAGENT_CHART_VERSION:-0.9.9}"\nZSH_VERSION=${ZSH_VERSION:-}\nGO_VERSION="$(go version)"\n',
  );
  put("Makefile", "KNATIVE_VERSION ?= v1.18.0\n");
  put(
    "infra/flux/oci.yaml",
    [
      "apiVersion: source.toolkit.fluxcd.io/v1",
      "kind: OCIRepository",
      "metadata:",
      "  name: envoy-gateway",
      "spec:",
      "  url: oci://docker.io/envoyproxy/gateway-helm",
      "  ref:",
      '    tag: "v1.8.2"',
    ].join("\n"),
  );
  put("infra/values.yaml", "image:\n  repository: ghcr.io/spiffe/spire-server\n  tag: 1.11.1\n");
  // Excluded by default: fixtures and docs never deploy.
  put("test/fixtures/x/go.mod", "module x\n\ngo 1.20\n\nrequire github.com/evil/thing v0.0.1\n");
  put("docs/evidence/pod.yaml", "image: docker.io/malicious/untrusted:latest\n");
  put("node_modules/foo/package.json", JSON.stringify({ dependencies: { leftpad: "1.0.0" } }));
  items = inventory(root);
});

afterAll(() => rmSync(root, { recursive: true, force: true }));

describe("inventory: container images", () => {
  test("k8s manifest image with exact file:line, merged across files", () => {
    const it = find("oci-image", "quay.io/openbao/openbao");
    expect(it.current).toBe("2.1.1");
    expect(it.locations).toEqual([
      { file: "infra/bao/statefulset.yaml", line: 8 },
      { file: "infra/other.yaml", line: 2 },
    ]);
  });
  test("docker hub short names are canonicalised", () => {
    const it = find("oci-image", "docker.io/library/redis");
    expect(it.current).toBe("7-alpine");
    expect(it.locations[0]).toEqual({ file: "infra/bao/statefulset.yaml", line: 10 });
  });
  test("templated references are skipped, never guessed", () => {
    expect(items.some((i) => i.name.includes("thing"))).toBe(false);
  });
  test("tag@digest keeps the tag and records the digest", () => {
    const it = find("oci-image", "registry.k8s.io/sig-storage/csi-node-driver-registrar");
    expect(it.current).toBe("v2.10.0");
    expect(it.digest).toStartWith("sha256:");
  });
  test("kind node image", () => {
    const it = find("oci-image", "docker.io/kindest/node");
    expect(it.current).toBe("v1.36.1");
    expect(it.locations[0]).toEqual({ file: "infra/kind/cluster.yaml", line: 4 });
  });
  test("Dockerfile FROM, stage aliases skipped", () => {
    expect(find("oci-image", "docker.io/library/golang").locations[0]).toEqual({ file: "apps/svc/Dockerfile", line: 1 });
    expect(find("oci-image", "gcr.io/distroless/static-debian12").current).toBe("nonroot");
    expect(items.some((i) => i.name.endsWith("/build"))).toBe(false);
  });
  test("kustomization images newTag", () => {
    const it = find("oci-image", "ghcr.io/dexidp/dex");
    expect(it.current).toBe("v2.41.1");
    expect(it.locations[0]).toEqual({ file: "apps/svc/overlay/kustomization.yaml", line: 5 });
  });
  test("Helm values repository + tag", () => {
    const it = find("oci-image", "ghcr.io/spiffe/spire-server");
    expect(it.current).toBe("1.11.1");
    expect(it.locations[0]).toEqual({ file: "infra/values.yaml", line: 3 });
  });
  test("Flux OCIRepository ref.tag", () => {
    const it = find("oci-artifact", "docker.io/envoyproxy/gateway-helm");
    expect(it.current).toBe("v1.8.2");
    expect(it.locations[0]).toEqual({ file: "infra/flux/oci.yaml", line: 8 });
  });
});

describe("inventory: language ecosystems", () => {
  test("go.mod direct requires, indirect skipped by default", () => {
    expect(find("go-module", "github.com/spf13/cobra").locations[0]).toEqual({ file: "apps/svc/go.mod", line: 8 });
    expect(find("go-module", "github.com/stretchr/testify").locations[0].line).toBe(12);
    expect(items.some((i) => i.name === "golang.org/x/net")).toBe(false);
  });
  test("indirect requires on request", () => {
    const all = inventory(root, { includeIndirect: true });
    expect(all.some((i) => i.name === "golang.org/x/net")).toBe(true);
  });
  test("go directive and toolchain are runtime items", () => {
    const go = items.filter((i) => i.ecosystem === "runtime" && i.name === "go");
    expect(go.map((g) => g.current).sort()).toEqual(["1.24.5", "1.25.1"]);
  });
  test("requirements.txt pins, extras stripped, ranges flagged", () => {
    expect(find("pypi", "fastapi").locations[0]).toEqual({ file: "apps/py/requirements.txt", line: 2 });
    expect(find("pypi", "uvicorn").current).toBe("0.29.0");
    const r = find("pypi", "requests");
    expect(r.notes.join(" ")).toContain("not pinned");
  });
  test("npm direct deps resolved from package-lock", () => {
    const r = find("npm", "react");
    expect(r.current).toBe("18.3.1");
    expect(r.locations[0].file).toBe("apps/web/package.json");
    expect(r.locations[0].line).toBe(4);
    expect(find("npm", "vite").current).toBe("5.1.4");
  });
  test("npm direct deps resolved from bun.lock", () => {
    expect(find("npm", "zod").current).toBe("3.23.8");
  });
});

describe("inventory: actions and tool pins", () => {
  test("GitHub Actions: tag ref and SHA-pinned ref with version comment", () => {
    expect(find("github-action", "actions/checkout").current).toBe("v4");
    const login = find("github-action", "docker/login-action");
    expect(login.current).toBe("v3.1.0");
    expect(login.locations[0]).toEqual({ file: ".github/workflows/ci.yaml", line: 5 });
    expect(items.some((i) => i.name.startsWith("./"))).toBe(false);
    expect(find("github-action", "controlplaneio-fluxcd/distribution").current).toBe("main");
  });
  test("CLI tool pins in scripts and Makefiles, defaults read through ${X:-y}", () => {
    expect(find("tool-pin", "kind").locations[0]).toEqual({ file: "scripts/setup.sh", line: 2 });
    expect(find("tool-pin", "chart").current).toBe("0.9.9");
    expect(find("tool-pin", "knative").current).toBe("v1.18.0");
    expect(items.some((i) => i.name === "zsh" || i.name === "go" && i.ecosystem === "tool-pin")).toBe(false);
  });
});

describe("inventory: exclusions", () => {
  test("fixtures, docs and node_modules are not inventoried", () => {
    expect(items.some((i) => i.name === "github.com/evil/thing")).toBe(false);
    expect(items.some((i) => i.name.includes("malicious"))).toBe(false);
    expect(items.some((i) => i.name === "leftpad")).toBe(false);
  });
});
