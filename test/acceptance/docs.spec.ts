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

const PAGES = [
  { slug: "start/external-linux-agent", heading: "Onboard an external Linux agent" },
  { slug: "onboarding/user-journey", heading: "Onboard as a first user" },
  { slug: "agents/dual-agent-onboarding", heading: "Claim the two demonstration agents" },
  { slug: "security/nono-optionality", heading: "Nono optionality and Landlock confinement" },
  { slug: "operations/demo-walkthrough", heading: "Run the partner demonstration" },
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
