import entraLogo from '../../assets/logos/entra.png'
import oktaLogo from '../../assets/logos/okta.png'
import googleWorkspaceLogo from '../../assets/logos/google-workspace.svg'
import awsLogo from '../../assets/logos/aws.png'
import gcpLogo from '../../assets/logos/gcp.png'
import openaiLogo from '../../assets/logos/openai.png'

// All marks below are Wendy-supplied official brand assets, except Google
// Workspace which remains the Simple Icons "G" mark (CC0/permissive) since
// no replacement was supplied for it.
const LOGOS: Record<string, string> = {
  ad_entra: entraLogo,
  okta: oktaLogo,
  google_workspace: googleWorkspaceLogo,
  aws_iam: awsLogo,
  gcp_iam: gcpLogo,
  openai: openaiLogo,
}

interface Props {
  providerId: string
  displayName: string
  size?: number
}

export default function ProviderLogo({ providerId, displayName, size = 40 }: Props) {
  const src = LOGOS[providerId]

  // Fallback for any provider without a mapped brand mark yet (e.g. a newly
  // added connector like OpenAI) — a neutral initial-letter avatar so the
  // grid/list still looks intentional instead of leaving a blank gap where
  // a logo would go. Swap in a real mark by adding it to LOGOS above; no
  // other change needed.
  if (!src) {
    return (
      <div
        style={{
          width: size, height: size, borderRadius: size / 4,
          background: 'var(--surface2)', border: '1px solid var(--border)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          flexShrink: 0, fontSize: size * 0.4, fontWeight: 700, color: 'var(--muted)',
        }}
      >
        {displayName.charAt(0).toUpperCase()}
      </div>
    )
  }

  return (
    <div
      style={{
        width: size, height: size, borderRadius: size / 4,
        // Always a white chip, not var(--surface2) — the supplied brand
        // marks (Entra, AWS) are opaque PNGs with a white background baked
        // in; rendering them on the app's dark surface color would show a
        // visible white box in dark mode. A fixed white background keeps
        // every logo's real colors correct regardless of theme.
        background: '#fff', border: '1px solid var(--border)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        flexShrink: 0, padding: size * 0.14, overflow: 'hidden',
      }}
    >
      <img src={src} alt={`${displayName} logo`} style={{ width: '100%', height: '100%', objectFit: 'contain' }} />
    </div>
  )
}
