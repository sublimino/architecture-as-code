import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

const site = process.env.DOCS_SITE_URL ?? "https://dashboard.osramp.acme.local";

export default defineConfig({
  site,
  base: "/docs",
  output: "static",
  integrations: [
    starlight({
      title: "Signal Loom Docs",
      description: "Task-based guidance for the Signal Loom agent governance platform.",
      customCss: ["./src/styles/custom.css"],
      sidebar: [
        {
          label: "Start here",
          items: [
            { label: "Overview", slug: "index" },
            { label: "Quick start", slug: "start/quick-start" },
            { label: "Onboard your first agent", slug: "start/first-agent" },
            { label: "External Linux agent", slug: "start/external-linux-agent" }
          ]
        },
        {
          label: "Onboarding",
          items: [{ label: "Onboard as a first user", slug: "onboarding/user-journey" }]
        },
        {
          label: "Operate agents",
          items: [
            { label: "Claim the two demonstration agents", slug: "agents/dual-agent-onboarding" },
            { label: "Stun or unstun an agent", slug: "operate/stun-agent" },
            { label: "Containment & response runbook", slug: "operate/containment-runbook" }
          ]
        },
        {
          label: "Security",
          items: [
            { label: "Nono optionality and Landlock confinement", slug: "security/nono-optionality" }
          ]
        },
        {
          label: "Run demonstrations",
          items: [
            { label: "Run the partner demonstration", slug: "operations/demo-walkthrough" },
            { label: "Superadmin demonstrations", slug: "demos/superadmin" },
            { label: 'AgentMaxxing interactive demo', slug: 'demos/agentmaxxing' }
          ]
        },
        {
          label: "Use the platform",
          items: [
            { label: "View-only user", slug: "roles/view-only" },
            { label: "Advanced user", slug: "roles/advanced" },
            { label: "Security team", slug: "roles/security-team" },
            { label: "Platform admin", slug: "roles/platform-admin" }
          ]
        },
        {
          label: "Reference",
          items: [
            { label: "Per-plane denial matrix", slug: "reference/denial-matrix" },
            { label: "Operator identity lifecycle", slug: "reference/operator-identity-lifecycle" },
            { label: "External agent wire contracts", slug: "reference/external-agent-wire-contracts" },
            { label: "Current limits and roadmap", slug: "reference/roadmap" },
            { label: "Glossary", slug: "reference/glossary" },
            { label: "Documentation rules", slug: "reference/documentation-rules" }
          ]
        }
      ]
    })
  ]
});
