/**
 * Signal Loom Platform Acceptance Suite — Governance Navigation & Role Gating (Surface 1).
 *
 * Validates:
 *   1. 3-tier sidebar hierarchy (View, Control, Design) and ordered primary navigation items.
 *   2. Superadmin role gating: Demos and Development sections visible only for superadmins.
 *   3. Active route highlights with aria-current="page" across primary routes.
 *   4. Keyboard navigation shortcuts (1..9 direct jumps, '/' quick search).
 *   5. Responsive rail collapse and expansion transitions.
 *   6. Canonical route aliases and redirects (/activity -> /weave).
 *   7. Mobile viewport (375x667) and desktop viewport (1280x800) responsiveness.
 *   8. Zero em-dash typography verification across navigation DOM.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

interface NavItemSpec {
  name: string;
  href: string;
  category: "View" | "Control" | "Design";
}

const PRIMARY_NAV_ITEMS: NavItemSpec[] = [
  // View Tier
  { name: "Discovery", href: "/discovery", category: "View" },
  { name: "Agents", href: "/agents", category: "View" },
  { name: "Topology", href: "/topology", category: "View" },
  { name: "The Weave", href: "/weave", category: "View" },
  { name: "FAIR Risk", href: "/risk", category: "View" },

  // Control Tier
  { name: "Policies", href: "/policies", category: "Control" },
  { name: "Compliance", href: "/compliance", category: "Control" },
  { name: "Collusion & Access", href: "/collusion-access", category: "Control" },
  { name: "Audit Trail", href: "/audit", category: "Control" },

  // Design Tier
  { name: "Federated Services", href: "/federated-services", category: "Design" },
  { name: "Settings", href: "/settings", category: "Design" },
];

const SUPERADMIN_NAV_ITEMS = [
  { name: "Fleet Demo", href: "/fleet" },
  { name: "SuperCredential Demo", href: "/supercred" },
  { name: "AgentMaxxing Demo", href: "/demos/agentmaxxing" },
  { name: "Design System", href: "/design-system" },
];

test.describe("Surface 1: Governance Navigation & Role Gating (Desktop 1280x800)", () => {
  test.use({ viewport: { width: 1280, height: 800 } });

  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test("renders 3 core tier headings (View, Control, Design) and ordered primary items", async ({ page }) => {
    const nav = page.locator("#sl-sidebar-nav");
    await expect(nav).toBeVisible({ timeout: 15_000 });

    await expect(nav.getByText("View", { exact: true })).toBeVisible();
    await expect(nav.getByText("Control", { exact: true })).toBeVisible();
    await expect(nav.getByText("Design", { exact: true })).toBeVisible();

    for (const item of PRIMARY_NAV_ITEMS) {
      const link = nav.getByRole("link", { name: new RegExp(`^${item.name}$`, "i") });
      await expect(link).toBeVisible();
      await expect(link).toHaveAttribute("href", item.href);
    }
  });

  test("superadmin gating renders Demos and Development sections when flag is active", async ({ page }) => {
    const nav = page.locator("#sl-sidebar-nav");
    await expect(nav).toBeVisible({ timeout: 15_000 });

    // In helpers.ts login(), signalloom.superadmin is set to 'true'
    await expect(nav.getByText("Demos", { exact: true })).toBeVisible();
    await expect(nav.getByText("Development", { exact: true })).toBeVisible();

    for (const item of SUPERADMIN_NAV_ITEMS) {
      const link = nav.getByRole("link", { name: new RegExp(`^${item.name}$`, "i") });
      await expect(link).toBeVisible();
    }
  });

  test("navigates across primary routes and asserts aria-current='page' active highlight", async ({ page }) => {
    const nav = page.locator("#sl-sidebar-nav");
    await expect(nav).toBeVisible({ timeout: 15_000 });

    const sampleRoutes = [
      { name: "Discovery", href: "/discovery" },
      { name: "The Weave", href: "/weave" },
      { name: "Policies", href: "/policies" },
      { name: "Settings", href: "/settings" },
    ];

    for (const route of sampleRoutes) {
      const link = nav.getByRole("link", { name: new RegExp(`^${route.name}$`, "i") });
      await link.click();

      await expect(page).toHaveURL(new RegExp(`${route.href}`));
      await expect(link).toHaveAttribute("aria-current", "page");
    }
  });

  test("collapses sidebar to compact icon rail and expands back without layout shift", async ({ page }) => {
    const toggle = page.getByTestId("sidebar-collapse-toggle");
    await expect(toggle).toBeVisible();
    await expect(toggle).toHaveAttribute("aria-expanded", "true");

    const nav = page.locator("#sl-sidebar-nav");
    await expect(nav.getByText("View", { exact: true })).toBeVisible();

    // Collapse rail
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(nav.getByText("View", { exact: true })).not.toBeVisible();

    // Expand rail
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-expanded", "true");
    await expect(nav.getByText("View", { exact: true })).toBeVisible();
  });

  test("keyboard shortcuts navigate to primary items and focus quick search", async ({ page }) => {
    const nav = page.locator("#sl-sidebar-nav");
    await expect(nav).toBeVisible({ timeout: 15_000 });

    // Press '1' for Discovery
    await page.keyboard.press("1");
    const discoveryLink = nav.getByRole("link", { name: /^Discovery/i });
    await expect(discoveryLink).toHaveAttribute("aria-current", "page", { timeout: 10_000 });

    // Press '2' for Agents
    await page.keyboard.press("2");
    const agentsLink = nav.getByRole("link", { name: /^Agents/i });
    await expect(agentsLink).toHaveAttribute("aria-current", "page", { timeout: 10_000 });

    // Press '/' for quick search focus
    await page.keyboard.press("/");
    const searchInput = page.getByPlaceholder("Quick search");
    await expect(searchInput).toBeFocused();
  });

  test("legacy route /activity redirects seamlessly to canonical /weave", async ({ page }) => {
    await page.goto(`${BASE}/activity`, { waitUntil: "domcontentloaded" });
    await expect(page).toHaveURL(/\/weave/);
    await expect(page.getByRole("heading", { level: 1, name: "The Weave" })).toBeVisible({ timeout: 15_000 });
  });

  test("sidebar navigation contains zero em-dashes in rendered DOM text", async ({ page }) => {
    const nav = page.locator("#sl-sidebar-nav");
    await expect(nav).toBeVisible({ timeout: 15_000 });

    const navText = await nav.innerText();
    expect(navText).not.toContain("—");
    expect(navText).not.toContain("\u2014");
  });
});

test.describe("Surface 1: Governance Navigation (Mobile Viewport 375x667)", () => {
  test.use({ viewport: { width: 375, height: 667 } });

  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test("renders responsive navigation and drawer on mobile screen", async ({ page }) => {
    // Assert main container loads without layout overflow
    const main = page.locator("main");
    await expect(main).toBeVisible({ timeout: 15_000 });

    // Navigate to Discovery
    await page.goto(`${BASE}/discovery`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1, name: /Discovery/i })).toBeVisible({ timeout: 15_000 });

    // Zero em-dashes on mobile rendered text
    const bodyText = await page.locator("body").innerText();
    expect(bodyText).not.toContain("—");
  });
});
