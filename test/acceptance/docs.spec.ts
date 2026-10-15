import { test, expect } from "@playwright/test";

// Renders the four SLON-P3-1 documentation pages in Chromium and asserts each
// one actually produced a page rather than a 404 shell.
//
// This spec deliberately drives a LOCALLY SERVED BUILD of the checked-out tree,
// not the cluster. `docs/signalloom/slon-p3-docs-portal-provenance.md` §4
// establishes that the running `docs-signalloom` image was published from
// `feat/signal-loop-and-bootstrap-refactor` and that every Flux source in the
// demo cluster is an OCIRepository carrying no git revision — so a live probe
// of `/docs` is evidence about the deployed artifact and never about the branch
// under test. SLON-P1-PRE already recorded `/docs/ -> 200 OK` as a property of
// the integration line when it was a property of a different branch; pointing
// this spec at the gateway would repeat that mistake with a green tick on it.
//
// Run it against a fresh build:
//   bun run --cwd d2-signalloom/apps/docs-signalloom build
//   bunx astro preview --root d2-signalloom/apps/docs-signalloom --port 4325
//   DOCS_BASE_URL=http://127.0.0.1:4325/docs \
//     bunx playwright test docs.spec.ts --project=docs
//
// There is no skip-when-unreachable branch. A docs server that is not there is
// a failure, not a pass: a `test.skip()` here would report green for a suite
// that rendered nothing.

const BASE = (process.env.DOCS_BASE_URL ?? "http://127.0.0.1:4325/docs").replace(/\/+$/, "");
const ENGINEERING = (process.env.DEV_DOCS_BASE_URL ?? BASE.replace(/\/docs$/, "/dev-docs")).replace(/\/+$/, "");

const PAGES = [
  { slug: "start/external-linux-agent", heading: "Onboard an external Linux agent" },
  { slug: "onboarding/user-journey", heading: "Onboard as a first user" },
  { slug: "agents/dual-agent-onboarding", heading: "Claim the two demonstration agents" },
  { slug: "security/nono-optionality", heading: "Nono optionality and Landlock confinement" },
  { slug: "operations/demo-walkthrough", heading: "Run the partner demonstration" },
  { slug: "operate/containment-runbook", heading: "Agent Containment & Response Operational Runbook" },
  { slug: "reference/denial-matrix", heading: "Per-Plane Denial Matrix & SLA Reference" },
  { slug: "operate/coding-agent-detection-runbook", heading: "Coding Agent Detection & Governance Runbook" },
  { slug: "security/detective-telemetry-architecture", heading: "Coding Agent Detective Telemetry Architecture" },
  { slug: "security/zero-customer-payload", heading: "Zero-Customer-Payload Privacy Architecture & Falsification Evidence" },
  { slug: "reference/lawful-basis-assessment", heading: "Lawful Basis & GDPR Legitimate Interests Assessment (LIA)" },
  { slug: "start/quick-start", heading: "Quick start" },
  { slug: "security/data-protection-and-erasure", heading: "Cryptographic data protection and erasure" },
  { slug: "operate/rbac-formal-analysis", heading: "Formal verification of Kubernetes RBAC" },
  { slug: "operate/cpai-runtime-proxy", heading: "CPAI runtime proxy configuration" },
  { slug: "operate/kagent-declarative-swarms", heading: "CNCF Kagent declarative agent swarms" },
] as const;

