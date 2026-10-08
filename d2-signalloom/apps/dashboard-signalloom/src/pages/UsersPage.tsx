// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React, { useState, useMemo, useCallback, useEffect, type CSSProperties } from 'react'
import { useSearchParams } from 'react-router-dom'
import DataTable, { type Column } from '../components/DataTable'
import EmptyState from '../components/EmptyState'
import {
  DEFAULT_USERS,
  PLATFORM_LEVELS,
  FEATURE_FLAGS,
  type PlatformAccessLevel,
  type PlatformUserWithPermissions,
} from '../data/defaultUsers'

// ─── StatCard Component ─────────────────────────────────────────────────────

function StatCard({
  label,
  value,
  sub,
  accent,
  testId,
}: {
  label: string
  value: string | number
  sub: string
  accent: string
  testId: string
}) {
  return (
    <div
      className="card"
      style={{
        flex: '1 1 200px',
        minWidth: 190,
        padding: '16px 18px',
        background: 'var(--surface)',
        border: '1px solid var(--border)',
        borderRadius: 8,
      }}
    >
      <div
        style={{
          fontSize: 11,
          color: 'var(--muted)',
          textTransform: 'uppercase',
          letterSpacing: '0.06em',
          marginBottom: 8,
          fontWeight: 600,
        }}
      >
        {label}
      </div>
      <div
        data-testid={testId}
        style={{
          fontSize: 26,
          fontWeight: 700,
          color: accent,
          lineHeight: 1,
        }}
      >
        {value}
      </div>
      <div
        style={{
          fontSize: 12,
          color: 'var(--muted)',
          marginTop: 6,
        }}
      >
        {sub}
      </div>
    </div>
  )
}

// ─── Helpers ────────────────────────────────────────────────────────────────

function getInitials(name: string): string {
  const parts = name.trim().split(/\s+/)
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase()
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase()
}

function formatDate(iso: string | null): string {
  if (!iso) return 'Never'
  try {
    const d = new Date(iso)
    return d.toLocaleDateString('en-US', {
      month: 'short',
      day: 'numeric',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    })
  } catch {
    return iso
  }
}

function formatRelativeTime(iso: string | null): string {
  if (!iso) return 'Never'
  try {
    const now = new Date('2026-10-08T13:30:00Z').getTime()
    const then = new Date(iso).getTime()
    const diffSec = Math.max(0, Math.floor((now - then) / 1000))
    if (diffSec < 60) return 'Just now'
    const diffMin = Math.floor(diffSec / 60)
    if (diffMin < 60) return `${diffMin}m ago`
    const diffHr = Math.floor(diffMin / 60)
    if (diffHr < 24) return `${diffHr}h ago`
    const diffDays = Math.floor(diffHr / 24)
    return `${diffDays}d ago`
  } catch {
    return iso
  }
}

// ─── Pill Button Styling ────────────────────────────────────────────────────

function pillStyle(selected: boolean, accentColor = 'var(--cyan)'): CSSProperties {
  return {
    fontSize: 11.5,
    padding: '4px 10px',
    borderRadius: 14,
    cursor: 'pointer',
    fontWeight: selected ? 600 : 400,
    color: selected ? accentColor : 'var(--muted)',
    background: selected ? `color-mix(in srgb, ${accentColor} 16%, transparent)` : 'var(--surface2)',
    border: `1px solid ${selected ? `color-mix(in srgb, ${accentColor} 45%, transparent)` : 'var(--border)'}`,
    transition: 'all 0.15s ease',
  }
}

// ─── Columns Definition ─────────────────────────────────────────────────────

const COLUMNS: Column<PlatformUserWithPermissions>[] = [
  { key: 'display_name', label: 'User', sortable: true },
  { key: 'role', label: 'Role & Department', sortable: true },
  { key: 'platform_level', label: 'Platform Access Tiers' },
  { key: 'auth_methods', label: 'Auth & Credentials' },
  { key: 'can_claim_agents', label: 'Trust Anchors' },
  { key: 'status', label: 'Status & Last Login', sortable: true },
  { key: 'actions', label: 'Permissions' },
]

const AUTH_TAG_OPTIONS = ['All', 'user/pass', '2FA Active', 'SSO Ready', 'Service Key']
const LEVEL_OPTIONS: ('All' | 'Observe' | 'Govern' | 'Attest')[] = ['All', 'Observe', 'Govern', 'Attest']
const ROLE_OPTIONS = ['All', 'Admin', 'Editor', 'Viewer']
const STATUS_OPTIONS = ['All', 'Active', 'Invited', 'Suspended']

