import type { WizardStep } from '../../hooks/useOnboardingWizard'

// Custom inline icons (not real logos — see ProviderLogo.tsx for the
// per-provider brand marks). Pure SVG, no external assets, themes correctly
// via currentColor/CSS vars in both light and dark mode.

function IconWrap({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        width: 44, height: 44, borderRadius: 12,
        background: 'linear-gradient(135deg, rgba(6,182,212,0.16), rgba(139,92,246,0.16))',
        border: '1px solid rgba(6,182,212,0.25)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: 'var(--cyan)', flexShrink: 0,
      }}
    >
      {children}
    </div>
  )
}

function Svg({ children }: { children: React.ReactNode }) {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      {children}
    </svg>
  )
}

const ICONS: Record<WizardStep['kind'], React.ReactNode> = {
  welcome: (
    <Svg>
      <path d="M12 2l2.6 6.2L21 11l-6.4 2.8L12 20l-2.6-6.2L3 11l6.4-2.8L12 2z" />
    </Svg>
  ),
  'select-providers': (
    <Svg>
      <path d="M9 3v4M15 3v4M4 8h16M6 8v11a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V8" />
      <path d="M9 13l2 2 4-4" />
    </Svg>
  ),
  configure: (
    <Svg>
      <circle cx="8" cy="12" r="3" />
      <path d="M11 12h9m-4 0v3m4-3v-3" />
    </Svg>
  ),
  preferences: (
    <Svg>
      <path d="M4 6h9M17 6h3M4 12h3M11 12h9M4 18h13M21 18h-1" />
      <circle cx="15" cy="6" r="2" />
      <circle cx="7" cy="12" r="2" />
      <circle cx="17" cy="18" r="2" />
    </Svg>
  ),
  'api-key': (
    <Svg>
      <path d="M8 9l-5 5 5 5M16 9l5 5-5 5M14 4l-4 16" />
    </Svg>
  ),
  summary: (
    <Svg>
      <circle cx="12" cy="12" r="9" />
      <path d="M8 12.5l2.5 2.5L16 9.5" />
    </Svg>
  ),
}

export default function StepIcon({ kind }: { kind: WizardStep['kind'] }) {
  return <IconWrap>{ICONS[kind]}</IconWrap>
}