test.describe("SLON-P3-1 documentation pages render", () => {
  for (const page_ of PAGES) {
    test(`${page_.slug} renders its heading and navigation`, async ({ page }) => {
      const response = await page.goto(`${BASE}/${page_.slug}/`, { waitUntil: "domcontentloaded" });

      expect(response, `no HTTP response for ${page_.slug}`).not.toBeNull();
      expect(response!.status(), `unexpected status for ${page_.slug}`).toBe(200);

      // A non-empty h1 is the assertion that separates "the route exists" from
      // "the page rendered". A 404 shell has a heading too, so match the text.
      const h1 = page.locator("h1").first();
      await expect(h1).toBeVisible();
      await expect(h1).toHaveText(page_.heading);

      // The sidebar entry proves astro.config.mjs claims this page, not just
      // that the file compiled.
      const navLink = page.locator(`a[href$="/${page_.slug}/"]`).first();
      await expect(navLink).toHaveCount(1);

      // Mermaid.astro emits <pre class="mermaid"> and swaps it for an <svg>
      // client-side. Asserting the container exists is shape validation — it
      // is present whether or not mermaid ran, so it would pass with the
      // diagram script removed entirely. Assert the rendered <svg> instead,
      // and require non-zero dimensions so a collapsed render fails too.
      const svg = page.locator(".mermaid svg, svg[id^='mermaid']").first();
      await expect(svg).toBeVisible({ timeout: 15_000 });
      const box = await svg.boundingBox();
      expect(box, `mermaid svg has no box on ${page_.slug}`).not.toBeNull();
      expect(box!.width, `mermaid svg collapsed on ${page_.slug}`).toBeGreaterThan(0);
      expect(box!.height, `mermaid svg collapsed on ${page_.slug}`).toBeGreaterThan(0);
    });
  }

  test("every new page is reachable from the sidebar of every other new page", async ({ page }) => {
    await page.goto(`${BASE}/onboarding/user-journey/`, { waitUntil: "domcontentloaded" });
    for (const page_ of PAGES) {
      await expect(
        page.locator(`a[href$="/${page_.slug}/"]`).first(),
        `sidebar is missing ${page_.slug}`,
      ).toHaveCount(1);
    }
  });
});

// The architecture diagrams page is asserted separately from PAGES because it
// carries no Mermaid fence: its diagrams are published Draw.io assets served
// from public/diagrams/, so the PAGES loop's mermaid assertion would fail on it.
//
// The caution assertion is the point of this block. The page is served by an
// unauthenticated nginx location (see the TECH DEBT comment above
// `location /docs` in dashboard-signalloom/nginx.conf), and the plan of
// record is to gate it behind the superadmin check before production
// go-live. Pinning the notice means the debt cannot be dropped silently: a
// deletion of the warning fails this suite, and the correct way to make it
// pass is to gate the page and then delete this test with the warning.
const DIAGRAMS = [
  "osramp-kind-sovereign-airgap",
  "osramp-aws-multitenant-saas",
  "osramp-gcp-multitenant-saas",
  "osramp-azure-multitenant-saas",
] as const;

test.describe("architecture diagrams page", () => {
  const slug = "reference/architecture-diagrams";

  test("renders its heading, sidebar entry, and the known-limitation notice", async ({ page }) => {
    const response = await page.goto(`${ENGINEERING}/${slug}/`, { waitUntil: "domcontentloaded" });

    expect(response, "no HTTP response for the architecture diagrams page").not.toBeNull();
    expect(response!.status()).toBe(200);

    await expect(page.locator("h1").first()).toHaveText("Architecture diagrams");
    await expect(page.locator(`a[href$="/${slug}/"]`).first()).toHaveCount(1);

    // TECH DEBT marker. Delete this assertion only together with the fix.
    const body = page.locator("body");
    await expect(body).toContainText("not access-controlled");
    await expect(body).toContainText("before production go-live");
  });

  test("lists Azure first among the hyperscaler platforms", async ({ page }) => {
    await page.goto(`${ENGINEERING}/${slug}/`, { waitUntil: "domcontentloaded" });
    const headings = await page.locator("h3").allTextContents();
    const clouds = headings.filter(h => /Azure|Amazon|Google/.test(h)).map(h => h.trim());
    expect(clouds).toEqual([
      "Microsoft Azure, AKS",
      "Amazon Web Services, EKS",
      "Google Cloud Platform, GKE",
    ]);
  });

  test("every inline diagram actually loads its asset", async ({ page }) => {
    await page.goto(`${ENGINEERING}/${slug}/`, { waitUntil: "load" });

    // naturalWidth separates "the <img> tag is in the markup" from "the
    // browser fetched and decoded the file". A broken path reports 0.
    for (const name of DIAGRAMS) {
      const img = page.locator(`img[src$="/diagrams/${name}.svg"]`).first();
      await expect(img, `no <img> for ${name}`).toHaveCount(1);
      const width = await img.evaluate(el => (el as HTMLImageElement).naturalWidth);
      expect(width, `${name}.svg did not load`).toBeGreaterThan(0);
    }
  });

  test("every download link resolves to a served file", async ({ page, request }) => {
    await page.goto(`${ENGINEERING}/${slug}/`, { waitUntil: "domcontentloaded" });

    const hrefs = await page.locator('a[href*="/diagrams/"]').evaluateAll(els =>
      els.map(el => (el as HTMLAnchorElement).href),
    );
    expect(hrefs.length, "no diagram download links on the page").toBeGreaterThan(0);

    for (const href of hrefs) {
      const head = await request.get(href);
      expect(head.status(), `unexpected status for ${href}`).toBe(200);
    }
  });

  test("diagram images support click-to-zoom modal", async ({ page }) => {
    await page.goto(`${ENGINEERING}/${slug}/`, { waitUntil: "load" });

    const firstDiagramImg = page.locator(`img[src$="/diagrams/${DIAGRAMS[0]}.svg"]`).first();
    await expect(firstDiagramImg).toBeVisible();

    const dialog = page.locator("dialog.starlight-image-zoom-dialog");
    await expect(dialog).toHaveCount(0);

    // Clicking the image opens the portaled zoom dialog
    await firstDiagramImg.click();
    await expect(dialog).toBeVisible();
    await expect(dialog).toHaveAttribute("open", "");
    await expect(page.locator("body")).toHaveClass(/starlight-image-zoom-opened/);

    // Pressing Escape closes the dialog and removes it
    await page.keyboard.press("Escape");
    await expect(dialog).toHaveCount(0);
  });
});

