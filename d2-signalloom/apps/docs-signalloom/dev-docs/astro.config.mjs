import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import starlightImageZoom from "starlight-image-zoom";
import { fileURLToPath } from "node:url";

export default defineConfig({
  site: process.env.DOCS_SITE_URL ?? "https://dashboard.osramp.acme.local",
  base: "/dev-docs",
  output: "static",
  outDir: "../dist-dev-docs",
  publicDir: "../public",
  integrations: [starlight({
    title: "Signal Loom Engineering",
    description: "Engineering guidance for Signal Loom contributors.",
    customCss: [fileURLToPath(new URL("../src/styles/custom.css", import.meta.url))],
    plugins: [starlightImageZoom()],
    sidebar: [
      { label: "Start here", items: [
        { label: "Overview", link: "/" },
        { label: "Engineering onboarding", link: "/onboarding/" }
      ] },
      { label: "Onboarding", items: [
        { label: "Developer", slug: "onboarding/developer" },
        { label: "Support engineer", slug: "onboarding/support-engineer" },
        { label: "Security engineer", slug: "onboarding/security-engineer" }
      ] },
      { label: "Reference", items: [{ autogenerate: { directory: "reference" } }] }
    ]
  })]
});
