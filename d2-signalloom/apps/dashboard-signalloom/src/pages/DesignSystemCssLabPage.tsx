import { useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import DesignSystemHeadersPage from './DesignSystemHeadersPage'
import DesignSystemPage from './DesignSystemPage'
import { CSS_VAR_NAMES, THEME_LABELS, THEME_NAMES, type CssVarName } from '../styles/themes'
import {
  CSS_LAB_STORAGE_KEY,
  buildBaseThemeCss,
  buildCssExport,
  buildTokenOverrideCss,
  createDefaultDraft,
  parseCssLabDraft,
  resolvedThemeValues,
  validateCustomCss,
  validateTokenValue,
  type CssLabDraft,
} from './design-system/cssLab'
import './DesignSystemCssLabPage.css'

function readDraft(): CssLabDraft {
  try {
    return parseCssLabDraft(window.localStorage.getItem(CSS_LAB_STORAGE_KEY))
  } catch {
    return createDefaultDraft()
  }
}

function cloneApplicationStyles(target: Document): void {
  for (const node of document.querySelectorAll('style, link[rel="stylesheet"]')) {
    if (node instanceof HTMLLinkElement) {
      try {
        if (new URL(node.href, window.location.href).origin !== window.location.origin) continue
      } catch {
        continue
      }
    }
    target.head.append(node.cloneNode(true))
  }
}

function initializePreviewDocument(frame: HTMLIFrameElement): HTMLElement | null {
  const previewDocument = frame.contentDocument
  if (!previewDocument || !previewDocument.head || !previewDocument.body) return null
  previewDocument.head.replaceChildren()
  previewDocument.body.replaceChildren()
  previewDocument.title = 'Signal Loom CSS Lab preview'
  cloneApplicationStyles(previewDocument)

  const baseStyle = previewDocument.createElement('style')
  baseStyle.id = 'css-lab-base-theme'
  previewDocument.head.append(baseStyle)

  const customStyle = previewDocument.createElement('style')
  customStyle.id = 'css-lab-custom'
  previewDocument.head.append(customStyle)

  const tokenStyle = previewDocument.createElement('style')
  tokenStyle.id = 'css-lab-token-overrides'
  previewDocument.head.append(tokenStyle)

  const mount = previewDocument.createElement('div')
  mount.id = 'css-lab-preview-root'
  mount.style.padding = '28px 32px'
  mount.style.minHeight = '100%'
  previewDocument.body.append(mount)
  return mount
}

export default function DesignSystemCssLabPage() {
  const initial = useMemo(readDraft, [])
  const [theme, setTheme] = useState(initial.theme)
  const [preview, setPreview] = useState(initial.preview)
  const [viewport, setViewport] = useState(initial.viewport)
  const [tokenOverrides, setTokenOverrides] = useState(initial.tokenOverrides)
  const [tokenInput, setTokenInput] = useState(initial.tokenOverrides)
  const [cssInput, setCssInput] = useState(initial.customCss)
  const [validCss, setValidCss] = useState(initial.customCss)
  const [cssError, setCssError] = useState('')
  const [tokenError, setTokenError] = useState('')
  const [message, setMessage] = useState('')
  const [portalHost, setPortalHost] = useState<HTMLElement | null>(null)
  const iframeRef = useRef<HTMLIFrameElement>(null)

  useEffect(() => {
    const frame = iframeRef.current
    if (!frame) return
    const initialize = () => setPortalHost(initializePreviewDocument(frame))
    initialize()
    frame.addEventListener('load', initialize)
    return () => {
      frame.removeEventListener('load', initialize)
    }
  }, [])

  useEffect(() => {
    if (!portalHost) return
    const previewDocument = portalHost.ownerDocument
    previewDocument.documentElement.setAttribute('data-theme', theme)
    for (const name of CSS_VAR_NAMES) previewDocument.documentElement.style.removeProperty(name)
    const baseStyle = previewDocument.getElementById('css-lab-base-theme')
    const customStyle = previewDocument.getElementById('css-lab-custom')
    const tokenStyle = previewDocument.getElementById('css-lab-token-overrides')
    if (baseStyle) baseStyle.textContent = buildBaseThemeCss(theme)
    if (customStyle) customStyle.textContent = validCss
    if (tokenStyle) tokenStyle.textContent = buildTokenOverrideCss(tokenOverrides)
  }, [portalHost, theme, tokenOverrides, validCss])

  useEffect(() => {
    if (!portalHost) return
    const previewDocument = portalHost.ownerDocument
    const containNavigation = (event: MouseEvent) => {
      const target = event.target as { closest?: (selector: string) => Element | null } | null
      const anchor = target?.closest?.('a') as HTMLAnchorElement | null
      if (!anchor) return
      const href = anchor.getAttribute('href') ?? ''
      if (href.startsWith('#')) {
        if (!event.defaultPrevented) {
          event.preventDefault()
          previewDocument.getElementById(href.slice(1))?.scrollIntoView?.()
        }
        return
      }
      event.preventDefault()
    }
    const preventRouterNavigation = (event: MouseEvent) => {
      const target = event.target as { closest?: (selector: string) => Element | null } | null
      const anchor = target?.closest?.('a')
      if (anchor && !(anchor.getAttribute('href') ?? '').startsWith('#')) {
        event.preventDefault()
        event.stopPropagation()
      }
    }
    previewDocument.addEventListener('click', preventRouterNavigation, true)
    previewDocument.addEventListener('click', containNavigation)
    return () => {
      previewDocument.removeEventListener('click', preventRouterNavigation, true)
      previewDocument.removeEventListener('click', containNavigation)
    }
  }, [portalHost])

  const updateCss = (value: string) => {
    setCssInput(value)
    const result = validateCustomCss(value)
    if (!result.ok) {
      setCssError(result.error ?? 'Invalid CSS.')
      return
    }
    setCssError('')
    setValidCss(value)
  }

  const updateToken = (name: CssVarName, value: string) => {
    setTokenInput((current) => ({ ...current, [name]: value }))
    const result = validateTokenValue(value)
    if (!result.ok) {
      setTokenError(`${name}: ${result.error ?? 'Invalid token value.'}`)
      return
    }
    setTokenError('')
    setTokenOverrides((current) => {
      const next = { ...current }
      if (value) next[name] = value
      else delete next[name]
      return next
    })
  }

  const currentDraft = (): CssLabDraft => ({
    version: 1,
    theme,
    preview,
    viewport,
    customCss: validCss,
    tokenOverrides,
  })

  const exportedCss = () => buildCssExport(theme, tokenOverrides, validCss)

  const saveDraft = () => {
    try {
      window.localStorage.setItem(CSS_LAB_STORAGE_KEY, JSON.stringify(currentDraft()))
      setMessage('Draft saved in this browser.')
    } catch {
      setMessage('Draft could not be saved because browser storage is unavailable.')
    }
  }

  const resetEdits = () => {
    setTokenOverrides({})
    setTokenInput({})
    setCssInput('')
    setValidCss('')
    setCssError('')
    setTokenError('')
    try {
      window.localStorage.setItem(CSS_LAB_STORAGE_KEY, JSON.stringify({
        version: 1,
        theme,
        preview,
        viewport,
        customCss: '',
        tokenOverrides: {},
      } satisfies CssLabDraft))
    } catch {
      // State still resets when browser storage is unavailable.
    }
    setMessage('Edits reset. The selected base theme is unchanged.')
  }

  const copyCss = async () => {
    if (!navigator.clipboard?.writeText) {
      setMessage('Clipboard unavailable. Use Download CSS instead.')
      return
    }
    try {
      await navigator.clipboard.writeText(exportedCss())
      setMessage('CSS copied to the clipboard.')
    } catch {
      setMessage('Clipboard unavailable. Use Download CSS instead.')
    }
  }

  const downloadCss = () => {
    const url = URL.createObjectURL(new Blob([exportedCss()], { type: 'text/css' }))
    const anchor = document.createElement('a')
    anchor.href = url
    anchor.download = `signalloom-css-lab-${theme}.css`
    anchor.click()
    URL.revokeObjectURL(url)
    setMessage('CSS export downloaded.')
  }

  return (
    <>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>CSS Lab</h1>
      <p style={{ color: 'var(--muted)', fontSize: 13, margin: '0 0 20px', maxWidth: 860, lineHeight: 1.55 }}>
        Experiment against the real component galleries without changing the saved application theme. Everything stays in this browser; nothing is published or sent to an API.
      </p>

      <div className="css-lab-shell">
        <aside className="css-lab-editor" aria-label="CSS Lab editor">
          <section className="css-lab-card">
            <div style={{ display: 'grid', gap: 12 }}>
              <label className="css-lab-field">
                Preview content
                <select value={preview} onChange={(event) => setPreview(event.target.value as CssLabDraft['preview'])}>
                  <option value="gallery">Expanded component gallery</option>
                  <option value="headers">Header gallery</option>
                </select>
              </label>
              <label className="css-lab-field">
                Base theme
                <select value={theme} onChange={(event) => setTheme(event.target.value as CssLabDraft['theme'])}>
                  {THEME_NAMES.map((name) => <option key={name} value={name}>{THEME_LABELS[name]}</option>)}
                </select>
              </label>
              <fieldset style={{ border: 0, display: 'grid', gap: 6 }}>
                <legend style={{ color: 'var(--muted)', fontSize: 12, marginBottom: 6 }}>Preview width</legend>
                <div className="css-lab-segmented">
                  <button className={`btn ${viewport === 'desktop' ? 'btn-primary' : 'btn-secondary'}`} type="button" onClick={() => setViewport('desktop')} aria-pressed={viewport === 'desktop'}>Desktop</button>
                  <button className={`btn ${viewport === 'mobile' ? 'btn-primary' : 'btn-secondary'}`} type="button" onClick={() => setViewport('mobile')} aria-pressed={viewport === 'mobile'}>Mobile</button>
                </div>
              </fieldset>
            </div>
          </section>

          <section className="css-lab-card">
            <h2 style={{ fontSize: 15, marginBottom: 4 }}>Token overrides</h2>
            <p className="css-lab-help" style={{ margin: '0 0 12px' }}>Values accept any local CSS colour or text value. Blank fields inherit the selected base theme.</p>
            <div className="css-lab-token-grid">
              {CSS_VAR_NAMES.map((name) => {
                const baseValue = resolvedThemeValues(theme, {})[name]
                const currentValue = tokenOverrides[name] || baseValue
                return (
                  <div className="css-lab-field" key={name}>
                    <label htmlFor={`css-lab-token-${name}`}>{name} override</label>
                    <div className="css-lab-token-inputs">
                      <input type="color" aria-label={`${name} colour`} value={/^#[0-9a-f]{6}$/i.test(currentValue) ? currentValue : baseValue} onChange={(event) => updateToken(name, event.target.value)} />
                      <input id={`css-lab-token-${name}`} value={tokenInput[name] ?? ''} onChange={(event) => updateToken(name, event.target.value)} placeholder={baseValue} />
                    </div>
                  </div>
                )
              })}
            </div>
            {tokenError && <p className="css-lab-error" role="alert" style={{ margin: '10px 0 0' }}>{tokenError} The preview keeps the last valid token value.</p>}
          </section>

          <section className="css-lab-card">
            <label className="css-lab-field">
              Custom CSS
              <textarea value={cssInput} onChange={(event) => updateCss(event.target.value)} spellCheck={false} placeholder={'.card { border-radius: 0 !important; }'} />
            </label>
            <p className="css-lab-help" style={{ margin: '10px 0 0' }}>
              Token variables work normally. Many component layouts use inline styles, so overriding those properties requires <code>!important</code>. Network-capable CSS is blocked.
            </p>
            {cssError && <p className="css-lab-error" role="alert" style={{ margin: '10px 0 0' }}>{cssError} The preview keeps the last valid CSS.</p>}
          </section>

          <section className="css-lab-card">
            <div className="css-lab-actions">
              <button className="btn btn-primary" type="button" onClick={saveDraft}>Save draft</button>
              <button className="btn btn-secondary" type="button" onClick={resetEdits}>Reset edits</button>
              <button className="btn btn-secondary" type="button" onClick={() => void copyCss()}>Copy CSS</button>
              <button className="btn btn-secondary" type="button" onClick={downloadCss}>Download CSS</button>
            </div>
            <p role="status" aria-live="polite" className="css-lab-help" style={{ minHeight: 19, margin: '10px 0 0' }}>{message}</p>
          </section>
        </aside>

        <section className="css-lab-preview-panel" aria-label="CSS Lab preview">
          <div className="css-lab-preview-scroll">
            <iframe
              ref={iframeRef}
              className="css-lab-preview"
              data-viewport={viewport}
              title="CSS Lab component preview"
              sandbox="allow-same-origin"
              srcDoc="<!doctype html><html><head></head><body></body></html>"
            />
          </div>
        </section>
      </div>

      {portalHost && createPortal(preview === 'gallery' ? <DesignSystemPage /> : <DesignSystemHeadersPage />, portalHost)}
    </>
  )
}
