// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React, { memo } from "react"

export interface DelegationEventFilterProps {
  selectedType: string
  onSelectType: (type: string) => void
  availableTypes: string[]
  minHops: number
  onMinHopsChange: (hops: number) => void
  onReset?: () => void
  filteredCount?: number
  totalCount?: number
}

export const DelegationEventFilter: React.FC<DelegationEventFilterProps> = memo(({
  selectedType,
  onSelectType,
  availableTypes,
  minHops,
  onMinHopsChange,
  onReset,
  filteredCount,
  totalCount,
}) => {
  return (
    <div
      data-testid="delegation-event-filter"
      style={{
        display: "flex",
        alignItems: "center",
        gap: 12,
        flexWrap: "wrap",
        padding: "10px 14px",
        borderRadius: 6,
        background: "var(--surface2)",
        border: "1px solid var(--border)",
        marginBottom: 16,
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
        <label
          htmlFor="delegation-type-select"
          style={{ fontSize: 12, fontWeight: 600, color: "var(--muted)" }}
        >
          Event Type:
        </label>
        <select
          id="delegation-type-select"
          data-testid="delegation-type-filter"
          value={selectedType}
          onChange={(e) => onSelectType(e.target.value)}
          style={{
            padding: "4px 8px",
            fontSize: 12,
            borderRadius: 4,
            border: "1px solid var(--border)",
            background: "var(--surface)",
            color: "var(--text)",
          }}
        >
          <option value="all">All Event Types</option>
          {availableTypes.map((t) => (
            <option key={t} value={t}>
              {t}
            </option>
          ))}
        </select>
      </div>

      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
        <label
          htmlFor="delegation-min-hops-input"
          style={{ fontSize: 12, fontWeight: 600, color: "var(--muted)" }}
        >
          Min Hops:
        </label>
        <input
          id="delegation-min-hops-input"
          data-testid="delegation-min-hops-filter"
          type="number"
          min={0}
          max={10}
          value={minHops}
          onChange={(e) => onMinHopsChange(Math.max(0, parseInt(e.target.value || "0", 10)))}
          style={{
            width: 60,
            padding: "4px 8px",
            fontSize: 12,
            borderRadius: 4,
            border: "1px solid var(--border)",
            background: "var(--surface)",
            color: "var(--text)",
          }}
        />
      </div>

      {onReset && (
        <button
          type="button"
          data-testid="delegation-filter-reset"
          onClick={onReset}
          style={{
            padding: "4px 10px",
            fontSize: 12,
            borderRadius: 4,
            border: "1px solid var(--border)",
            background: "var(--surface)",
            color: "var(--muted)",
            cursor: "pointer",
          }}
        >
          Reset Filters
        </button>
      )}

      {typeof filteredCount === "number" && typeof totalCount === "number" && (
        <span
          data-testid="delegation-filter-count"
          style={{
            fontSize: 11,
            color: "var(--muted)",
            marginLeft: "auto",
          }}
        >
          Showing {filteredCount} of {totalCount} events
        </span>
      )}
    </div>
  )
})

export default DelegationEventFilter
