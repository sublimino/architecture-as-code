# DESIGN.md: Signal Loom Dashboard

This guide defines visual rules for `d2-signalloom/apps/dashboard-signalloom/`.
Apply these styles to every new page and component to maintain UI consistency.

## Colour System

### CSS Variables (`:root` in `global.css`)

| Variable | Hex | Use |
|----------|-----|-----|
| `--bg` | `#020617` | Page background |
| `--surface` | `#0F172A` | Cards, sidebar, and modals |
| `--surface2` | `#1E293B` | Table headers, hover states, and elevated surfaces |
| `--border` | `#1E293B` | Card borders and dividers |
| `--border-subtle` | `#334155` | Input borders and secondary dividers |
| `--cyan` | `#06B6D4` | Primary accent: links, active navigation, and code highlights |
| `--violet` | `#8B5CF6` | Secondary accent: identity and policy elements |
| `--teal` | `#10B981` | Success states: active, healthy, and passed |
| `--amber` | `#D97706` | Warning states: suspended, degraded, and expiring |
| `--error` | `#DC2626` | Error states: revoked, failed, and critical |
| `--text` | `#F8FAFC` | Primary text |
| `--muted` | `#94A3B8` | Secondary text, labels, and helper hints |
| `--slate-gray` | `#475569` | Tertiary states: unclassified and acknowledged |

### TypeScript Tokens (`styles/tokens.ts`)

```typescript
import { colors } from '../styles/tokens'
// colors.cyanLoom, colors.tealLoom, colors.irisViolet, colors.amber, colors.red
// statusColors maps lifecycle and compliance states to palette tokens.
```

Use CSS variables in inline styles (`var(--cyan)`).
Use TypeScript tokens for calculated color values (for example, `hex(colors.tealLoom, 0.12)`).

## CSS Classes

The application defines three global utility classes in `global.css`:

| Class | Function |
|-------|----------|
| `.card` | Surface container with `--surface` background, `--border` border, 8px radius, and 20px padding. |
| `.btn` | Base button with inline-flex display and 4px radius. Variants: `.btn-primary`, `.btn-secondary`, `.btn-danger`. |
| `.tag` | Status indicator pill with 99px radius, 11px uppercase bold text, and 2px/8px padding. |

Apply all other styles through inline CSS variables.
Do not use CSS modules or Tailwind CSS.

## Page Anatomy

Construct dashboard pages with this layout structure:

```
<h1>  Page Title  (fontSize: 22, fontWeight: 700)
<p>   Subtitle    (fontSize: 13, color: var(--muted), maxWidth ~720-780px)

<div> Stat Cards  (flex row, gap: 14, flexWrap: wrap, marginBottom: 28)
  StatCard × N    (DashKit.tsx: label, value, sub, accent)

<Section>         (DashKit.tsx: h2 title + hint span, marginBottom: 26)
  <Table>         (DashKit.tsx: .card with table, header row in --surface2)
  or <div>        (card grid, chart + table side-by-side)
```

### StatCard
```tsx
<StatCard label="Trust anchors" value="4" sub="root + intermediate CAs" accent="var(--cyan)" />
```

### Section
```tsx
<Section title="Cluster Root of Trust" hint="certificate authority chain">
  <Table headers={['Name', 'Role', 'Status']}>
    <tr>...</tr>
  </Table>
</Section>
```

### Table Styles
```typescript
// th: padding 9px 14px, color var(--muted), fontWeight 600, fontSize 11, uppercase
// td: padding 9px 14px, fontSize 13, color var(--text), whiteSpace nowrap
```

## Shared Components

| Component | Location | Use |
|-----------|----------|-----|
| `DashKit.tsx` | `components/` | StatCard, Section, Table, Pill, and formatting helpers |
| `StatusBadge` | `components/StatusBadge.tsx` | Status pills for lifecycle, risk, privilege, compliance, and NHI |
| `EmptyState` | `components/EmptyState.tsx` | Displays icon, title, and description for empty data sets |
| `ErrorState` | `components/ErrorState.tsx` | Displays error messages and a retry action button |
| `DonutChart` | `components/DonutChart.tsx` | Recharts wrapper for pie and donut charts |
| `DemoToggle` | `components/DemoToggle.tsx` | Toggles between demo mode and live API data |