// Internal Architecture publishes the component-level SeeCode diagrams
// (public/diagrams/internal/NN-*.{svg,html,json}). docs-signalloom/DIAGRAMS.md
// governs these the same way it governs the Draw.io platform diagrams above,
// so a drift from its inclusion/exclusion lists fails test/diagram-focus.bats,
// not this spec. This spec only proves the page renders and every asset it
// links actually loads.
test.describe("internal architecture page", () => {
  const slug = "reference/internal-architecture";

  test("renders its heading and sidebar entry", async ({ page }) => {
    const response = await page.goto(`${ENGINEERING}/${slug}/`, { waitUntil: "domcontentloaded" });

    expect(response, "no HTTP response for the internal architecture page").not.toBeNull();
    expect(response!.status()).toBe(200);

    await expect(page.locator("h1").first()).toHaveText("Internal Architecture");
    await expect(page.locator(`a[href$="/${slug}/"]`).first()).toHaveCount(1);
  });

  test("embeds between 10 and 20 diagrams, each actually decoded", async ({ page }) => {
    await page.goto(`${ENGINEERING}/${slug}/`, { waitUntil: "load" });

    const images = page.locator('img[src*="/diagrams/internal/"]');
    const count = await images.count();
    expect(count, "internal diagram count out of the expected 10-20 range").toBeGreaterThanOrEqual(10);
    expect(count, "internal diagram count out of the expected 10-20 range").toBeLessThanOrEqual(20);

    for (let i = 0; i < count; i++) {
      const img = images.nth(i);
      const src = await img.getAttribute("src");
      const width = await img.evaluate(el => (el as HTMLImageElement).naturalWidth);
      expect(width, `${src} did not load`).toBeGreaterThan(0);
    }
  });

  test("every internal diagram link resolves to a served file", async ({ page, request }) => {
    await page.goto(`${ENGINEERING}/${slug}/`, { waitUntil: "domcontentloaded" });

    const hrefs = await page.locator('a[href*="/diagrams/internal/"]').evaluateAll(els =>
      els.map(el => (el as HTMLAnchorElement).href),
    );
    expect(hrefs.length, "no internal diagram links on the page").toBeGreaterThan(0);

    for (const href of hrefs) {
      const head = await request.get(href);
      expect(head.status(), `unexpected status for ${href}`).toBe(200);
    }
  });

  test("architecture diagrams page points here instead of embedding component flows", async ({ page }) => {
    await page.goto(`${ENGINEERING}/reference/architecture-diagrams/`, { waitUntil: "domcontentloaded" });

    // The old component-flows diagram lived at public/diagrams/osramp-demo.svg.
    // It moved into this page as 01-component-flows; the old embed must be gone.
    await expect(page.locator('img[src$="/diagrams/osramp-demo.svg"]')).toHaveCount(0);

    await expect(page.locator(`a[href$="/${slug}/"]`).first()).toHaveCount(1);
  });
});

