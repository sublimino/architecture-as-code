/**
 * Mount point for the cluster-free streaming harness.
 *
 * Renders the REAL SuperCredInstructorPanel — the same module the dashboard
 * ships — against the scripted runner in server.ts. Nothing here reimplements
 * any part of the component under test; the file is a `createRoot` call and a
 * theme.
 *
 * The theme comes from the app's own THEMES table rather than from a
 * hand-written block of CSS variables. StreamingLogBlock colours every token it
 * renders with `var(--cyan)`, `var(--error)` and friends, so a harness that
 * invented its own values would be rendering a different component and would
 * drift the moment themes.ts changed. styles/themes.ts is already asserted
 * byte-for-byte against global.css by themes.test.ts, so borrowing it keeps the
 * harness honest for free.
 */
import { createRoot } from 'react-dom/client'
import SuperCredInstructorPanel from '../../../d2-signalloom/apps/dashboard-signalloom/src/components/SuperCredInstructorPanel'
import { THEMES, DEFAULT_THEME } from '../../../d2-signalloom/apps/dashboard-signalloom/src/styles/themes'

for (const [name, value] of Object.entries(THEMES[DEFAULT_THEME])) {
  document.documentElement.style.setProperty(name, value)
}
document.body.style.background = 'var(--bg)'
document.body.style.color = 'var(--text)'

const root = document.getElementById('root')
if (!root) throw new Error('harness: #root is missing from index.html')

createRoot(root).render(<SuperCredInstructorPanel superadmin onRefreshClients={() => {}} />)
