import FleetDemoPage from "./FleetDemoPage"

/**
 * Audience presentation view for fleet demonstrations.
 *
 * Mounts the fleet topology and risk metrics full-screen on the presentation route
 * (/demos/fleet/audience), hiding instructor controls, roster tables, and destructive
 * action buttons so the audience sees only live telemetry and topology graphs.
 */
export default function FleetAudiencePage() {
  return (
    <div data-testid="fleet-audience-page" style={{ width: "100%", height: "100%" }}>
      <FleetDemoPage audience />
    </div>
  )
}
