# DESIGN.md: Signal Loom Dashboard

Visual design guide for `d2-signalloom/apps/dashboard-signalloom/`. Every new
page or component must match this surface to maintain visual consistency.

## Colour System

### CSS Variables (`:root` in `global.css`)

| Variable | Hex | Use |
|----------|-----|-----|
| `--bg` | `#020617` | Page background |
| `--surface` | `#0F172A` | Cards, sidebar, modals |
| `--surface2` | `#1E293B` | Table headers, hover states, elevated surfaces |
| `--border` | `#1E293B` | Card borders, dividers |
| `--border-subtle` | `#334155` | Input borders, secondary dividers |
| `--cyan` | `#06B6D4` | Primary accent: links, active nav, code highlights |
| `--violet` | `#8B5CF6` | Secondary accent: identity, policies |
| `--teal` | `#10B981` | Success: active, healthy, pass, good |
| `--amber` | `#D97706` | Warning: suspended, degraded, expiring |
| `--error` | `#DC2626` | Error: revoked, failed, critical |
| `--text` | `#F8FAFC` | Primary text |
| `--muted` | `#94A3B8` | Secondary text, labels, hints |
| `--slate-gray` | `#475569` | Tertiary: not classified, acknowledged |

### TypeScript Tokens (`styles/tokens.ts`)

```typescript
import { colors } from '../styles/tokens'
// colors.cyanLoom, colors.tealLoom, colors.irisViolet, colors.amber, colors.red, etc.
// statusColors maps lifecycle/compliance states to the token palette.
```

Use CSS variables in inline styles (`var(--cyan)`). Use TS tokens when computing
derived values (e.g. `hex(colors.tealLoom, 0.12)` for translucent pill backgrounds).

## CSS Classes

Three global utility classes (defined in `global.css`):

| Class | What it does |
|-------|-------------|
| `.card` | Surface container. `--surface` bg, `--border` border, 8px radius, 20px padding. |
| `.btn` | Button base. Inline-flex, 4px radius. Variants: `.btn-primary` (cyan), `.btn-secondary` (surface2), `.btn-danger` (error). |
| `.tag` | Status pill. 99px radius, 11px uppercase bold, 2px/8px padding. |

All other styles are **inline** using CSS variables. No CSS modules. No Tailwind.

## Page Anatomy

Every dashboard page follows this structure:

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

### Table header/cell styles
```typescript
// th: padding 9px 14px, color var(--muted), fontWeight 600, fontSize 11, uppercase
// td: padding 9px 14px, fontSize 13, color var(--text), whiteSpace nowrap
```

## Shared Components

| Component | Location | Use |
|-----------|----------|-----|
| `DashKit.tsx` | `components/` | StatCard, Section, Table, Pill, td/hex helpers |
| `StatusBadge` | `components/StatusBadge.tsx` | Lifecycle/risk/privilege/compliance/NHI status pills |
| `EmptyState` | `components/EmptyState.tsx` | Icon + title + body for empty data |
| `ErrorState` | `components/ErrorState.tsx` | Error message + retry button |
| `DonutChart` | `components/DonutChart.tsx` | Recharts PieChart wrapper |
| `DemoToggle` | `components/DemoToggle.tsx` | Bottom-right corner widget (demo/live switch) |

### StatusBadge Variants

```tsx
<StatusBadge status="active" variant="lifecycle" />   // teal
<StatusBadge status="high_risk" variant="risk" />      // amber
<StatusBadge status="fail" variant="compliance" />     // red
```

Variants: `lifecycle`, `risk`, `privilege`, `violation`, `compliance`, `nhi`.

### Pill (DashKit)

For inline status indicators outside the StatusBadge system:
```tsx
<Pill label="active" />    // teal bg at 12% opacity
<Pill label="degraded" />  // amber
<Pill label="critical" />  // red
```

## Charts

Use **recharts** (already a dependency). Common pattern:

```tsx
import { PieChart, Pie, Cell } from 'recharts'

<PieChart width={160} height={160}>
  <Pie data={data} cx={80} cy={80} innerRadius={52} outerRadius={72} dataKey="value" paddingAngle={2}>
    {data.map(d => <Cell key={d.name} fill={d.color} />)}
  </Pie>
</PieChart>
```

Centre overlay text via absolute-positioned div inside a relative container.

## Typography

| Element | Size | Weight | Colour |
|---------|------|--------|--------|
| Page h1 | 22px | 700 | `--text` |
| Section h2 | 16px | 700 | `--text` |
| Section hint | 12px | 400 | `--muted` |
| Table header | 11px | 600 | `--muted`, uppercase, 0.05em tracking |
| Table cell | 13px | 400 | `--text` |
| Stat label | 11px | 400 | `--muted`, uppercase, 0.06em tracking |
| Stat value | 26px | 700 | accent colour |
| Stat sub | 12px | 400 | `--muted` |
| Code inline | 12px | monospace | `--cyan` (paths/ids) or `--violet` (policies) |

Font stack: `Arial, Helvetica, sans-serif` (inherited from body).

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

Active state: `color: var(--cyan)`, `background: rgba(6,182,212,0.10)`, `fontWeight: 600`.
Inactive: `color: var(--muted)`, `fontWeight: 400`.

The Compliance nav item shows a red badge count when `failingControls > 0`.

## Adding a new page

1. Create `src/pages/MyPage.tsx`. Default-export a component.
2. Lazy-import in `App.tsx`: `const MyPage = lazy(() => import('./pages/MyPage'))`
3. Add route in `App.tsx`: `<Route path="/my-page" element={<ProtectedRoute><MyPage /></ProtectedRoute>} />`
4. Add nav entry in `Sidebar.tsx` NAV array (before Settings).
5. Use `DashKit` components (StatCard, Section, Table, Pill) for layout consistency.
6. Write a vitest test at `src/pages/MyPage.test.tsx`.
7. Add the route to `smoke.spec.ts` PAGES array.
8. Rebuild: `make signalloom-dashboard-image`, then rollout restart, then restart port-forward.

## Dependencies

No new npm dependencies for mock/demo pages. Use what's already available:
- `recharts` for charts
- `react-router-dom` for routing
- `axios` for API calls (via `api/client.ts`)
- `oidc-client-ts` and `react-oidc-context` for auth

## Background Images

Static assets go in `public/`. File permissions must be `644` (nginx uid 101).
Reference as `url(/filename.png)` in inline styles.
