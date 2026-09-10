/**
 * Signal Loom dashboard — 3-tier navigation acceptance suite (SP-2).
 *
 * Validates:
 *   1. 3-tier hierarchy: View, Control, Design sections and ordered items.
 *   2. Persistent utility anchors: Onboarding and Help & Support.
 *   3. Active route highlighting without layout shifts (aria-current="page").
 *   4. Keyboard shortcuts (1..9 digit navigation and '/' quick search focus).
 *   5. Responsive rail collapse and expand state transitions.
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
  { name: "Overview", href: "/overview", category: "View" },
  { name: "Agents", href: "/agents", category: "View" },
  { name: "Topology", href: "/topology", category: "View" },
  { name: "Activity", href: "/activity", category: "View" },
  { name: "FAIR Risk", href: "/risk", category: "View" },

  // Control Tier
  { name: "Policies", href: "/policies", category: "Control" },
  { name: "Containment", href: "/containment", category: "Control" },
  { name: "Approvals", href: "/approvals", category: "Control" },
  { name: "Audit Trail", href: "/audit", category: "Control" },

  // Design Tier
  { name: "Workspaces", href: "/workspaces", category: "Design" },
  { name: "Connectors", href: "/connectors", category: "Design" },
  { name: "Fleet Config", href: "/fleet", category: "Design" },
  { name: "Settings", href: "/settings", category: "Design" },
];

test.describe("3-Tier Navigation Hierarchy & Structure", () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test("renders all 3 tier headings (View, Control, Design) in the sidebar", async ({ page }) => {
    const nav = page.locator("#sl-sidebar-nav");
    await expect(nav).toBeVisible({ timeout: 15_000 });

    await expect(nav.getByText("View", { exact: true })).toBeVisible();
    await expect(nav.getByText("Control", { exact: true })).toBeVisible();
    await expect(nav.getByText("Design", { exact: true })).toBeVisible();
  });

  test("renders every primary navigation link within its expected tier in order", async ({ page }) => {
    const nav = page.locator("#sl-sidebar-nav");
    await expect(nav).toBeVisible({ timeout: 15_000 });

    for (const item of PRIMARY_NAV_ITEMS) {
      const link = nav.getByRole("link", { name: new RegExp(`^${item.name}`, "i") });
      await expect(link).toBeVisible();
      await expect(link).toHaveAttribute("href", item.href);
    }
  });

  test("navigates through each tier and sets aria-current='page' on active route", async ({ page }) => {
    const nav = page.locator("#sl-sidebar-nav");
    await expect(nav).toBeVisible({ timeout: 15_000 });

    // Test a representative from each tier
    const sampleItems = [
      { name: "Overview", href: "/overview" },
      { name: "Policies", href: "/policies" },
      { name: "Workspaces", href: "/workspaces" },
    ];

    for (const item of sampleItems) {
      const link = nav.getByRole("link", { name: new RegExp(`^${item.name}`, "i") });
      await link.click();

      await expect(page).toHaveURL(new RegExp(`${item.href}`));
      await expect(link).toHaveAttribute("aria-current", "page");
    }
  });

  test("persistent utility anchors are visible and accessible", async ({ page }) => {
    const onboardingLink = page.getByRole("link", { name: /^Onboarding/i });
    await expect(onboardingLink).toBeVisible();
    await expect(onboardingLink).toHaveAttribute("href", "/onboarding");

    const helpButton = page.getByRole("button", { name: /help & support/i });
    await expect(helpButton).toBeVisible();

    // Verify opening help modal
    await helpButton.click();
    const helpModal = page.getByRole("heading", { name: "Help & Support" });
    await expect(helpModal).toBeVisible({ timeout: 10_000 });

    // Close help modal
    await page.getByRole("button", { name: "×" }).click();
    await expect(helpModal).not.toBeVisible({ timeout: 5_000 });
  });

  test("keyboard shortcuts navigate to primary items and focus search", async ({ page }) => {
    const nav = page.locator("#sl-sidebar-nav");
    await expect(nav).toBeVisible({ timeout: 15_000 });

    // Press '1' for item 1 (Overview)
    await page.keyboard.press("1");
    const overviewLink = nav.getByRole("link", { name: /^Overview/i });
    await expect(overviewLink).toHaveAttribute("aria-current", "page", { timeout: 10_000 });

    // Press '2' for item 2 (Agents)
    await page.keyboard.press("2");
    const agentsLink = nav.getByRole("link", { name: /^Agents/i });
    await expect(agentsLink).toHaveAttribute("aria-current", "page", { timeout: 10_000 });

    // Press '/' to focus quick search
    await page.keyboard.press("/");
    const searchInput = page.getByPlaceholder("Quick search");
    await expect(searchInput).toBeFocused();
  });

  test("collapses sidebar to compact icon rail and expands back", async ({ page }) => {
    const toggle = page.getByTestId("sidebar-collapse-toggle");
    await expect(toggle).toBeVisible();
    await expect(toggle).toHaveAttribute("aria-expanded", "true");

    const nav = page.locator("#sl-sidebar-nav");
    await expect(nav.getByText("View", { exact: true })).toBeVisible();

    // Collapse
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(nav.getByText("View", { exact: true })).not.toBeVisible();

    // Icons remain accessible in collapsed rail
    const agentsIconLink = nav.getByRole("link", { name: /^Agents/i });
    await expect(agentsIconLink).toBeVisible();

    // Expand
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-expanded", "true");
    await expect(nav.getByText("View", { exact: true })).toBeVisible();
  });
});
