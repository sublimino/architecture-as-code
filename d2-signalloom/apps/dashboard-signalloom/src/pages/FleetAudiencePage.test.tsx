import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { act, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import FleetAudiencePage from "./FleetAudiencePage"
import type { FleetTopology } from "../api/fleetApi"
import { routeLoadingLabel } from "../App"

// Mocks

const getAccessTokenSilently = vi.fn().mockResolvedValue("test-token")

vi.mock("../auth/oidc", () => ({
  useAuth0: () => ({
    getAccessTokenSilently,
    user: { email: "audience-viewer@signalloom.local", preferred_username: "audience-viewer" },
  }),
}))

const mockSuperadmin = { value: false }

vi.mock("../App", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../App")>()
  return {
    ...actual,
    useAppContext: () => ({
      superadmin: mockSuperadmin.value,
      setSuperadmin: vi.fn(),
      failingControls: 0,
      setFailingControls: vi.fn(),
      helpOpen: false,
      setHelpOpen: vi.fn(),
    }),
  }
})

const mockFetchFleetTopology = vi.fn()
const mockDeployFleet = vi.fn()
const mockScanFleet = vi.fn()
const mockStunFleetAgent = vi.fn()
const mockRecoverFleet = vi.fn()
const mockResetFleet = vi.fn()

vi.mock("../api/fleetApi", () => ({
  fetchFleetTopology: (...args: unknown[]) => mockFetchFleetTopology(...args),
  deployFleet: (...args: unknown[]) => mockDeployFleet(...args),
  scanFleet: (...args: unknown[]) => mockScanFleet(...args),
  stunFleetAgent: (...args: unknown[]) => mockStunFleetAgent(...args),
  recoverFleet: (...args: unknown[]) => mockRecoverFleet(...args),
  resetFleet: (...args: unknown[]) => mockResetFleet(...args),
}))

// Fixtures

const TOPOLOGY: FleetTopology = {
  agents: [
    { id: "agent-cardvault", name: "Card Vault", type: "data-vault", team: "data", trustProfile: "high", state: "active" },
    { id: "agent-pipeline", name: "Data Pipeline", type: "data-pipeline", team: "data", trustProfile: "medium", state: "active" },
    { id: "agent-llm", name: "LLM Inference", type: "llm-inference", team: "ai", trustProfile: "medium", state: "active" },
    { id: "agent-gateway", name: "API Gateway", type: "api-gateway", team: "platform", trustProfile: "low", state: "active" },
    { id: "agent-monitor", name: "Monitor", type: "observability", team: "sre", trustProfile: "high", state: "active" },
  ],
  edges: [
    { from: "agent-cardvault", to: "agent-pipeline" },
    { from: "agent-pipeline", to: "agent-llm" },
    { from: "agent-llm", to: "agent-gateway" },
    { from: "agent-gateway", to: "agent-monitor" },
  ],
  aggregateRisk: { ale: 847000, var95: 1200000, trend: "up", previousAle: 650000 },
  cascadeHistory: [],
}

function renderAudiencePage() {
  return render(
    <MemoryRouter initialEntries={["/demos/fleet/audience"]}>
      <FleetAudiencePage />
    </MemoryRouter>
  )
}

describe("FleetAudiencePage", () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    vi.clearAllMocks()
    mockSuperadmin.value = false
    mockFetchFleetTopology.mockResolvedValue(TOPOLOGY)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("renders full-screen topology and risk metrics cleanly", async () => {
    renderAudiencePage()

    await waitFor(() => {
      expect(screen.getByTestId("fleet-topology")).toBeInTheDocument()
      expect(screen.getByTestId("fleet-risk-gauge")).toBeInTheDocument()
    })

    // Assert key agent nodes are in the topology
    expect(screen.getByTestId("fleet-node-agent-cardvault")).toBeInTheDocument()
    expect(screen.getByTestId("fleet-node-agent-pipeline")).toBeInTheDocument()
    expect(screen.getByTestId("fleet-node-agent-llm")).toBeInTheDocument()

    // Assert aggregate risk metrics are visible
    expect(screen.getByTestId("fleet-risk-ale")).toBeInTheDocument()
    expect(screen.getByText("5 agents deployed")).toBeInTheDocument()
  })

  it("hides instructor controls and roster completely from the audience presentation view", async () => {
    renderAudiencePage()

    await waitFor(() => {
      expect(screen.getByTestId("fleet-topology")).toBeInTheDocument()
    })

    // No mutation action buttons
    expect(screen.queryByRole("button", { name: /Deploy Fleet/i })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Scan Fleet/i })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Stun/i })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Recover/i })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Reset/i })).not.toBeInTheDocument()

    // No roster table or filter inputs
    expect(screen.queryByTestId("fleet-roster-search")).not.toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: /Fleet roster/i })).not.toBeInTheDocument()
  })

  it("displays error state cleanly when topology fetch fails on mount", async () => {
    mockFetchFleetTopology.mockRejectedValue(
      new Error("Fleet Manager did not respond: upstream unavailable")
    )
    renderAudiencePage()

    await waitFor(() => {
      expect(screen.getByTestId("fleet-audience-unreachable")).toBeInTheDocument()
    })

    expect(screen.getByText("Failed to load")).toBeInTheDocument()
    expect(screen.queryByTestId("fleet-topology")).not.toBeInTheDocument()
    expect(screen.queryByTestId("fleet-risk-gauge")).not.toBeInTheDocument()
  })

  it("keeps the audience diagram displayed when the fleet is empty", async () => {
    mockFetchFleetTopology.mockResolvedValue({
      ...TOPOLOGY,
      agents: [],
      edges: [],
    })
    renderAudiencePage()

    await waitFor(() => {
      expect(screen.getByTestId("fleet-topology")).toBeInTheDocument()
    })

    expect(screen.getByTestId("fleet-risk-gauge")).toBeInTheDocument()
    expect(screen.queryByTestId("fleet-audience-unreachable")).not.toBeInTheDocument()
    expect(screen.getByText("0 agents deployed")).toBeInTheDocument()
  })

  it("maintains presentation view when a subsequent background poll fails", async () => {
    mockFetchFleetTopology.mockResolvedValueOnce(TOPOLOGY)
    mockFetchFleetTopology.mockRejectedValue(new Error("Transient 503 Service Unavailable"))

    renderAudiencePage()

    await waitFor(() => {
      expect(screen.getByTestId("fleet-topology")).toBeInTheDocument()
    })

    // Advance past the 5-second polling interval
    await act(async () => {
      await vi.advanceTimersByTimeAsync(5500)
    })

    // The topology and risk gauge must remain visible
    expect(screen.getByTestId("fleet-topology")).toBeInTheDocument()
    expect(screen.getByTestId("fleet-risk-gauge")).toBeInTheDocument()
    expect(screen.queryByTestId("fleet-audience-unreachable")).not.toBeInTheDocument()
  })

  it("labels the audience route correctly in App suspense loading labels", () => {
    expect(routeLoadingLabel("/demos/fleet/audience")).toBe("Loading Fleet Demo Audience")
    expect(routeLoadingLabel("/fleet/audience")).toBe("Loading Fleet Demo Audience")
  })

  it("contains no em-dashes anywhere in rendered output", async () => {
    const { container } = renderAudiencePage()

    await waitFor(() => {
      expect(screen.getByTestId("fleet-topology")).toBeInTheDocument()
    })

    const text = container.textContent || ""
    expect(text).not.toContain("\u2014")
    expect(text).not.toContain("\u2013")
  })
})
