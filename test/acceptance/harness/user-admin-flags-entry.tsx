// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Entry point for the User Administration and Feature Flags acceptance harness.
 *
 * Renders the real UsersPage, UserTable, InviteUserModal, EditUserModal, Sidebar,
 * FeatureGate, and NotFoundPage with full routing and OpenFeature integration.
 */
import React, { useState, useMemo } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

import { AppContext, type AppContextType } from '../../../d2-signalloom/apps/dashboard-signalloom/src/App'
import { FeatureFlagProvider } from '../../../d2-signalloom/apps/dashboard-signalloom/src/providers/FeatureFlagProvider'
import FeatureGate from '../../../d2-signalloom/apps/dashboard-signalloom/src/components/common/FeatureGate'
import Sidebar from '../../../d2-signalloom/apps/dashboard-signalloom/src/components/Sidebar'
import UsersPage from '../../../d2-signalloom/apps/dashboard-signalloom/src/pages/admin/UsersPage'
import FeaturesPage from '../../../d2-signalloom/apps/dashboard-signalloom/src/pages/admin/FeaturesPage'
import NotFoundPage from '../../../d2-signalloom/apps/dashboard-signalloom/src/pages/NotFoundPage'
import Settings from '../../../d2-signalloom/apps/dashboard-signalloom/src/views/Settings'
import { currentTenantFromUrl, isSuperadminFromUrl } from './user-admin-flags-auth-stub'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: false,
      refetchOnWindowFocus: false,
      staleTime: 0,
    },
  },
})

function HarnessApp(): React.JSX.Element {
  const initialTenant = currentTenantFromUrl()
  const initialSuper = isSuperadminFromUrl()

  const [tenant, setTenant] = useState<string>(initialTenant)
  const [superadmin, setSuperadmin] = useState<boolean>(initialSuper)
  const [cluster, setCluster] = useState<string>('osramp-kind')
  const [demoMode, setDemoMode] = useState<boolean>(false)
  const [isPreferencesModalOpen, setIsPreferencesModalOpen] = useState<boolean>(false)

  const appContextValue = useMemo<AppContextType>(() => ({
    superadmin,
    setSuperadmin,
    cluster,
    setCluster,
    tenant,
    setTenant,
    demoMode,
    setDemoMode,
    cookiePreferences: { analytics: false, functional: true },
    setCookiePreferences: () => {},
    hasConsent: true,
    showBanner: false,
    dismissBanner: () => {},
    openPreferencesModal: () => setIsPreferencesModalOpen(true),
    closePreferencesModal: () => setIsPreferencesModalOpen(false),
    isPreferencesModalOpen,
  }), [superadmin, cluster, tenant, demoMode, isPreferencesModalOpen])

  return (
    <AppContext.Provider value={appContextValue}>
      <FeatureFlagProvider tenantId={tenant}>
        <div
          data-testid="harness-shell"
          data-harness-tenant={tenant}
          data-harness-superadmin={String(superadmin)}
          style={{
            display: 'flex',
            minHeight: '100vh',
            background: 'var(--bg, #0B0E14)',
            color: 'var(--text, #E2E8F0)',
          }}
        >
          {/* Navigation Sidebar */}
          <Sidebar />

          {/* Main Content Area */}
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
            <main style={{ flex: 1, padding: '24px 32px', overflowY: 'auto' }}>
              <Routes>
                {/* User Administration & Features Route */}
                <Route path="/admin/users" element={<UsersPage />} />
                <Route path="/admin/features" element={<FeaturesPage />} />

                {/* Core Governance & Control Routes */}
                <Route path="/agents" element={<div data-testid="page-agents" style={{ padding: 24 }}><h1>Agents</h1></div>} />
                <Route path="/discovery" element={<div data-testid="page-discovery" style={{ padding: 24 }}><h1>Discovery</h1></div>} />
                <Route path="/compliance" element={<div data-testid="page-compliance" style={{ padding: 24 }}><h1>Compliance</h1></div>} />
                <Route path="/policies" element={<div data-testid="page-policies" style={{ padding: 24 }}><h1>Policies</h1></div>} />
                <Route path="/audit" element={<div data-testid="page-audit" style={{ padding: 24 }}><h1>Audit Trail</h1></div>} />
                <Route path="/settings" element={<Settings />} />
                <Route path="/federated-services" element={<div data-testid="page-federated" style={{ padding: 24 }}><h1>Federated Services</h1></div>} />

                {/* Feature-Gated Experimental & Demo Routes */}
                <Route
                  path="/collusion-access"
                  element={
                    <FeatureGate flag="collusion_access" fallback={<NotFoundPage />}>
                      <div data-testid="page-collusion" style={{ padding: 24 }}><h1>Collusion & Access</h1></div>
                    </FeatureGate>
                  }
                />
                <Route
                  path="/rbac-analysis"
                  element={
                    <FeatureGate flag="rbac_analysis" fallback={<NotFoundPage />}>
                      <div data-testid="page-rbac-analysis" style={{ padding: 24 }}><h1>RBAC Analysis</h1></div>
                    </FeatureGate>
                  }
                />
                <Route
                  path="/rbac-explorer"
                  element={
                    <FeatureGate flag="rbac_analysis" fallback={<NotFoundPage />}>
                      <div data-testid="page-rbac-explorer" style={{ padding: 24 }}><h1>RBAC Explorer</h1></div>
                    </FeatureGate>
                  }
                />
                <Route
                  path="/supercred"
                  element={
                    <FeatureGate flag="supercred" fallback={<NotFoundPage />}>
                      <div data-testid="page-supercred" style={{ padding: 24 }}><h1>SuperCredential Demo</h1></div>
                    </FeatureGate>
                  }
                />
                <Route
                  path="/fleet"
                  element={
                    <FeatureGate flag="demos_fleet" fallback={<NotFoundPage />}>
                      <div data-testid="page-fleet" style={{ padding: 24 }}><h1>Fleet Demo</h1></div>
                    </FeatureGate>
                  }
                />
                <Route
                  path="/fleet/audience"
                  element={
                    <FeatureGate flag="demos_fleet" fallback={<NotFoundPage />}>
                      <div data-testid="page-fleet-audience" style={{ padding: 24 }}><h1>Fleet Demo Audience</h1></div>
                    </FeatureGate>
                  }
                />
                <Route
                  path="/demos/fleet"
                  element={
                    <FeatureGate flag="demos_fleet" fallback={<NotFoundPage />}>
                      <div data-testid="page-demos-fleet" style={{ padding: 24 }}><h1>Fleet Demo</h1></div>
                    </FeatureGate>
                  }
                />

                {/* Fallbacks */}
                <Route path="/" element={<Navigate to="/admin/users" replace />} />
                <Route path="*" element={<NotFoundPage />} />
              </Routes>
            </main>
          </div>
        </div>
      </FeatureFlagProvider>
    </AppContext.Provider>
  )
}

const container = document.getElementById('root')
if (!container) throw new Error('user-admin-flags harness: #root element missing')

createRoot(container).render(
  <QueryClientProvider client={queryClient}>
    <BrowserRouter>
      <HarnessApp />
    </BrowserRouter>
  </QueryClientProvider>,
)
