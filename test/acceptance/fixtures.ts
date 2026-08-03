import { existsSync, readFileSync } from "node:fs";
import { test as base, expect } from "@playwright/test";

type Diagnostic = {
  kind: string;
  message: string;
};

// Where auth.setup.ts dumps sessionStorage after logging in.
const SESSION_FILE = "test-results/.auth-session.json";

export const test = base.extend({
  // Restore the OIDC session into every new context.
  //
  // The dashboard keeps its token in sessionStorage, not localStorage, so a
  // shared demo link cannot hand the next visitor the previous person's session
  // (dashboard-signalloom/src/auth/oidc.tsx). Playwright's storageState covers
  // cookies and localStorage; sessionStorage is per-tab and is NOT in it. So
  // the setup project's login stopped carrying over and every journey test
  // landed back on the Dex login page — 11 passing became 10 failing in one
  // change.
  //
  // addInitScript runs before any page script in every new document, which is
  // the part that matters: the app reads its token during boot, so restoring
  // after load would be too late and it would already have redirected to Dex.
  context: async ({ context }, use) => {
    if (existsSync(SESSION_FILE)) {
      await context.addInitScript((json: string) => {
        try {
          for (const [key, value] of Object.entries(JSON.parse(json) as Record<string, string>)) {
            window.sessionStorage.setItem(key, value);
          }
        } catch {
          /* a malformed dump must not mask the real assertion failure */
        }
      }, readFileSync(SESSION_FILE, "utf8"));
    }
    await use(context);
  },
  page: async ({ page }, use, testInfo) => {
    const diagnostics: Diagnostic[] = [];

    page.on("console", (message) => {
      diagnostics.push({
        kind: `console.${message.type()}`,
        message: message.text(),
      });
    });
    page.on("pageerror", (error) => {
      diagnostics.push({ kind: "pageerror", message: error.stack ?? error.message });
    });
    page.on("requestfailed", (request) => {
      diagnostics.push({
        kind: "requestfailed",
        message: `${request.method()} ${request.url()} — ${request.failure()?.errorText ?? "unknown error"}`,
      });
    });
    page.on("response", (response) => {
      if (response.status() >= 400) {
        diagnostics.push({
          kind: "http-error",
          message: `${response.status()} ${response.request().method()} ${response.url()}`,
        });
      }
    });

    await use(page);

    if (testInfo.status !== testInfo.expectedStatus) {
      try {
        const screenshotPath = testInfo.outputPath("failure.png");
        await page.screenshot({ path: screenshotPath, fullPage: true });
        await testInfo.attach("failure-screenshot", {
          path: screenshotPath,
          contentType: "image/png",
        });
      } catch (error) {
        diagnostics.push({
          kind: "screenshot-error",
          message: error instanceof Error ? error.message : String(error),
        });
      }
    }

    if (testInfo.status !== testInfo.expectedStatus || diagnostics.length > 0) {
      const body = diagnostics.length
        ? diagnostics.map(({ kind, message }) => `[${kind}] ${message}`).join("\n")
        : "No browser console or network diagnostics were captured.";
      await testInfo.attach("browser-diagnostics", {
        body: Buffer.from(body),
        contentType: "text/plain",
      });
    }
  },
});

export { expect };
