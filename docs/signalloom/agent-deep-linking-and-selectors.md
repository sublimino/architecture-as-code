# Agent Deep Linking and Query Selectors

## 1. Overview and Purpose

This document specifies the agent deep linking architecture for the Signal Loom dashboard.
Operators must inspect agents quickly across different dashboard views.
These views include audit trails, network tests, discovery tables, and topology graphs.

The navigation system links directly to agent dossiers.
When an exact agent ID exists, the link opens the agent overview dossier.
When an identifier is ambiguous, the link opens a filtered search query.
This design prevents dead navigation links and navigation failures.

## 2. Architecture and Data Flow

The navigation subsystem contains three modular components:

- `agentQuerySelectors.ts`: Parses and matches structured query selector clauses.
- `agentDeepLink.ts`: Resolves navigation targets, normalizes prefixes, and constructs URLs.
- `AgentDeepLink.tsx`: Renders visual links and badges with five distinct styles.

The data flow follows strict unidirectional principles:

```
Identifier or Selector String
        │
        ▼
resolveDeepLinkTarget() ────► Normalize Prefixes (sa, id, instance, spiffe)
        │
        ▼
buildAgentDeepLink()    ────► Generate Route: /agents/:id OR /agents?selector=:query
        │
        ▼
<AgentDeepLink />       ────► Render Accessible UI Link or Badge
```

## 3. Query Selector Syntax

The search engine supports structured query selector prefixes.
Prefixes allow operators to search by workload identity and runtime metadata.

| Prefix | Alternate Names | Description | Example |
|---|---|---|---|
| `id:` | `uuid:` | Matches unique agent identifier or UUID. | `id:agent-sir-lancelot` |
| `sa:` | `serviceaccount:`, `k8s:sa:` | Matches Kubernetes service account name. | `sa:agent-cardvault-sa` |
| `instance:` | `pod:`, `pod_uid:` | Matches specific container or pod instance UID. | `instance:pod-987` |
| `spiffe:` | none | Matches SPIFFE identity URI or path segment. | `spiffe:agent-triage-sa` |
| `ns:` | `namespace:` | Filters workloads by Kubernetes namespace. | `ns:fe-signalloom-agents` |
| `state:` | `status:` | Filters workloads by runtime execution status. | `state:stunned` |
| `tenant:` | none | Filters workloads by tenant identifier. | `tenant:prod` |
| `tag:` | none | Matches arbitrary user-defined metadata tag. | `tag:llm` |

The parser accepts bare strings without prefixes.
Bare strings match against agent names, IDs, and descriptions.

## 4. Normalization and Resolution Rules

Different systems express identities in distinct formats.
For example, SPIFFE identities include full URIs.
Kubernetes manifests reference service accounts with custom prefixes.

The helper function `normalizeSelectorPrefix()` canonicalizes these variants:
- It maps `serviceaccount` to `sa`.
- It maps `uuid` to `id`.
- It maps `pod` and `pod_uid` to `instance`.

The helper function `resolveDeepLinkTarget()` checks available agents.
If the input matches a unique agent ID, it returns an agent dossier target.
If the input matches an agent service account, it returns an agent dossier target.
If the input is an unassigned selector, it returns a filtered search target.

## 5. UI Component Specification

The `<AgentDeepLink />` component renders navigation targets.
It wraps the router-resilient `<SafeLink />` primitive.
Inside React Router context, it renders a React Router `<Link />`.
Outside router context, it renders a standard HTML anchor tag.

The component provides five visual variants:

1. `link`: Standard text link with cyan hover transition.
2. `badge`: Cyan highlight badge with rounded borders for table rows.
3. `chip`: Monospace surface chip for Kubernetes and SPIFFE selectors.
4. `pill`: Rounded pill tag for status and instance indicators.
5. `subtle`: Muted secondary link for audit actors and timestamps.

### Usage Example

```tsx
import AgentDeepLink from './components/AgentDeepLink'

// Direct dossier link with trailing arrow
<AgentDeepLink
  target="agent-cardvault"
  label="agent-cardvault"
  variant="badge"
  showIcon={true}
/>

// Kubernetes selector chip
<AgentDeepLink
  target="k8s:sa:planner"
  variant="chip"
/>
```

## 6. Verification and Testing Procedures

All deep linking code requires rigorous testing.
Follow these procedural steps to verify changes:

1. Run unit tests for selector matching and deep link resolution.
2. Run component tests for the visual variants.
3. Run the design system page tests to verify gallery specimens.
4. Build and verify the production dashboard bundle.
5. Execute end-to-end acceptance tests against the cluster.
