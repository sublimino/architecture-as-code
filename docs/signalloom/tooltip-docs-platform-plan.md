# Signal Loom Tooltips and Documentation Platform Plan

## Decision

Use **Astro Starlight** for a static Signal Loom documentation site. Build it in
`d2-signalloom/apps/docs-signalloom/` and serve it from an unprivileged nginx
container. Publish it through a direct Gateway route at `/docs`.

The dashboard owns route definitions. Starlight owns page help content. A build
step turns Starlight frontmatter into a generated dashboard help manifest. The
dashboard never owns a duplicate tooltip summary or documentation URL.

## Scope

The first release covers every protected dashboard route. It includes primary,
detail, administrative, onboarding, connector-help, and demo routes. Existing
control-level `HelpHint` components remain in place. The new page-level tooltip
explains the purpose of the current page, its main data, and the next useful
action.

Routes that redirect or cannot render a page are not documentation subjects:
`/`, `/signup`, `/redeem-invite`, and the wildcard fallback.

## User Experience

Add one `PageHelp` control beside the page title for every rendered route.

The control:

1. Shows a `?` icon.
2. Has an accessible name such as `Help for Agents`.
3. Opens on hover and keyboard focus.
4. Shows one or two short sentences from the generated help manifest.
5. Shows a `More help` link to `/docs/current/pages/<docId>/`.
6. Keeps the current dashboard page open when the tooltip closes.

Do not replace local `HelpHint` controls. Page help answers, “What is this
page?” Local help answers, “What does this control do?”

## Canonical Content Contract

Create `src/routes/pageRoutes.ts` in the dashboard. It is the sole catalogue of
renderable protected routes.

```ts
type PageRoute = {
  path: '/agents' | '/agents/:id' | /* remaining protected paths */ string
  docId: string
  element: React.LazyExoticComponent<React.ComponentType>
  helpScope: 'page' | 'detail' | 'utility'
}
```

Routes become data. `App.tsx` maps the catalogue to `Route` elements. `PageHelp`
matches the current pathname to the catalogue template and loads its generated
help item by `docId`.

Each Starlight page has frontmatter:

```yaml
---
title: Agents
docId: agents
tooltip: Review governed agents, their identity state, and policy posture.
summary: Manage the registry records that make agent actions accountable.
---
```

The documentation build validates frontmatter and writes:

```ts
// generated, do not edit
export const pageHelp = {
  agents: {
    title: 'Agents',
    tooltip: 'Review governed agents, their identity state, and policy posture.',
    href: '/docs/current/pages/agents/',
  },
} as const
```

The dashboard imports this generated file. Therefore the tooltip string and
link come from the documentation page itself.

## Drift Prevention

Add `check-page-help-contract.ts` and run it in both dashboard and docs CI.

It checks:

1. Each protected `PageRoute` has one `docId`.
2. Each `docId` has one Markdown page.
3. Each Markdown page has one unique `docId`.
4. Each page has a nonempty `tooltip` value within the agreed length limit.
5. Each page has a generated canonical `/docs/current/pages/<docId>/` URL.
6. No page-specific documentation file lacks a registered route.
7. Dynamic route templates use the template `docId`, never runtime values.

The docs build runs the checker before Starlight. The dashboard build runs it
before TypeScript. A route or documentation change cannot merge in a partial
state.

## Route Coverage Map

