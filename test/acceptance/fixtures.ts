import { test as base, expect } from "@playwright/test";

type Diagnostic = {
  kind: string;
  message: string;
};

export const test = base.extend({
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