export default function UsersPage() {
  const [searchParams, setSearchParams] = useSearchParams()

  const urlSearch = searchParams.get('search') ?? ''
  const urlLevel = searchParams.get('level') ?? 'All'
  const urlTag = searchParams.get('tag') ?? 'All'
  const urlRole = searchParams.get('role') ?? 'All'
  const urlStatus = searchParams.get('status') ?? 'All'

  const [search, setSearch] = useState(urlSearch)
  const [levelFilter, setLevelFilter] = useState(urlLevel)
  const [tagFilter, setTagFilter] = useState(urlTag)
  const [roleFilter, setRoleFilter] = useState(urlRole)
  const [statusFilter, setStatusFilter] = useState(urlStatus)

  const [selectedUser, setSelectedUser] = useState<PlatformUserWithPermissions | null>(null)
  const users = DEFAULT_USERS

  // Synchronize state from URL query parameters if they change externally
  useEffect(() => {
    setSearch(searchParams.get('search') ?? '')
    setLevelFilter(searchParams.get('level') ?? 'All')
    setTagFilter(searchParams.get('tag') ?? 'All')
    setRoleFilter(searchParams.get('role') ?? 'All')
    setStatusFilter(searchParams.get('status') ?? 'All')
  }, [searchParams])

  // Update URL params upon filter changes
  const updateQuery = useCallback(
    (newSearch: string, newLevel: string, newTag: string, newRole: string, newStatus: string) => {
      const next = new URLSearchParams()
      if (newSearch.trim()) next.set('search', newSearch.trim())
      if (newLevel !== 'All') next.set('level', newLevel)
      if (newTag !== 'All') next.set('tag', newTag)
      if (newRole !== 'All') next.set('role', newRole)
      if (newStatus !== 'All') next.set('status', newStatus)
      setSearchParams(next, { replace: true })
    },
    [setSearchParams]
  )

  const handleSearchChange = (val: string) => {
    setSearch(val)
    updateQuery(val, levelFilter, tagFilter, roleFilter, statusFilter)
  }

  const handleLevelChange = (lvl: string) => {
    setLevelFilter(lvl)
    updateQuery(search, lvl, tagFilter, roleFilter, statusFilter)
  }

  const handleTagChange = (tag: string) => {
    setTagFilter(tag)
    updateQuery(search, levelFilter, tag, roleFilter, statusFilter)
  }

  const handleRoleChange = (role: string) => {
    setRoleFilter(role)
    updateQuery(search, levelFilter, tagFilter, role, statusFilter)
  }

  const handleStatusChange = (status: string) => {
    setStatusFilter(status)
    updateQuery(search, levelFilter, tagFilter, roleFilter, status)
  }

  const handleClearFilters = () => {
    setSearch('')
    setLevelFilter('All')
    setTagFilter('All')
    setRoleFilter('All')
    setStatusFilter('All')
    setSearchParams(new URLSearchParams(), { replace: true })
  }

  const isFilteringActive =
    search.trim() !== '' ||
    levelFilter !== 'All' ||
    tagFilter !== 'All' ||
    roleFilter !== 'All' ||
    statusFilter !== 'All'

  // Filtered users calculation
  const filteredUsers = useMemo(() => {
    const q = search.trim().toLowerCase()
    return users.filter((u) => {
      // Platform level filter
      if (levelFilter !== 'All') {
        const targetLevel = levelFilter.toLowerCase() as PlatformAccessLevel
        if (!u.platform_level.includes(targetLevel)) return false
      }

      // Tag filter
      if (tagFilter !== 'All') {
        if (!u.auth_methods.includes(tagFilter)) return false
      }

      // Role filter
      if (roleFilter !== 'All') {
        if (u.role.toLowerCase() !== roleFilter.toLowerCase()) return false
      }

      // Status filter
      if (statusFilter !== 'All') {
        if (u.status.toLowerCase() !== statusFilter.toLowerCase()) return false
      }

      // Free text search across name, email, department, role, title
      if (q) {
        const matchesName = u.display_name.toLowerCase().includes(q)
        const matchesEmail = u.email.toLowerCase().includes(q)
        const matchesDept = u.department?.toLowerCase().includes(q) ?? false
        const matchesRole = u.role.toLowerCase().includes(q)
        const matchesTitle = u.title?.toLowerCase().includes(q) ?? false
        if (!matchesName && !matchesEmail && !matchesDept && !matchesRole && !matchesTitle) {
          return false
        }
      }

      return true
    })
  }, [users, search, levelFilter, tagFilter, roleFilter, statusFilter])

  // Summary Metrics (always computed on full dataset)
  const totalIdentities = users.length
  const observeCount = users.filter((u) => u.platform_level.includes('observe')).length
  const governAnchorCount = users.filter((u) => u.platform_level.includes('govern') || u.can_claim_agents).length
  const attestOfficerCount = users.filter((u) => u.platform_level.includes('attest') || u.can_sign_attestations).length

  // CSV Export
  const handleExportCsv = () => {
    const headers = [
      'ID',
      'Display Name',
      'Email',
      'Role',
      'Department',
      'Title',
      'Status',
      'Auth Methods',
      'Platform Levels',
      'Can Claim Agents',
      'Can Sign Attestations',
      'SuperCred Cascade',
      'Cross-Plane Probes',
      'Multi-Agent Delegation',
      'eBPF Sentinel L7',
      'Continuous Attestation',
      'CEL Dynamic Evaluation',
      'Last Login',
      'Created At',
    ]

    const rows = filteredUsers.map((u) => [
      u.id,
      `"${u.display_name.replace(/"/g, '""')}"`,
      `"${u.email.replace(/"/g, '""')}"`,
      u.role,
      `"${(u.department ?? '').replace(/"/g, '""')}"`,
      `"${(u.title ?? '').replace(/"/g, '""')}"`,
      u.status,
      `"${u.auth_methods.join('; ')}"`,
      `"${u.platform_level.join('; ')}"`,
      u.can_claim_agents ? 'TRUE' : 'FALSE',
      u.can_sign_attestations ? 'TRUE' : 'FALSE',
      u.feature_flags.supercred_cascade ? 'TRUE' : 'FALSE',
      u.feature_flags.cross_plane_probes ? 'TRUE' : 'FALSE',
      u.feature_flags.multi_agent_delegation ? 'TRUE' : 'FALSE',
      u.feature_flags.ebpf_sentinel_l7 ? 'TRUE' : 'FALSE',
      u.feature_flags.continuous_attestation ? 'TRUE' : 'FALSE',
      u.feature_flags.cel_dynamic_evaluation ? 'TRUE' : 'FALSE',
      u.last_login_at ?? 'Never',
      u.created_at,
    ])

    const csvString = [headers.join(','), ...rows.map((r) => r.join(','))].join('\n')
    const blob = new Blob([csvString], { type: 'text/csv;charset=utf-8;' })
    const url = URL.createObjectURL(blob)
    const link = document.createElement('a')
    link.href = url
    link.download = `signal-loom-users-matrix-${new Date().toISOString().slice(0, 10)}.csv`
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
    URL.revokeObjectURL(url)
  }

  // Close modal on Escape
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setSelectedUser(null)
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [])

  return (
    <div style={{ paddingBottom: 48 }}>
      {/* Header */}
      <div
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'flex-start',
          flexWrap: 'wrap',
          gap: 16,
          marginBottom: 24,
        }}
      >
        <div>
          <h1 style={{ fontSize: 24, fontWeight: 700, margin: '0 0 6px 0', letterSpacing: '-0.02em' }}>
            Users & Access Control
          </h1>
          <p style={{ fontSize: 13, color: 'var(--muted)', margin: 0, maxWidth: 840, lineHeight: 1.5 }}>
            Enterprise human identity anchoring for autonomous agent claims, multi-tier permissions, and cryptographic
            trust log endorsement. Bridge human authorization directly with machine attestation keys.
          </p>
        </div>

        <button
          type="button"
          className="btn btn-secondary"
          onClick={handleExportCsv}
          data-testid="export-users-csv"
          style={{
            display: 'inline-flex',
            alignItems: 'center',
            gap: 8,
            fontSize: 12,
            padding: '8px 14px',
            background: 'var(--surface2)',
            border: '1px solid var(--border)',
            borderRadius: 6,
            color: 'var(--text)',
            cursor: 'pointer',
            fontWeight: 500,
          }}
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
            <polyline points="7 10 12 15 17 10" />
            <line x1="12" y1="15" x2="12" y2="3" />
          </svg>
          Export Users Matrix (CSV)
        </button>
      </div>

      {/* Top Summary StatCards */}
      <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 28 }}>
        <StatCard
          label="Total Identities"
          value={totalIdentities}
          sub="enrolled enterprise identities"
          accent="var(--text)"
          testId="stat-total-identities"
        />
        <StatCard
          label="Observe Level Access"
          value={observeCount}
          sub="runtime telemetry & signal store"
          accent="var(--cyan)"
          testId="stat-observe-access"
        />
        <StatCard
          label="Govern & Claim Anchors"
          value={governAnchorCount}
          sub="containment & agent auto-claim"
          accent="var(--violet)"
          testId="stat-govern-anchors"
        />
        <StatCard
          label="Attestation Officers"
          value={attestOfficerCount}
          sub="cryptographic notary & trust log signers"
          accent="var(--teal)"
          testId="stat-attest-officers"
        />
      </div>

      {/* Super Data Table */}
      <DataTable
        columns={COLUMNS}
        data={filteredUsers}
        pageSize={10}
        testIdPrefix="users-table"
        toolbar={
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12, width: '100%' }}>
            {/* Top Toolbar: Search + Quick Stats */}
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 12 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, flex: '1 1 320px', maxWidth: 440 }}>
                <input
                  type="search"
                  aria-label="Search users by name, email, department, role"
                  placeholder="Search by name, email, department, role..."
                  value={search}
                  onChange={(e) => handleSearchChange(e.target.value)}
                  data-testid="users-search"
                  style={{
                    width: '100%',
                    fontSize: 12,
                    padding: '7px 12px',
                    color: 'var(--text)',
                    background: 'var(--surface2)',
                    border: '1px solid var(--border)',
                    borderRadius: 6,
                  }}
                />
              </div>

              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                {isFilteringActive && (
                  <button
                    type="button"
                    onClick={handleClearFilters}
                    data-testid="clear-filters"
                    style={{
                      fontSize: 11.5,
                      color: 'var(--amber)',
                      background: 'transparent',
                      border: 'none',
                      cursor: 'pointer',
                      textDecoration: 'underline',
                      padding: 0,
                    }}
                  >
                    Reset filters
                  </button>
                )}
                <span data-testid="users-count" style={{ fontSize: 12, color: 'var(--muted)' }}>
                  {filteredUsers.length} of {users.length} users shown
                </span>
              </div>
            </div>

            {/* Faceted Pill Filters Strip */}
            <div
              style={{
                display: 'flex',
                flexWrap: 'wrap',
                gap: 16,
                padding: '10px 14px',
                background: 'var(--surface2)',
                borderRadius: 8,
                border: '1px solid var(--border)',
                alignItems: 'center',
              }}
            >
              {/* Platform Level Facet */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase' }}>
                  Platform Level:
                </span>
                <div role="group" aria-label="Filter by Platform Level" style={{ display: 'flex', gap: 4 }}>
                  {LEVEL_OPTIONS.map((lvl) => {
                    const sel = levelFilter.toLowerCase() === lvl.toLowerCase()
                    const accent =
                      lvl === 'Observe'
                        ? 'var(--cyan)'
                        : lvl === 'Govern'
                        ? 'var(--violet)'
                        : lvl === 'Attest'
                        ? 'var(--teal)'
                        : 'var(--text)'
                    return (
                      <button
                        key={lvl}
                        type="button"
                        onClick={() => handleLevelChange(lvl)}
                        data-testid={`filter-level-${lvl.toLowerCase()}`}
                        aria-pressed={sel}
                        style={pillStyle(sel, accent)}
                      >
                        {lvl}
                      </button>
                    )
                  })}
                </div>
              </div>

              {/* Auth Tag Facet */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase' }}>
                  Auth Tag:
                </span>
                <div role="group" aria-label="Filter by Auth Tag" style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                  {AUTH_TAG_OPTIONS.map((tag) => {
                    const sel = tagFilter === tag
                    const slug = tag.toLowerCase().replace(/[^a-z0-9]/g, '-')
                    return (
                      <button
                        key={tag}
                        type="button"
                        onClick={() => handleTagChange(tag)}
                        data-testid={`filter-tag-${slug}`}
                        aria-pressed={sel}
                        style={pillStyle(sel, 'var(--teal)')}
                      >
                        {tag}
                      </button>
                    )
                  })}
                </div>
              </div>

              {/* Role Facet */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase' }}>
                  Role:
                </span>
                <div role="group" aria-label="Filter by Role" style={{ display: 'flex', gap: 4 }}>
                  {ROLE_OPTIONS.map((r) => {
                    const sel = roleFilter.toLowerCase() === r.toLowerCase()
                    return (
                      <button
                        key={r}
                        type="button"
                        onClick={() => handleRoleChange(r)}
                        data-testid={`filter-role-${r.toLowerCase()}`}
                        aria-pressed={sel}
                        style={pillStyle(sel, 'var(--cyan)')}
                      >
                        {r}
                      </button>
                    )
                  })}
                </div>
              </div>

              {/* Status Facet */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase' }}>
                  Status:
                </span>
                <div role="group" aria-label="Filter by Status" style={{ display: 'flex', gap: 4 }}>
                  {STATUS_OPTIONS.map((st) => {
                    const sel = statusFilter.toLowerCase() === st.toLowerCase()
                    const accent = st === 'Active' ? 'var(--teal)' : st === 'Invited' ? 'var(--cyan)' : 'var(--amber)'
                    return (
                      <button
                        key={st}
                        type="button"
                        onClick={() => handleStatusChange(st)}
                        data-testid={`filter-status-${st.toLowerCase()}`}
                        aria-pressed={sel}
                        style={pillStyle(sel, accent)}
                      >
                        {st}
                      </button>
                    )
                  })}
                </div>
              </div>
            </div>
          </div>
        }
        emptyState={
          <EmptyState
            kicker="No matching users found"
            body="Try adjusting your search query, platform tier, or authentication filter."
          />
        }
        renderRow={(user) => {
          const initials = getInitials(user.display_name)
          return (
            <tr
              key={user.id}
              data-testid={`user-row-${user.id}`}
              onClick={() => setSelectedUser(user)}
              style={{
                borderBottom: '1px solid var(--border)',
                cursor: 'pointer',
                transition: 'background 0.15s ease',
              }}
              className="user-table-row"
            >
              {/* 1. User (avatar, display name, email) */}
              <td style={{ ...DataTable.td, minWidth: 200 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                  <div
                    style={{
                      width: 34,
                      height: 34,
                      borderRadius: '50%',
                      background:
                        user.role === 'admin'
                          ? 'color-mix(in srgb, var(--violet) 25%, transparent)'
                          : 'color-mix(in srgb, var(--cyan) 20%, transparent)',
                      color: user.role === 'admin' ? 'var(--violet)' : 'var(--cyan)',
                      border: `1px solid ${
                        user.role === 'admin'
                          ? 'color-mix(in srgb, var(--violet) 50%, transparent)'
                          : 'color-mix(in srgb, var(--cyan) 40%, transparent)'
                      }`,
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      fontSize: 12,
                      fontWeight: 700,
                      flexShrink: 0,
                    }}
                  >
                    {initials}
                  </div>
                  <div>
                    <div style={{ fontWeight: 600, color: 'var(--text)', fontSize: 13 }}>{user.display_name}</div>
                    <div style={{ fontSize: 11.5, color: 'var(--muted)', fontFamily: 'monospace' }}>{user.email}</div>
                  </div>
                </div>
              </td>

              {/* 2. Role & Department */}
              <td style={{ ...DataTable.td, minWidth: 160 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 2 }}>
                  <span
                    style={{
                      display: 'inline-block',
                      padding: '2px 7px',
                      borderRadius: 4,
                      fontSize: 10.5,
                      fontWeight: 700,
                      textTransform: 'uppercase',
                      letterSpacing: '0.04em',
                      background:
                        user.role === 'admin'
                          ? 'color-mix(in srgb, var(--violet) 20%, transparent)'
                          : user.role === 'editor'
                          ? 'color-mix(in srgb, var(--cyan) 20%, transparent)'
                          : 'color-mix(in srgb, var(--muted) 20%, transparent)',
                      color:
                        user.role === 'admin'
                          ? 'var(--violet)'
                          : user.role === 'editor'
                          ? 'var(--cyan)'
                          : 'var(--text)',
                      border: `1px solid ${
                        user.role === 'admin'
                          ? 'color-mix(in srgb, var(--violet) 40%, transparent)'
                          : user.role === 'editor'
                          ? 'color-mix(in srgb, var(--cyan) 40%, transparent)'
                          : 'var(--border)'
                      }`,
                    }}
                  >
                    {user.role}
                  </span>
                </div>
                <div style={{ fontSize: 11.5, color: 'var(--muted)' }}>{user.department ?? 'General'}</div>
              </td>

              {/* 3. Platform Access Level badges (Observe [cyan], Govern [violet], Attest [teal]) */}
              <td style={{ ...DataTable.td, minWidth: 200 }}>
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  {user.platform_level.includes('observe') && (
                    <span
                      style={{
                        padding: '2px 8px',
                        borderRadius: 4,
                        fontSize: 11,
                        fontWeight: 600,
                        background: 'color-mix(in srgb, var(--cyan) 18%, transparent)',
                        color: 'var(--cyan)',
                        border: '1px solid color-mix(in srgb, var(--cyan) 40%, transparent)',
                      }}
                    >
                      Observe
                    </span>
                  )}
                  {user.platform_level.includes('govern') && (
                    <span
                      style={{
                        padding: '2px 8px',
                        borderRadius: 4,
                        fontSize: 11,
                        fontWeight: 600,
                        background: 'color-mix(in srgb, var(--violet) 18%, transparent)',
                        color: 'var(--violet)',
                        border: '1px solid color-mix(in srgb, var(--violet) 40%, transparent)',
                      }}
                    >
                      Govern
                    </span>
                  )}
                  {user.platform_level.includes('attest') && (
                    <span
                      style={{
                        padding: '2px 8px',
                        borderRadius: 4,
                        fontSize: 11,
                        fontWeight: 600,
                        background: 'color-mix(in srgb, var(--teal) 18%, transparent)',
                        color: 'var(--teal)',
                        border: '1px solid color-mix(in srgb, var(--teal) 40%, transparent)',
                      }}
                    >
                      Attest
                    </span>
                  )}
                </div>
              </td>

              {/* 4. Auth Tags */}
              <td style={{ ...DataTable.td, minWidth: 170 }}>
                <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
                  {user.auth_methods.map((tag) => (
                    <span
                      key={tag}
                      style={{
                        padding: '2px 6px',
                        borderRadius: 4,
                        fontSize: 11,
                        background:
                          tag === '2FA Active' || tag === 'SSO Ready'
                            ? 'color-mix(in srgb, var(--teal) 14%, transparent)'
                            : tag === 'Service Key' || tag === 'Notary Key'
                            ? 'color-mix(in srgb, var(--amber) 15%, transparent)'
                            : 'var(--surface2)',
                        color:
                          tag === '2FA Active' || tag === 'SSO Ready'
                            ? 'var(--teal)'
                            : tag === 'Service Key' || tag === 'Notary Key'
                            ? 'var(--amber)'
                            : 'var(--muted)',
                        border: '1px solid var(--border)',
                      }}
                    >
                      {tag}
                    </span>
                  ))}
                </div>
              </td>

              {/* 5. Trust Anchors */}
              <td style={{ ...DataTable.td, minWidth: 180 }}>
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  {user.can_claim_agents && (
                    <span
                      style={{
                        padding: '2px 7px',
                        borderRadius: 4,
                        fontSize: 10.5,
                        fontWeight: 600,
                        background: 'color-mix(in srgb, var(--violet) 18%, transparent)',
                        color: 'var(--violet)',
                        border: '1px solid color-mix(in srgb, var(--violet) 40%, transparent)',
                      }}
                    >
                      Claim Approver
                    </span>
                  )}
                  {user.can_sign_attestations && (
                    <span
                      style={{
                        padding: '2px 7px',
                        borderRadius: 4,
                        fontSize: 10.5,
                        fontWeight: 600,
                        background: 'color-mix(in srgb, var(--teal) 18%, transparent)',
                        color: 'var(--teal)',
                        border: '1px solid color-mix(in srgb, var(--teal) 40%, transparent)',
                      }}
                    >
                      Attestation Signer
                    </span>
                  )}
                  {!user.can_claim_agents && !user.can_sign_attestations && (
                    <span style={{ color: 'var(--muted)', fontSize: 11.5 }}>-</span>
                  )}
                </div>
              </td>

              {/* 6. Status & Last Login */}
              <td style={{ ...DataTable.td, minWidth: 140 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <span
                    style={{
                      width: 7,
                      height: 7,
                      borderRadius: '50%',
                      background:
                        user.status === 'active'
                          ? 'var(--teal)'
                          : user.status === 'invited'
                          ? 'var(--cyan)'
                          : 'var(--amber)',
                    }}
                  />
                  <span style={{ fontSize: 12, fontWeight: 500, textTransform: 'capitalize' }}>
                    {user.status}
                  </span>
                </div>
                <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                  {formatRelativeTime(user.last_login_at)}
                </div>
              </td>

              {/* 7. Actions */}
              <td style={{ ...DataTable.td, minWidth: 130 }}>
                <button
                  type="button"
                  data-testid={`btn-matrix-${user.id}`}
                  onClick={(e) => {
                    e.stopPropagation()
                    setSelectedUser(user)
                  }}
                  className="btn btn-secondary"
                  style={{
                    fontSize: 11,
                    padding: '4px 9px',
                    borderRadius: 4,
                    background: 'var(--surface2)',
                    border: '1px solid var(--border)',
                    color: 'var(--cyan)',
                    cursor: 'pointer',
                    fontWeight: 600,
                  }}
                >
                  View Matrix
                </button>
              </td>
            </tr>
          )
        }}
      />

      {/* Permissions Matrix Interactive Modal / Drawer */}
      {selectedUser && (
        <div
          data-testid="permissions-matrix-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="permissions-modal-title"
          style={{
            position: 'fixed',
            top: 0,
            left: 0,
            right: 0,
            bottom: 0,
            zIndex: 1200,
            display: 'flex',
            justifyContent: 'flex-end',
          }}
        >
          {/* Backdrop */}
          <div
            onClick={() => setSelectedUser(null)}
            style={{
              position: 'absolute',
              top: 0,
              left: 0,
              right: 0,
              bottom: 0,
              background: 'rgba(0, 0, 0, 0.65)',
              backdropFilter: 'blur(3px)',
            }}
          />

          {/* Drawer Panel */}
          <aside
            style={{
              position: 'relative',
              width: 620,
              maxWidth: '92vw',
              height: '100%',
              background: 'var(--surface)',
              borderLeft: '1px solid var(--border)',
              display: 'flex',
              flexDirection: 'column',
              boxShadow: '-10px 0 36px rgba(0, 0, 0, 0.6)',
              overflow: 'hidden',
              zIndex: 1,
            }}
          >
            {/* Header */}
            <div
              style={{
                padding: '20px 24px',
                borderBottom: '1px solid var(--border)',
                background: 'var(--surface2)',
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'flex-start',
                flexShrink: 0,
              }}
            >
              <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
                <div
                  style={{
                    width: 44,
                    height: 44,
                    borderRadius: '50%',
                    background:
                      selectedUser.role === 'admin'
                        ? 'color-mix(in srgb, var(--violet) 25%, transparent)'
                        : 'color-mix(in srgb, var(--cyan) 20%, transparent)',
                    color: selectedUser.role === 'admin' ? 'var(--violet)' : 'var(--cyan)',
                    border: `1px solid ${
                      selectedUser.role === 'admin'
                        ? 'color-mix(in srgb, var(--violet) 50%, transparent)'
                        : 'color-mix(in srgb, var(--cyan) 40%, transparent)'
                    }`,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    fontSize: 16,
                    fontWeight: 700,
                    flexShrink: 0,
                  }}
                >
                  {getInitials(selectedUser.display_name)}
                </div>
                <div>
                  <h2
                    id="permissions-modal-title"
                    style={{ fontSize: 18, fontWeight: 700, margin: '0 0 2px 0', color: 'var(--text)' }}
                  >
                    {selectedUser.display_name}
                  </h2>
                  <div style={{ fontSize: 12, color: 'var(--muted)', fontFamily: 'monospace' }}>
                    {selectedUser.email}
                  </div>
                  <div style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 4 }}>
                    {selectedUser.title ?? selectedUser.role} • {selectedUser.department ?? 'Organization'}
                  </div>
                </div>
              </div>

              <button
                type="button"
                data-testid="close-permissions-matrix"
                onClick={() => setSelectedUser(null)}
                aria-label="Close permissions matrix"
                style={{
                  background: 'transparent',
                  border: '1px solid var(--border)',
                  borderRadius: 6,
                  color: 'var(--muted)',
                  fontSize: 20,
                  cursor: 'pointer',
                  padding: '4px 10px',
                  lineHeight: 1,
                }}
              >
                &times;
              </button>
            </div>

            {/* Scrollable Content Body */}
            <div
              style={{
                flex: 1,
                overflowY: 'auto',
                padding: '24px',
                display: 'flex',
                flexDirection: 'column',
                gap: 24,
              }}
            >
              {/* Profile Meta Cards */}
              <div
                style={{
                  display: 'grid',
                  gridTemplateColumns: 'repeat(auto-fit, minmax(130px, 1fr))',
                  gap: 10,
                  padding: '12px 14px',
                  background: 'var(--surface2)',
                  borderRadius: 8,
                  border: '1px solid var(--border)',
                  fontSize: 12,
                }}
              >
                <div>
                  <div style={{ color: 'var(--muted)', fontSize: 11, marginBottom: 2 }}>Role</div>
                  <div style={{ fontWeight: 600, textTransform: 'capitalize', color: 'var(--text)' }}>
                    {selectedUser.role}
                  </div>
                </div>
                <div>
                  <div style={{ color: 'var(--muted)', fontSize: 11, marginBottom: 2 }}>Status</div>
                  <div style={{ fontWeight: 600, textTransform: 'capitalize', color: 'var(--teal)' }}>
                    {selectedUser.status}
                  </div>
                </div>
                <div>
                  <div style={{ color: 'var(--muted)', fontSize: 11, marginBottom: 2 }}>Last Login</div>
                  <div style={{ color: 'var(--text)' }}>{formatDate(selectedUser.last_login_at)}</div>
                </div>
                <div>
                  <div style={{ color: 'var(--muted)', fontSize: 11, marginBottom: 2 }}>Created</div>
                  <div style={{ color: 'var(--text)' }}>{formatDate(selectedUser.created_at)}</div>
                </div>
              </div>

              {/* Section 1: Platform Access Tiers (Observe, Govern, Attest) */}
              <section data-testid="modal-platform-levels">
                <div style={{ marginBottom: 12 }}>
                  <h3 style={{ fontSize: 13, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.06em', margin: 0 }}>
                    Platform Access Tiers
                  </h3>
                  <p style={{ fontSize: 12, color: 'var(--muted)', margin: '4px 0 0 0' }}>
                    Granular platform capability boundaries across telemetry observation, active control, and cryptographic attestation.
                  </p>
                </div>

                <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                  {(['observe', 'govern', 'attest'] as PlatformAccessLevel[]).map((levelKey) => {
                    const meta = PLATFORM_LEVELS[levelKey]
                    const hasAccess = selectedUser.platform_level.includes(levelKey)
                    return (
                      <div
                        key={levelKey}
                        style={{
                          background: hasAccess
                            ? `color-mix(in srgb, ${meta.tone} 6%, var(--surface2))`
                            : 'var(--surface2)',
                          border: `1px solid ${
                            hasAccess ? `color-mix(in srgb, ${meta.tone} 35%, transparent)` : 'var(--border)'
                          }`,
                          borderRadius: 8,
                          padding: '14px 16px',
                        }}
                      >
                        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
                          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                            <span
                              style={{
                                width: 9,
                                height: 9,
                                borderRadius: '50%',
                                background: hasAccess ? meta.tone : 'var(--muted)',
                              }}
                            />
                            <strong style={{ fontSize: 14, color: hasAccess ? meta.tone : 'var(--text)' }}>
                              {meta.title} Level
                            </strong>
                          </div>
                          <span
                            style={{
                              padding: '2px 8px',
                              borderRadius: 4,
                              fontSize: 11,
                              fontWeight: 700,
                              background: hasAccess
                                ? `color-mix(in srgb, ${meta.tone} 20%, transparent)`
                                : 'color-mix(in srgb, var(--muted) 15%, transparent)',
                              color: hasAccess ? meta.tone : 'var(--muted)',
                            }}
                          >
                            {hasAccess ? 'GRANTED' : 'NOT GRANTED'}
                          </span>
                        </div>

                        <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 10 }}>
                          {meta.description}
                        </div>

                        <ul style={{ margin: 0, paddingLeft: 18, fontSize: 11.5, color: hasAccess ? 'var(--text)' : 'var(--muted)' }}>
                          {meta.capabilities.map((cap, idx) => (
                            <li key={idx} style={{ marginBottom: 3, opacity: hasAccess ? 1 : 0.65 }}>
                              {cap}
                            </li>
                          ))}
                        </ul>
                      </div>
                    )
                  })}
                </div>
              </section>

              {/* Section 2: Active Proposal Feature Flags Matrix */}
              <section data-testid="modal-feature-flags">
                <div style={{ marginBottom: 12 }}>
                  <h3 style={{ fontSize: 13, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.06em', margin: 0 }}>
                    Active Feature Flags Matrix
                  </h3>
                  <p style={{ fontSize: 12, color: 'var(--muted)', margin: '4px 0 0 0' }}>
                    Autonomous governance proposal feature toggles delegated to this operator identity.
                  </p>
                </div>

                <div
                  style={{
                    background: 'var(--surface2)',
                    border: '1px solid var(--border)',
                    borderRadius: 8,
                    overflow: 'hidden',
                  }}
                >
                  {FEATURE_FLAGS.map((flag, idx) => {
                    const isActive = Boolean(selectedUser.feature_flags[flag.key])
                    return (
                      <div
                        key={flag.key}
                        style={{
                          display: 'flex',
                          justifyContent: 'space-between',
                          alignItems: 'center',
                          padding: '11px 14px',
                          borderBottom: idx === FEATURE_FLAGS.length - 1 ? 'none' : '1px solid var(--border)',
                          background: isActive ? 'color-mix(in srgb, var(--teal) 4%, transparent)' : 'transparent',
                        }}
                      >
                        <div style={{ maxWidth: '78%' }}>
                          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                            <code style={{ fontSize: 12, fontWeight: 600, color: isActive ? 'var(--cyan)' : 'var(--text)' }}>
                              {flag.label}
                            </code>
                          </div>
                          <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>{flag.description}</div>
                        </div>

                        <span
                          style={{
                            padding: '3px 9px',
                            borderRadius: 12,
                            fontSize: 10.5,
                            fontWeight: 700,
                            letterSpacing: '0.04em',
                            background: isActive
                              ? 'color-mix(in srgb, var(--teal) 20%, transparent)'
                              : 'color-mix(in srgb, var(--muted) 15%, transparent)',
                            color: isActive ? 'var(--teal)' : 'var(--muted)',
                            border: `1px solid ${isActive ? 'color-mix(in srgb, var(--teal) 45%, transparent)' : 'var(--border)'}`,
                          }}
                        >
                          {isActive ? 'ACTIVE' : 'INACTIVE'}
                        </span>
                      </div>
                    )
                  })}
                </div>
              </section>

              {/* Section 3: Human Identity Anchoring & Trust Log Audit Trail */}
              <section data-testid="modal-human-anchor">
                <div style={{ marginBottom: 12 }}>
                  <h3 style={{ fontSize: 13, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.06em', margin: 0 }}>
                    Human Identity Anchoring & Trust Log
                  </h3>
                  <p style={{ fontSize: 12, color: 'var(--muted)', margin: '4px 0 0 0' }}>
                    Cryptographic trust anchoring bridging human authorization with machine agent claims and trust log state receipts.
                  </p>
                </div>

                <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                  <div
                    style={{
                      background: 'var(--surface2)',
                      border: '1px solid var(--border)',
                      borderRadius: 8,
                      padding: '12px 16px',
                    }}
                  >
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
                      <strong style={{ fontSize: 13, color: 'var(--text)' }}>Agent Auto-Claim Anchor Authority</strong>
                      <span
                        style={{
                          fontSize: 11,
                          fontWeight: 700,
                          padding: '2px 8px',
                          borderRadius: 4,
                          background: selectedUser.can_claim_agents
                            ? 'color-mix(in srgb, var(--violet) 20%, transparent)'
                            : 'color-mix(in srgb, var(--muted) 15%, transparent)',
                          color: selectedUser.can_claim_agents ? 'var(--violet)' : 'var(--muted)',
                        }}
                      >
                        {selectedUser.can_claim_agents ? 'ENABLED' : 'DISABLED'}
                      </span>
                    </div>
                    <p style={{ fontSize: 11.5, color: 'var(--muted)', margin: 0 }}>
                      When enabled, this identity acts as a designated human anchor for autonomous agent discovery,
                      approving auto-claims, and binding machine credentials to organizational ownership.
                    </p>
                  </div>

                  <div
                    style={{
                      background: 'var(--surface2)',
                      border: '1px solid var(--border)',
                      borderRadius: 8,
                      padding: '12px 16px',
                    }}
                  >
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
                      <strong style={{ fontSize: 13, color: 'var(--text)' }}>Trust Log Notary & Attestation Signer</strong>
                      <span
                        style={{
                          fontSize: 11,
                          fontWeight: 700,
                          padding: '2px 8px',
                          borderRadius: 4,
                          background: selectedUser.can_sign_attestations
                            ? 'color-mix(in srgb, var(--teal) 20%, transparent)'
                            : 'color-mix(in srgb, var(--muted) 15%, transparent)',
                          color: selectedUser.can_sign_attestations ? 'var(--teal)' : 'var(--muted)',
                        }}
                      >
                        {selectedUser.can_sign_attestations ? 'AUTHORIZED' : 'STANDARD'}
                      </span>
                    </div>
                    <p style={{ fontSize: 11.5, color: 'var(--muted)', margin: 0 }}>
                      When authorized, this identity possesses cryptographic endorsement authority to sign trust log
                      state transitions, issue cosign/witness attestations, and seal immutable audit receipts.
                    </p>
                  </div>

                  <div
                    style={{
                      background: 'var(--surface2)',
                      border: '1px solid var(--border)',
                      borderRadius: 8,
                      padding: '12px 16px',
                    }}
                  >
                    <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)', marginBottom: 6 }}>
                      ENROLLED CREDENTIALS & KEYS
                    </div>
                    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                      {selectedUser.auth_methods.map((auth) => (
                        <span
                          key={auth}
                          style={{
                            padding: '3px 8px',
                            borderRadius: 4,
                            fontSize: 11,
                            background: 'var(--surface)',
                            border: '1px solid var(--border)',
                            color: 'var(--cyan)',
                            fontFamily: 'monospace',
                          }}
                        >
                          {auth}
                        </span>
                      ))}
                    </div>
                  </div>
                </div>
              </section>
            </div>
          </aside>
        </div>
      )}
    </div>
  )
}
