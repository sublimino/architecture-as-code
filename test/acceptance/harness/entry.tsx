/**
 * Mount point for the cluster-free streaming harness.
 *
 * Renders the REAL SuperCredInstructorPanel — the same module the dashboard
 * ships — against the scripted runner in server.ts. This file is a `createRoot`
 * call. It reimplements nothing and it styles nothing.
 *
 * ─── Why there is no theme code here any more ──────────────────────────────
 *
 * It used to copy the THEMES table onto `document.documentElement.style` and
 * set the body background by hand, on the reasoning that the harness only
 * needed the CSS custom properties StreamingLogBlock reads. That produced a
 * page with the app's COLOURS and the browser's TYPOGRAPHY, which is not the
 * app — and typography is exactly what the scroll assertions measure. A log
 * block whose lines lay out at a different height is a different box, and
 * "the log never overflowed" is what that mistake looks like from the outside.
 *
 * index.html now links the app's real `styles/global.css`, which carries the
 * `:root` palette (byte-for-byte the values themes.ts asserts against), the
 * font stack, the base font-size and line-height, and the `.card` / `.btn`
 * classes the panel uses by name. Dark is the default in that file, so there is
 * nothing left to set here: duplicating it would be a second source of truth
 * for the one thing themes.test.ts exists to keep single.
 */
import { createRoot } from 'react-dom/client'
import SuperCredInstructorPanel from '../../../d2-signalloom/apps/dashboard-signalloom/src/components/SuperCredInstructorPanel'

const root = document.getElementById('root')
if (!root) throw new Error('harness: #root is missing from index.html')

createRoot(root).render(<SuperCredInstructorPanel superadmin onRefreshClients={() => {}} />)
