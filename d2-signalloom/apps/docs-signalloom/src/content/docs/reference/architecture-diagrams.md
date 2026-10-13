---
title: Architecture diagrams
description: Read the deployment architecture diagrams for each Signal Loom target platform.
---

This page publishes the deployment architecture diagrams for each Signal Loom
target platform. Each diagram is available as a rendered SVG, an editable
Draw.io SVG, the native Draw.io XML, and a high-resolution PNG.

:::caution[Known limitation: these diagrams are not access-controlled]
The documentation portal serves every page and every asset to any caller that
reaches it, including callers on the public tunnel. These diagrams are
therefore readable without a superadmin role, and without any role at all.

Gate this page behind the superadmin check before production go-live. The
`/fleet-api/` and `/dashboard/` routes in `d2-signalloom/apps/dashboard-signalloom/nginx.conf`
already show the pattern: an `auth_request` subrequest to
`GET /api/v1/auth/check`, which answers 204 for a superadmin and 403 for every
other caller. Tracked in [Current limits and roadmap](/docs/reference/roadmap/).
:::

## Platform baseline (available now)

### Sovereign Kind, air-gapped

The single-node foundation that `make up` builds. No cloud dependency.

![Sovereign Kind air-gapped architecture](/docs/diagrams/osramp-kind-sovereign-airgap.svg)

- Editable vector SVG: [osramp-kind-sovereign-airgap.drawio.svg](/docs/diagrams/osramp-kind-sovereign-airgap.drawio.svg)
- Native Draw.io XML: [osramp-kind-sovereign-airgap.drawio](/docs/diagrams/osramp-kind-sovereign-airgap.drawio)
- High-resolution raster PNG: [osramp-kind-sovereign-airgap.png](/docs/diagrams/osramp-kind-sovereign-airgap.png)

Component-level call diagrams, generated from the repository, moved to [Internal Architecture](/docs/reference/internal-architecture/).

## Roadmap platforms

The three cloud diagrams below describe planned deployment targets. They are
design records, not descriptions of a running estate. Read
[Current limits and roadmap](/docs/reference/roadmap/) for the phase that owns
each target.

### Amazon Web Services, EKS

![AWS multi-tenant SaaS architecture](/docs/diagrams/osramp-aws-multitenant-saas.svg)

- Editable vector SVG: [osramp-aws-multitenant-saas.drawio.svg](/docs/diagrams/osramp-aws-multitenant-saas.drawio.svg)
- Native Draw.io XML: [osramp-aws-multitenant-saas.drawio](/docs/diagrams/osramp-aws-multitenant-saas.drawio)
- High-resolution raster PNG: [osramp-aws-multitenant-saas.png](/docs/diagrams/osramp-aws-multitenant-saas.png)

### Google Cloud Platform, GKE

![GCP multi-tenant SaaS architecture](/docs/diagrams/osramp-gcp-multitenant-saas.svg)

- Editable vector SVG: [osramp-gcp-multitenant-saas.drawio.svg](/docs/diagrams/osramp-gcp-multitenant-saas.drawio.svg)
- Native Draw.io XML: [osramp-gcp-multitenant-saas.drawio](/docs/diagrams/osramp-gcp-multitenant-saas.drawio)
- High-resolution raster PNG: [osramp-gcp-multitenant-saas.png](/docs/diagrams/osramp-gcp-multitenant-saas.png)

### Microsoft Azure, AKS

![Azure multi-tenant SaaS architecture](/docs/diagrams/osramp-azure-multitenant-saas.svg)

- Editable vector SVG: [osramp-azure-multitenant-saas.drawio.svg](/docs/diagrams/osramp-azure-multitenant-saas.drawio.svg)
- Native Draw.io XML: [osramp-azure-multitenant-saas.drawio](/docs/diagrams/osramp-azure-multitenant-saas.drawio)
- High-resolution raster PNG: [osramp-azure-multitenant-saas.png](/docs/diagrams/osramp-azure-multitenant-saas.png)

## Where the diagram files live

Every diagram has one home in the repository:
`d2-signalloom/apps/docs-signalloom/public/diagrams/`. The documentation image
build context is that application directory, so a diagram published here must
live inside it. The repository specification documents link to the same files
from that path.

To change a diagram, edit the `.drawio` source and regenerate the `.drawio.svg`,
`.svg`, and `.png` outputs from it.
