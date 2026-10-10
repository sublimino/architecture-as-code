export type FleetRole = "admin" | "compliance" | "team-lead"

export interface RoleViewSelectorProps {
  activeRole: FleetRole
  onRoleChange: (role: FleetRole) => void
  disabled?: boolean
  testId?: string
}

export interface RoleViewOption {
  role: FleetRole
  label: string
}

export const ROLE_VIEW_OPTIONS: RoleViewOption[] = [
  { role: "admin", label: "Platform Admin" },
  { role: "compliance", label: "Compliance Officer" },
  { role: "team-lead", label: "Payments Team Lead" },
]

export default function RoleViewSelector({
  activeRole,
  onRoleChange,
  disabled = false,
  testId = "role-view-selector",
}: RoleViewSelectorProps) {
  return (
    <div
      role="group"
      aria-label="Fleet role view"
      data-testid={testId}
      className="inline-flex items-center gap-1 p-0.5 rounded-lg border border-slate-800 bg-slate-900/90 text-xs font-medium"
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 4,
        padding: "3px 4px",
        borderRadius: 6,
        background: "var(--surface2)",
        border: "1px solid var(--border)",
      }}
    >
      {ROLE_VIEW_OPTIONS.map((opt) => {
        const isActive = opt.role === activeRole
        return (
          <button
            key={opt.role}
            type="button"
            data-testid={"role-btn-" + opt.role}
            data-active={isActive ? "true" : "false"}
            data-static="true"
            aria-pressed={isActive}
            disabled={disabled}
            onClick={() => onRoleChange(opt.role)}
            className={
              isActive
                ? "px-3 py-1.5 rounded-md text-xs font-semibold transition-colors duration-150 bg-cyan-500/20 text-cyan-400 border border-cyan-500/40 shadow-sm"
                : "px-3 py-1.5 rounded-md text-xs font-medium transition-colors duration-150 text-slate-400 hover:text-slate-200 hover:bg-slate-800/60 border border-transparent"
            }
            style={{
              padding: "4px 10px",
              fontSize: 12,
              fontWeight: isActive ? 600 : 500,
              borderRadius: 4,
              cursor: disabled ? "not-allowed" : "pointer",
              color: isActive ? "var(--cyan)" : "var(--muted)",
              background: isActive
                ? "color-mix(in srgb, var(--cyan) 14%, var(--surface))"
                : "transparent",
              border: isActive
                ? "1px solid color-mix(in srgb, var(--cyan) 45%, transparent)"
                : "1px solid transparent",
              transition: "all 0.15s ease",
            }}
          >
            {opt.label}
          </button>
        )
      })}
    </div>
  )
}
