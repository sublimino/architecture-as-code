import { lazy, Suspense } from 'react'
import { Route, Routes } from 'react-router-dom'
import { Sidebar } from './components/Sidebar'

const OverviewPage = lazy(() => import('./pages/OverviewPage'))
const AgentsPage = lazy(() => import('./pages/AgentsPage'))
const CompliancePage = lazy(() => import('./pages/CompliancePage'))
const AuditPage = lazy(() => import('./pages/AuditPage'))
const TopologyPage = lazy(() => import('./pages/TopologyPage'))
const SpecialistPage = lazy(() => import('./pages/SpecialistPage'))
const SettingsPage = lazy(() => import('./pages/SettingsPage'))
const DesignSystemPage = lazy(() => import('./pages/DesignSystemPage'))
const NotFoundPage = lazy(() => import('./pages/NotFoundPage'))

function LoadingPage() { return <div className="page-loading" role="status"><span /><p>Composing the evidence view…</p></div> }

export default function App() {
  return <div className="app-shell"><Sidebar /><main id="main-content" className="main-content"><Suspense fallback={<LoadingPage />}><Routes><Route path="/" element={<OverviewPage />} /><Route path="/agents" element={<AgentsPage />} /><Route path="/compliance" element={<CompliancePage />} /><Route path="/audit" element={<AuditPage />} /><Route path="/topology" element={<TopologyPage />} /><Route path="/cryptography" element={<SpecialistPage />} /><Route path="/federated-services" element={<SpecialistPage />} /><Route path="/collusion-access" element={<SpecialistPage />} /><Route path="/rbac-analysis" element={<SpecialistPage />} /><Route path="/rbac-explorer" element={<SpecialistPage />} /><Route path="/supercred" element={<SpecialistPage />} /><Route path="/settings" element={<SettingsPage />} /><Route path="/design-system" element={<DesignSystemPage />} /><Route path="*" element={<NotFoundPage />} /></Routes></Suspense></main></div>
}