test.describe("engineering portal migration", () => {
  for (const slug of ["architecture-diagrams", "internal-architecture"]) {
    for (const suffix of ["", "/"]) {
      test(`old ${slug}${suffix} permanently redirects`, async ({ request, page }) => {
        const old = `${BASE}/reference/${slug}${suffix}`;
        const response = await request.get(old, { maxRedirects: 0 });
        expect(response.status()).toBe(301);
        expect(response.headers().location).toBe(`/dev-docs/reference/${slug}/`);
        await page.goto(old);
        await expect(page).toHaveURL(`${ENGINEERING}/reference/${slug}/`);
      });
    }
  }

  test("user sidebar excludes engineering architecture pages", async ({ page }) => {
    await page.goto(`${BASE}/start/quick-start/`);
    await expect(page.locator('nav.sidebar a[href*="reference/architecture-diagrams"]')).toHaveCount(0);
    await expect(page.locator('nav.sidebar a[href*="reference/internal-architecture"]')).toHaveCount(0);
  });

  test("engineering title and shared styling render", async ({ page }) => {
    const response = await page.goto(`${ENGINEERING}/reference/architecture-diagrams/`);
    expect(response?.status()).toBe(200);
    await expect(page.locator('.site-title').first()).toContainText("Signal Loom Engineering");
    await expect(page.locator('h1').first()).toBeVisible();
    const styles = await page.locator('link[rel="stylesheet"]').count();
    expect(styles).toBeGreaterThan(0);
  });

  for (const role of ["developer", "support-engineer", "security-engineer"]) {
    test(`engineering onboarding navigation opens ${role}`, async ({ page }) => {
      await page.goto(`${ENGINEERING}/`);
      const link = page.locator(`nav.sidebar a[href="/dev-docs/onboarding/${role}/"]`);
      await link.click();
      await expect(page).toHaveURL(`${ENGINEERING}/onboarding/${role}/`);
      await expect(page.locator("h1").first()).toBeVisible();
      await expect(page.locator("main")).toContainText("Stop");
    });
  }

  test("engineering security assessment is read-only and leads to a findings template", async ({ page }) => {
    await page.goto(`${ENGINEERING}/onboarding/security-engineer/`);
    await expect(page.locator("main")).toContainText("Do not mutate the assessed environment");
    await expect(page.locator("main")).toContainText("The assessment permits no automatic remediation");
    await page.locator('main a[href="/dev-docs/reference/security-assessment-template/"]').first().click();
    await expect(page.locator("main")).toContainText("Confirmed gap");
    await expect(page.locator("main")).toContainText("Unverified");
  });

  test("engineering Pagefind search works under the documentation CSP", async ({ page }) => {
    const errors: string[] = [];
    page.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
    const response = await page.goto(`${ENGINEERING}/`);
    const csp = response?.headers()["content-security-policy"] ?? "";
    expect(csp).toContain("'wasm-unsafe-eval'");
    expect(csp).not.toContain("'unsafe-eval'");
    await page.getByRole("button", { name: "Search", exact: true }).click();
    await page.locator('.pagefind-ui__search-input').fill("Security engineer");
    await expect(page.locator('.pagefind-ui__result-link').first()).toBeVisible();
    const links = await page.locator('.pagefind-ui__result-link').evaluateAll(nodes => nodes.map(node => (node as HTMLAnchorElement).pathname));
    expect(links.length).toBeGreaterThan(0);
    expect(links.every(link => link.startsWith("/dev-docs/"))).toBe(true);
    expect(errors).toEqual([]);
  });
});