| Dashboard route | `docId` | Initial page |
|---|---|---|
| `/agents` | `agents` | Governed agents |
| `/agents/:id` | `agent-detail` | Agent detail |
| `/discovery` | `discovery` | Discovery |
| `/discovery/accounts/:accountId` | `discovery-account` | Discovery account |
| `/compliance` | `compliance` | Compliance overview |
| `/compliance/policies` | `compliance-policies` | Policy compliance |
| `/compliance/posture` | `agent-posture` | Agent posture |
| `/compliance/risk` | `risk-exposure` | Risk exposure |
| `/compliance/:frameworkId` | `framework-detail` | Framework detail |
| `/audit` | `audit-trail` | Audit trail |
| `/cryptography` | `cryptography` | Cryptography |
| `/credential-inventory` | `credential-inventory` | Credential inventory |
| `/federated-services` | `federated-services` | Federated services |
| `/collusion-access` | `collusion-access` | Collusion and access |
| `/rbac-analysis` | `rbac-analysis` | RBAC analysis |
| `/rbac-explorer` | `rbac-explorer` | RBAC explorer |
| `/agent-trust-topology` | `agent-trust-topology` | Agent trust topology |
| `/settings` | `settings` | Settings |
| `/onboarding` | `onboarding` | Onboarding |
| `/help/connectors/:provider` | `connector-help` | Connector help |
| `/network-tests` | `network-tests` | Network tests |
| `/supercred` | `supercred` | SuperCredential demo |
| `/fleet` | `fleet` | Fleet demo |
| `/fleet/audience` | `fleet-audience` | Fleet audience view |

## Initial Documentation Structure

```text
Start Here
  Overview
  Core Concepts

Philosophy
  Governance That Enables Action
  Agency Needs Accountability
  Identity Is Earned and Bounded
  Evidence Over Claims

Pages
  Agents
  Discovery
  Compliance
  Audit Trail
  ... one concise page per docId

Glossary
```

Every page document starts with a short explanation, then one `Why it matters`
section and one `What to do next` section. Keep the initial page documents to
roughly 150 to 250 words. Add deeper guides only when a real user need appears.

Use the STE-Code Level 1 style rules supplied by Andrew for human-written
documentation:

- Use clear American English.
- Use short sentences.
- Use one thought per sentence.
- Use exact product nouns consistently.
- Avoid slang, inflated verbs, and em dashes.

The philosophy overview begins:

> Signal Loom governs AI agents without treating governance as a barrier.
> An agent can act when it has a clear identity, defined limits, and evidence
> for its actions. Agency needs accountability. Identity is earned and bounded.
> Evidence matters more than claims. Governance should guide action and make
> safe work easier.

## Container and Delivery Design

Add a new static workload:

```text
d2-signalloom/apps/docs-signalloom/
  src/content/docs/
  scripts/generate-page-help.ts
  scripts/check-page-help-contract.ts
  astro.config.mjs
  Dockerfile
```

Build Starlight to static files. Copy the output into an unprivileged nginx
image. Apply the same image evidence pattern as `dashboard-signalloom`:

- SPDX SBOM
- SLSA provenance
- cosign signature
- local Kind image verification

Add to `d2-signalloom/apps/fe-signalloom/base/`:

- `docs-deployment.yaml`
- `docs-service.yaml`
- dashboard-to-docs and Gateway-to-docs NetworkPolicy rules
- a direct `HTTPRoute` prefix match for `/docs`
- Kustomize resources

The direct Gateway rule must take precedence over the dashboard SPA route. Do
not proxy documentation through dashboard nginx. The initial canonical URL is
`/docs/current/`. Dashboard and documentation images use the same artifact tag
in the local lifecycle.

## Delivery Sequence

1. Add the dashboard route catalogue without changing rendered routes.
2. Add Starlight content and frontmatter for every covered route.
3. Add the generator and bidirectional contract check.
4. Add `PageHelp` and replace page-title ad hoc help only where appropriate.
5. Add the docs container, service, policies, and Gateway route.
6. Add build, unit, BATS, and browser checks.
7. Build, sign, deploy, and verify both images from one artifact tag.

## Verification Plan

| Layer | Check |
|---|---|
| Contract | Missing, duplicate, and orphaned `docId` fixtures fail the checker. |
| Dashboard | Every protected route resolves a page-help item and `More help` href. |
| Docs | Starlight build produces each page from frontmatter. |
| Container | Docs image serves `/docs/current/` and a representative page. |
| Gateway | `/docs` reaches docs; `/agents` remains an SPA route. |
| Browser | Tooltip opens by keyboard, gives a page-specific explanation, and follows `More help`. |
| Supply chain | Docs image has SBOM, provenance, and verified signature. |

## Explicit Deferrals

- API reference generation
- Documentation authentication
- CMS or editing UI
- Historical documentation versions
- Automatic prose generation
- Translation

These can follow once page-help coverage proves useful.
