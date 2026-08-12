import { usePreferences } from '../state/preferences'
import { Card, PageHeader, Provenance, SectionHeader } from '../components/ui'

export default function SettingsPage() {
  const { theme, setTheme, superadmin, setSuperadmin } = usePreferences()
  return <>
    <PageHeader eyebrow="Account" title="Workspace settings" description="Adjust this static design demonstration without a backend or Kubernetes cluster." actions={<Provenance>Local presentation preferences</Provenance>} />
    <div className="settings-grid">
      <Card><SectionHeader title="Appearance" description="Preferences persist locally in this browser." /><fieldset><legend>Theme</legend><label className="radio-card"><input type="radio" checked={theme === 'dark'} onChange={() => setTheme('dark')} /><span><strong>Dark</strong><small>Deep midnight surfaces with semantic neon.</small></span></label><label className="radio-card"><input type="radio" checked={theme === 'light'} onChange={() => setTheme('light')} /><span><strong>Light</strong><small>Quiet paper surfaces with higher-contrast accents.</small></span></label></fieldset></Card>
      <Card><SectionHeader title="Demo visibility" description="This changes navigation visibility, never authorization." /><label className="settings-toggle"><span><strong>Superadmin tools</strong><small>Show trust fabric and permission-analysis destinations.</small></span><input type="checkbox" checked={superadmin} onChange={(event) => setSuperadmin(event.target.checked)} /></label></Card>
    </div>
  </>
}
