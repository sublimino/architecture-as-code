// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Authentication and principal stub for the user administration and feature flags harness.
 *
 * Provides stable OIDC identity and token generation for both superadmin
 * (demo-user@signalloom.local) and tenant-scoped principals (e.g. kusari, acme).
 */
import React from 'react'
import axios, { type AxiosInstance } from 'axios'

export const LOGGED_OUT_KEY = 'signalloom:logged-out'
export const hasAuthParams = () => false

export const oidcConfig = {
  authority: 'https://dex.signalloom.local',
  client_id: 'signalloom-dashboard',
  redirect_uri: 'http://localhost:5173/callback',
}

export function isPublicRoute(pathname: string): boolean {
  return pathname === '/login' || pathname === '/callback'
}

export function OidcProvider({ children }: { children: React.ReactNode }) {
  return <>{children}</>
}

function queryParam(key: string): string | null {
  try {
    return new URLSearchParams(window.location.search).get(key)
  } catch {
    return null
  }
}

export function currentTenantFromUrl(): string {
  return queryParam('tenant') ?? 'tenant-demo'
}

export function isSuperadminFromUrl(): boolean {
  const superParam = queryParam('superadmin')
  if (superParam !== null) {
    return superParam === 'true' || superParam === '1'
  }
  const tenant = currentTenantFromUrl()
  // By default, demo-user and kusari admin are superadmins
  return tenant === 'tenant-demo' || tenant === 'kusari'
}

export function currentEmailFromUrl(): string {
  const tenant = currentTenantFromUrl()
  if (tenant === 'kusari') {
    return 'admin@kusari.demo'
  }
  if (tenant === 'tenant-acme') {
    return 'operator@acme.demo'
  }
  return 'demo-user@signalloom.local'
}

/**
 * Stable module-scope auth token reflecting active tenant and superadmin privilege.
 */
export function buildAuthToken(tenant: string, isSuperadmin: boolean): string {
  const header = btoa(JSON.stringify({ alg: 'none', typ: 'JWT' }))
  const payload = btoa(
    JSON.stringify({
      sub: `usr-${tenant}-${isSuperadmin ? 'super' : 'user'}`,
      email: currentEmailFromUrl(),
      'https://signalloom.ai/tenant_id': tenant,
      tenant_id: tenant,
      is_superadmin: isSuperadmin,
      exp: Math.floor(Date.now() / 1000) + 3600,
    }),
  )
  return `${header}.${payload}.sig`
}

export function useAuth0() {
  const tenant = currentTenantFromUrl()
  const isSuperadmin = isSuperadminFromUrl()
  const email = currentEmailFromUrl()
  const token = buildAuthToken(tenant, isSuperadmin)

  return {
    user: {
      sub: `usr-${tenant}`,
      email,
      name: isSuperadmin ? 'Platform Superadmin' : 'Tenant Operator',
      'https://signalloom.ai/tenant_id': tenant,
      tenant_id: tenant,
    },
    getAccessTokenSilently: async (): Promise<string> => token,
    loginWithRedirect: async (): Promise<void> => {},
    logout: async (): Promise<void> => {},
    isAuthenticated: true,
    isLoading: false,
  }
}

export function useApi(): AxiosInstance {
  const tenant = currentTenantFromUrl()
  const isSuperadmin = isSuperadminFromUrl()
  const token = buildAuthToken(tenant, isSuperadmin)

  const instance = axios.create({
    baseURL: '',
    headers: {
      Authorization: `Bearer ${token}`,
    },
  })
  return instance
}