test.describe("documentation layout width and positioning", () => {
  test("user documentation expands content width and preserves TOC positioning without overflow", async ({ page }) => {
    await page.setViewportSize({ width: 1600, height: 900 });
    const response = await page.goto(`${BASE}/start/quick-start/`, { waitUntil: "domcontentloaded" });
    expect(response, "no HTTP response for quick-start").not.toBeNull();
    expect(response!.status()).toBe(200);

    const slContainer = page.locator(".main-pane .sl-container").first();
    await expect(slContainer).toBeVisible();
    const containerBox = await slContainer.boundingBox();
    expect(containerBox, "content .sl-container has no bounding box").not.toBeNull();
    expect(containerBox!.width).toBeGreaterThan(850);

    const mainPane = page.locator(".main-pane").first();
    const rightSidebar = page.locator(".right-sidebar").first();
    await expect(mainPane).toBeVisible();
    await expect(rightSidebar).toBeVisible();

    const mainBox = await mainPane.boundingBox();
    const sidebarBox = await rightSidebar.boundingBox();
    expect(mainBox, "main-pane has no bounding box").not.toBeNull();
    expect(sidebarBox, "right-sidebar has no bounding box").not.toBeNull();

    expect(mainBox!.x + mainBox!.width).toBeLessThanOrEqual(sidebarBox!.x + 1);

    const hasNoHorizontalOverflow = await page.evaluate(() => {
      return document.documentElement.scrollWidth <= document.documentElement.clientWidth;
    });
    expect(hasNoHorizontalOverflow).toBe(true);
  });
});

test.describe("dev-docs diagram and content layout width", () => {
  test("Draw.io architecture diagram expands beyond 850px on desktop viewport", async ({ page }) => {
    await page.setViewportSize({ width: 1600, height: 900 });
    await page.goto(`${ENGINEERING}/reference/architecture-diagrams/`, { waitUntil: "load" });
    const drawioImg = page.locator('img[src$="/diagrams/osramp-kind-sovereign-airgap.svg"]').first();
    await expect(drawioImg).toBeVisible();
    const box = await drawioImg.boundingBox();
    expect(box, "Draw.io SVG boundingBox missing").not.toBeNull();
    expect(box!.width, "Draw.io SVG diagram width should expand beyond 850px").toBeGreaterThan(850);
  });

  test("internal architecture diagrams expand beyond 850px on desktop viewport", async ({ page }) => {
    await page.setViewportSize({ width: 1600, height: 900 });
    await page.goto(`${ENGINEERING}/reference/internal-architecture/`, { waitUntil: "load" });
    const internalImg = page.locator('img[src*="/diagrams/internal/"]').first();
    await expect(internalImg).toBeVisible();
    const box = await internalImg.boundingBox();
    expect(box, "Internal architecture diagram boundingBox missing").not.toBeNull();
    expect(box!.width, "Internal architecture diagram width should expand beyond 850px").toBeGreaterThan(850);
  });

  test("developer onboarding container expands beyond 850px on desktop viewport", async ({ page }) => {
    await page.setViewportSize({ width: 1600, height: 900 });
    await page.goto(`${ENGINEERING}/onboarding/developer/`, { waitUntil: "load" });
    const container = page.locator("main .sl-container").first();
    await expect(container).toBeVisible();
    const box = await container.boundingBox();
    expect(box, "main .sl-container boundingBox missing").not.toBeNull();
    expect(box!.width, "Developer onboarding main .sl-container width should expand beyond 850px").toBeGreaterThan(850);
  });

  test("mobile viewport does not suffer horizontal scroll overflow", async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    for (const path of [
      `${ENGINEERING}/reference/architecture-diagrams/`,
      `${ENGINEERING}/reference/internal-architecture/`,
      `${ENGINEERING}/onboarding/developer/`,
    ]) {
      await page.goto(path, { waitUntil: "load" });
      const noOverflow = await page.evaluate(() => {
        return document.documentElement.scrollWidth <= document.documentElement.clientWidth;
      });
      expect(noOverflow, `horizontal overflow detected on ${path}`).toBe(true);
    }
  });
});
