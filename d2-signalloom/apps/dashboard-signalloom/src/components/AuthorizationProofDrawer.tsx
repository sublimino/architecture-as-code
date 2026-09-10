// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React, { useEffect, useState, memo } from "react"
import { WhoAuthorizedPanel } from "./WhoAuthorizedPanel"
import type { AuthorizationChain } from "../api/weaveApi"

export interface AuthorizationProofDrawerProps {
  isOpen: boolean
  onClose: () => void
  actionId?: string
  chain?: AuthorizationChain | null
  actorId?: string
  onSelectActor?: (actorId: string) => void
  availableActors?: { id: string; name?: string }[]
  evidenceRef?: string
  rekorUrl?: string
}

export const AuthorizationProofDrawer: React.FC<AuthorizationProofDrawerProps> = memo(({
  isOpen,
  onClose,
  actionId,
  chain,
  actorId,
  onSelectActor,
  availableActors = [],
  evidenceRef = "sha256:8f43b12390abcf",
  rekorUrl = "https://rekor.sigstore.dev",
}) => {
  const [copiedKey, setCopiedKey] = useState<string | null>(null)

  useEffect(() => {
    if (!isOpen) return
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        onClose()
      }
    }
    window.addEventListener("keydown", handleKeyDown)
    return () => window.removeEventListener("keydown", handleKeyDown)
  }, [isOpen, onClose])

  if (!isOpen) return null

  const copyToClipboard = async (text: string, key: string) => {
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(text)
        setCopiedKey(key)
        setTimeout(() => setCopiedKey(null), 2000)
      }
    } catch {
      // ignore
    }
  }

  const frostDbDigest = `frostdb:segment:sha256:${(evidenceRef || 'seg-001').replace('sha256:', '')}`
  const webhookRecord = `audit-webhook:rec:${actionId || 'ev-001'}`

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="proof-drawer-title"
      style={{
        position: "fixed",
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        zIndex: 9999,
        display: "flex",
        justifyContent: "flex-end",
      }}
    >
      {/* Backdrop */}
      <div
        data-testid="proof-drawer-backdrop"
        onClick={onClose}
        style={{
          position: "absolute",
          top: 0,
          left: 0,
          right: 0,
          bottom: 0,
          background: "rgba(0, 0, 0, 0.5)",
          backdropFilter: "blur(2px)",
        }}
      />

      {/* Drawer */}
      <div
        data-testid="authorization-proof-drawer"
        style={{
          position: "relative",
          width: 680,
          maxWidth: "94vw",
          height: "100%",
          background: "var(--surface1, #121824)",
          borderLeft: "1px solid var(--border)",
          boxShadow: "-8px 0 24px rgba(0, 0, 0, 0.4)",
          display: "flex",
          flexDirection: "column",
          overflowY: "auto",
          transition: "transform 90ms ease-in-out",
        }}
      >
        {/* Header */}
        <div
          style={{
            padding: "16px 20px",
            borderBottom: "1px solid var(--border)",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            background: "var(--surface2)",
            position: "sticky",
            top: 0,
            zIndex: 10,
          }}
        >
          <div>
            <h2
              id="proof-drawer-title"
              style={{ margin: 0, fontSize: 16, fontWeight: 700, color: "var(--text)" }}
            >
              Cryptographic Authorization Proof
            </h2>
            {actionId && (
              <span
                data-testid="proof-drawer-action-id"
                style={{
                  fontSize: 11,
                  fontFamily: "monospace",
                  color: "var(--cyan)",
                  display: "inline-block",
                  marginTop: 4,
                }}
              >
                Action: {actionId}
              </span>
            )}
          </div>
          <button
            type="button"
            data-testid="close-proof-drawer"
            aria-label="Close"
            onClick={onClose}
            style={{
              background: "none",
              border: "none",
              fontSize: 20,
              cursor: "pointer",
              color: "var(--text-muted)",
              padding: "4px 8px",
              borderRadius: 4,
            }}
          >
            ✕
          </button>
        </div>

        {/* Content */}
        <div style={{ padding: 20, display: "flex", flexDirection: "column", gap: 16 }}>
          {/* Quick Copy & Reference Actions */}
          <div
            style={{
              display: "flex",
              flexDirection: "column",
              gap: 8,
              padding: "12px 14px",
              borderRadius: 6,
              background: "var(--surface2)",
              border: "1px solid var(--border)",
              fontSize: 12,
            }}
          >
            <div style={{ fontWeight: 600, color: "var(--text-muted)", marginBottom: 2 }}>
              Evidence & Verification References
            </div>

            {/* FrostDB Segment Digest */}
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8 }}>
              <span style={{ color: "var(--text-muted)", fontSize: 11 }}>FrostDB Digest:</span>
              <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                <code style={{ fontSize: 11, color: "var(--text)" }}>{frostDbDigest}</code>
                <button
                  type="button"
                  data-testid="proof-drawer-copy-frostdb"
                  onClick={() => copyToClipboard(frostDbDigest, 'frostdb')}
                  style={{
                    background: "none",
                    border: "1px solid var(--border)",
                    borderRadius: 3,
                    padding: "2px 8px",
                    fontSize: 11,
                    color: "var(--cyan)",
                    cursor: "pointer",
                  }}
                >
                  {copiedKey === 'frostdb' ? "Copied!" : "Copy"}
                </button>
              </div>
            </div>

            {/* Webhook Audit Record */}
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8 }}>
              <span style={{ color: "var(--text-muted)", fontSize: 11 }}>Audit Webhook:</span>
              <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                <code style={{ fontSize: 11, color: "var(--text)" }}>{webhookRecord}</code>
                <button
                  type="button"
                  data-testid="proof-drawer-copy-webhook"
                  onClick={() => copyToClipboard(webhookRecord, 'webhook')}
                  style={{
                    background: "none",
                    border: "1px solid var(--border)",
                    borderRadius: 3,
                    padding: "2px 8px",
                    fontSize: 11,
                    color: "var(--cyan)",
                    cursor: "pointer",
                  }}
                >
                  {copiedKey === 'webhook' ? "Copied!" : "Copy"}
                </button>
              </div>
            </div>

            {/* Evidence Ref */}
            {evidenceRef && (
              <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8 }}>
                <span style={{ color: "var(--text-muted)", fontSize: 11 }}>Evidence Ref:</span>
                <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                  <code style={{ fontSize: 11, color: "var(--cyan)" }}>{evidenceRef}</code>
                  <button
                    type="button"
                    data-testid="proof-drawer-copy-evidence"
                    onClick={() => copyToClipboard(evidenceRef, 'evidence')}
                    style={{
                      background: "none",
                      border: "1px solid var(--border)",
                      borderRadius: 3,
                      padding: "2px 8px",
                      fontSize: 11,
                      color: "var(--cyan)",
                      cursor: "pointer",
                    }}
                  >
                    {copiedKey === 'evidence' ? "Copied!" : "Copy"}
                  </button>
                </div>
              </div>
            )}

            {/* Rekor Transparency Explorer Link */}
            {rekorUrl && (
              <div style={{ marginTop: 4 }}>
                <a
                  data-testid="proof-drawer-rekor-link"
                  href={rekorUrl}
                  target="_blank"
                  rel="noreferrer noopener"
                  style={{ color: "var(--cyan)", textDecoration: "none", fontSize: 11 }}
                >
                  Inspect Rekor Attestation Log ↗
                </a>
              </div>
            )}
          </div>

          {/* Embedded WhoAuthorizedPanel */}
          <div data-testid="who-authorized-panel">
            <WhoAuthorizedPanel
              chain={chain}
              actorId={actorId}
              onSelectActor={onSelectActor}
              availableActors={availableActors}
              compact={false}
              hideHeaderControls={false}
            />
          </div>
        </div>
      </div>
    </div>
  )
})

export default AuthorizationProofDrawer
