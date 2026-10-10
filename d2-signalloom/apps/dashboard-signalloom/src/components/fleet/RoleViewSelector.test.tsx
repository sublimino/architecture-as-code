import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import RoleViewSelector from "./RoleViewSelector"

describe("RoleViewSelector", () => {
  it("renders all three role option buttons with correct labels", () => {
    const onRoleChange = vi.fn()
    render(<RoleViewSelector activeRole="admin" onRoleChange={onRoleChange} />)

    expect(screen.getByTestId("role-view-selector")).toBeInTheDocument()
    expect(screen.getByTestId("role-btn-admin")).toHaveTextContent("Platform Admin")
    expect(screen.getByTestId("role-btn-compliance")).toHaveTextContent("Compliance Officer")
    expect(screen.getByTestId("role-btn-team-lead")).toHaveTextContent("Payments Team Lead")
  })

  it("marks and styles the active role button appropriately", () => {
    const onRoleChange = vi.fn()
    const { rerender } = render(
      <RoleViewSelector activeRole="admin" onRoleChange={onRoleChange} />
    )

    const adminBtn = screen.getByTestId("role-btn-admin")
    const complianceBtn = screen.getByTestId("role-btn-compliance")
    const teamLeadBtn = screen.getByTestId("role-btn-team-lead")

    expect(adminBtn).toHaveAttribute("aria-pressed", "true")
    expect(adminBtn).toHaveAttribute("data-active", "true")
    expect(complianceBtn).toHaveAttribute("aria-pressed", "false")
    expect(complianceBtn).toHaveAttribute("data-active", "false")
    expect(teamLeadBtn).toHaveAttribute("aria-pressed", "false")
    expect(teamLeadBtn).toHaveAttribute("data-active", "false")

    // Switch to compliance
    rerender(<RoleViewSelector activeRole="compliance" onRoleChange={onRoleChange} />)
    expect(adminBtn).toHaveAttribute("aria-pressed", "false")
    expect(complianceBtn).toHaveAttribute("aria-pressed", "true")
    expect(teamLeadBtn).toHaveAttribute("aria-pressed", "false")

    // Switch to team-lead
    rerender(<RoleViewSelector activeRole="team-lead" onRoleChange={onRoleChange} />)
    expect(adminBtn).toHaveAttribute("aria-pressed", "false")
    expect(complianceBtn).toHaveAttribute("aria-pressed", "false")
    expect(teamLeadBtn).toHaveAttribute("aria-pressed", "true")
  })

  it("invokes onRoleChange callback when a role button is clicked", async () => {
    const user = userEvent.setup()
    const onRoleChange = vi.fn()
    render(<RoleViewSelector activeRole="admin" onRoleChange={onRoleChange} />)

    await user.click(screen.getByTestId("role-btn-compliance"))
    expect(onRoleChange).toHaveBeenCalledTimes(1)
    expect(onRoleChange).toHaveBeenCalledWith("compliance")

    await user.click(screen.getByTestId("role-btn-team-lead"))
    expect(onRoleChange).toHaveBeenCalledTimes(2)
    expect(onRoleChange).toHaveBeenCalledWith("team-lead")

    await user.click(screen.getByTestId("role-btn-admin"))
    expect(onRoleChange).toHaveBeenCalledTimes(3)
    expect(onRoleChange).toHaveBeenCalledWith("admin")
  })

  it("disables all buttons when disabled prop is true", async () => {
    const user = userEvent.setup()
    const onRoleChange = vi.fn()
    render(<RoleViewSelector activeRole="admin" onRoleChange={onRoleChange} disabled />)

    const adminBtn = screen.getByTestId("role-btn-admin")
    const complianceBtn = screen.getByTestId("role-btn-compliance")
    const teamLeadBtn = screen.getByTestId("role-btn-team-lead")

    expect(adminBtn).toBeDisabled()
    expect(complianceBtn).toBeDisabled()
    expect(teamLeadBtn).toBeDisabled()

    await user.click(complianceBtn)
    expect(onRoleChange).not.toHaveBeenCalled()
  })

  it("contains zero em-dashes across rendered content and labels", () => {
    const onRoleChange = vi.fn()
    const { container } = render(
      <RoleViewSelector activeRole="admin" onRoleChange={onRoleChange} />
    )
    expect(container.textContent).not.toMatch(/\u2014|\u2013/)
  })
})