### StatusBadge Variants

```tsx
<StatusBadge status="active" variant="lifecycle" />   // teal
<StatusBadge status="high_risk" variant="risk" />      // amber
<StatusBadge status="fail" variant="compliance" />     // red
```

Available variants include `lifecycle`, `risk`, `privilege`, `violation`, `compliance`, and `nhi`.

### Pill Component (`DashKit`)

Use the `Pill` component for inline indicators outside the `StatusBadge` system:

```tsx
<Pill label="active" />    // teal background with 12% opacity
<Pill label="degraded" />  // amber background
<Pill label="critical" />  // red background
```

## Charts

Build charts with the `recharts` library:

```tsx
import { PieChart, Pie, Cell } from 'recharts'

<PieChart width={160} height={160}>
  <Pie data={data} cx={80} cy={80} innerRadius={52} outerRadius={72} dataKey="value" paddingAngle={2}>
    {data.map(d => <Cell key={d.name} fill={d.color} />)}
  </Pie>
</PieChart>
```

Center overlay text inside a relative parent element using an absolute position container.

## Typography

| Element | Size | Weight | Colour |
|---------|------|--------|--------|
| Page h1 | 22px | 700 | `--text` |
| Section h2 | 16px | 700 | `--text` |
| Section hint | 12px | 400 | `--muted` |
| Table header | 11px | 600 | `--muted`, uppercase, 0.05em tracking |
| Table cell | 13px | 400 | `--text` |
| Stat label | 11px | 400 | `--muted`, uppercase, 0.06em tracking |
| Stat value | 26px | 700 | Accent colour |
| Stat sub | 12px | 400 | `--muted` |
| Inline code | 12px | monospace | `--cyan` (identifiers) or `--violet` (policies) |

Font stack: `Arial, Helvetica, sans-serif`.

## Sidebar Navigation

```typescript
const NAV = [
  { to: '/agents', label: 'Agents' },
  { to: '/compliance', label: 'Compliance' },
  { to: '/audit', label: 'Audit Trail' },
  { to: '/cryptography', label: 'Cryptography' },
  { to: '/federated-services', label: 'Federated Services' },
  { to: '/collusion-access', label: 'Collusion & Access' },
  { to: '/rbac-analysis', label: 'RBAC Analysis' },
  { to: '/settings', label: 'Settings' },
]
```

Navigation styles:
- Active link: `color: var(--cyan)`, `background: rgba(6,182,212,0.10)`, `fontWeight: 600`.
- Inactive link: `color: var(--muted)`, `fontWeight: 400`.

The Compliance item displays a red counter badge when `failingControls > 0`.

## Add a New Page

Follow these steps to add a dashboard page:

1. Create `src/pages/MyPage.tsx` and export a default component.
2. Add a lazy import in `App.tsx`: `const MyPage = lazy(() => import('./pages/MyPage'))`.
3. Add a route in `App.tsx`: `<Route path="/my-page" element={<ProtectedRoute><MyPage /></ProtectedRoute>} />`.
4. Add the route object to the `NAV` array in `Sidebar.tsx` before Settings.
5. Use `DashKit` components (`StatCard`, `Section`, `Table`, `Pill`) for layout structure.
6. Write unit tests in `src/pages/MyPage.test.tsx`.
7. Add the new path to the `PAGES` array in `smoke.spec.ts`.
8. Rebuild the container: run `make signalloom-dashboard-image`.
9. Restart the deployment and renew port-forward tunnels.

## External Dependencies

Do not install new npm dependencies for mock pages.
Use existing libraries:
- `recharts` for visual graphs
- `react-router-dom` for navigation
- `axios` via `api/client.ts` for network requests
- `oidc-client-ts` and `react-oidc-context` for authentication

## Static Image Assets

Store static images in `public/`.
Set file permissions to mode `644` for the nginx user (uid 101).
Reference images in inline styles as `url(/filename.png)`.
