import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { CSS_LAB_STORAGE_KEY, buildCssExport } from './design-system/cssLab'
import DesignSystemCssLabPage from './DesignSystemCssLabPage'
import { installMemoryStorage } from '../test-utils/memoryStorage'

vi.mock('./DesignSystemPage', () => ({ default: () => <div data-testid="real-gallery"><a href="/agents">Agents</a><a href="#target-section" onClick={(event) => { event.currentTarget.dataset.handled = 'true' }}>Jump</a><div id="target-section">Target</div></div> }))
vi.mock('./DesignSystemHeadersPage', () => ({ default: () => <div data-testid="real-headers">Header gallery</div> }))

describe('DesignSystemCssLabPage', () => {
  beforeEach(() => {
    installMemoryStorage()
    vi.restoreAllMocks()
  })

  it('keeps the editor outside a scriptless same-origin preview iframe', async () => {
    render(<DesignSystemCssLabPage />)
    const frame = screen.getByTitle('CSS Lab component preview') as HTMLIFrameElement
    expect(frame).toHaveAttribute('sandbox', 'allow-same-origin')
    expect(screen.getByLabelText('Custom CSS')).toBeInTheDocument()
    await waitFor(() => expect(within(frame.contentDocument!.body).getByTestId('real-gallery')).toBeInTheDocument())
  })

  it('switches between the real gallery page selections', async () => {
    render(<DesignSystemCssLabPage />)
    const frame = screen.getByTitle('CSS Lab component preview') as HTMLIFrameElement
    fireEvent.change(screen.getByLabelText('Preview content'), { target: { value: 'headers' } })
    await waitFor(() => expect(within(frame.contentDocument!.body).getByTestId('real-headers')).toBeInTheDocument())
  })

  it('shows blocked CSS errors while retaining the last valid CSS', async () => {
    render(<DesignSystemCssLabPage />)
    const editor = screen.getByLabelText('Custom CSS')
    fireEvent.change(editor, { target: { value: '.card { color: hotpink; }' } })
    fireEvent.change(editor, { target: { value: '.card { background: url(/leak); }' } })
    expect(screen.getByRole('alert')).toHaveTextContent(/network-capable css/i)

    const frame = screen.getByTitle('CSS Lab component preview') as HTMLIFrameElement
    await waitFor(() => expect(frame.contentDocument!.getElementById('css-lab-custom')?.textContent).toBe('.card { color: hotpink; }'))
  })

  it('matches exported cascade order and contains preview navigation after fragment handlers', async () => {
    render(<DesignSystemCssLabPage />)
    const frame = screen.getByTitle('CSS Lab component preview') as HTMLIFrameElement
    const previewBody = within(frame.contentDocument!.body)
    await waitFor(() => expect(previewBody.getByTestId('real-gallery')).toBeInTheDocument())

    fireEvent.change(screen.getByLabelText('Base theme'), { target: { value: 'light' } })
    fireEvent.change(screen.getByLabelText('Custom CSS'), { target: { value: ':root { --text: hotpink; --bg: papayawhip; }' } })
    fireEvent.change(screen.getByLabelText('--text override'), { target: { value: 'rebeccapurple' } })
    const previewDocument = frame.contentDocument!
    await waitFor(() => {
      const computed = frame.contentWindow!.getComputedStyle(previewDocument.documentElement)
      expect(computed.getPropertyValue('--text').trim()).toBe('rebeccapurple')
      expect(computed.getPropertyValue('--bg').trim()).toBe('papayawhip')
    })
    expect(previewDocument.documentElement.getAttribute('style')).toBeNull()
    expect(Array.from(previewDocument.head.querySelectorAll('style')).slice(-3).map((node) => node.id)).toEqual([
      'css-lab-base-theme',
      'css-lab-custom',
      'css-lab-token-overrides',
    ])

    expect(fireEvent.click(previewBody.getByRole('link', { name: 'Agents' }))).toBe(false)
    const fragment = previewBody.getByRole('link', { name: 'Jump' })
    expect(fireEvent.click(fragment)).toBe(false)
    expect(fragment).toHaveAttribute('data-handled', 'true')
  })

  it('restores a saved draft after remount and persists a reset draft', async () => {
    const first = render(<DesignSystemCssLabPage />)
    const frame = screen.getByTitle('CSS Lab component preview') as HTMLIFrameElement
    await waitFor(() => expect(within(frame.contentDocument!.body).getByTestId('real-gallery')).toBeInTheDocument())
    fireEvent.change(screen.getByLabelText('Base theme'), { target: { value: 'andy' } })
    fireEvent.change(screen.getByLabelText('Custom CSS'), { target: { value: '.card { opacity: .8; }' } })
    fireEvent.change(screen.getByLabelText('--text override'), { target: { value: 'gold' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
    expect(JSON.parse(localStorage.getItem(CSS_LAB_STORAGE_KEY)!)).toMatchObject({ theme: 'andy' })

    first.unmount()
    const second = render(<DesignSystemCssLabPage />)
    expect(screen.getByLabelText('Base theme')).toHaveValue('andy')
    expect(screen.getByLabelText('Custom CSS')).toHaveValue('.card { opacity: .8; }')
    expect(screen.getByLabelText('--text override')).toHaveValue('gold')
    fireEvent.click(screen.getByRole('button', { name: 'Reset edits' }))
    expect(screen.getByLabelText('Base theme')).toHaveValue('andy')
    expect(screen.getByLabelText('Custom CSS')).toHaveValue('')
    expect(screen.getByLabelText('--text override')).toHaveValue('')
    second.unmount()

    render(<DesignSystemCssLabPage />)
    expect(screen.getByLabelText('Base theme')).toHaveValue('andy')
    expect(screen.getByLabelText('Custom CSS')).toHaveValue('')
    expect(screen.getByLabelText('--text override')).toHaveValue('')
    const resetFrame = screen.getByTitle('CSS Lab component preview') as HTMLIFrameElement
    await waitFor(() => expect(within(resetFrame.contentDocument!.body).getByTestId('real-gallery')).toBeInTheDocument())
  })

  it('copies and downloads the exact standalone export', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText } })
    const createObjectURL = vi.fn((_blob: Blob) => 'blob:css-lab')
    const revokeObjectURL = vi.fn()
    Object.defineProperty(URL, 'createObjectURL', { configurable: true, value: createObjectURL })
    Object.defineProperty(URL, 'revokeObjectURL', { configurable: true, value: revokeObjectURL })
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => undefined)
    render(<DesignSystemCssLabPage />)
    fireEvent.change(screen.getByLabelText('Base theme'), { target: { value: 'light' } })
    fireEvent.change(screen.getByLabelText('Custom CSS'), { target: { value: ':root { --bg: papayawhip; }' } })
    fireEvent.change(screen.getByLabelText('--text override'), { target: { value: 'rebeccapurple' } })
    const expected = buildCssExport('light', { '--text': 'rebeccapurple' }, ':root { --bg: papayawhip; }')

    fireEvent.click(screen.getByRole('button', { name: 'Copy CSS' }))
    await waitFor(() => expect(writeText).toHaveBeenCalledWith(expected))

    fireEvent.click(screen.getByRole('button', { name: 'Download CSS' }))
    const blob = createObjectURL.mock.calls[0][0] as Blob
    const downloaded = await new Promise<string>((resolve, reject) => {
      const reader = new FileReader()
      reader.addEventListener('load', () => resolve(String(reader.result)))
      reader.addEventListener('error', () => reject(reader.error))
      reader.readAsText(blob)
    })
    expect(downloaded).toBe(expected)
    expect(click).toHaveBeenCalledOnce()
    expect(revokeObjectURL).toHaveBeenCalledWith('blob:css-lab')
  })

  it('allows incomplete token typing while keeping the last valid value', async () => {
    render(<DesignSystemCssLabPage />)
    const frame = screen.getByTitle('CSS Lab component preview') as HTMLIFrameElement
    await waitFor(() => expect(within(frame.contentDocument!.body).getByTestId('real-gallery')).toBeInTheDocument())
    const input = screen.getByLabelText('--text override')
    fireEvent.change(input, { target: { value: 'gold' } })
    fireEvent.change(input, { target: { value: 'rgb(' } })
    expect(input).toHaveValue('rgb(')
    expect(screen.getByRole('alert')).toHaveTextContent(/last valid token value/i)
    expect(frame.contentDocument!.getElementById('css-lab-token-overrides')?.textContent).toContain('--text: gold')
    fireEvent.change(input, { target: { value: 'rgb(255, 0, 0)' } })
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(frame.contentDocument!.getElementById('css-lab-token-overrides')?.textContent).toContain('rgb(255, 0, 0)')
    fireEvent.change(screen.getByLabelText('--text colour'), { target: { value: '#112233' } })
    expect(input).toHaveValue('#112233')
  })

  it('reports clipboard unavailability without throwing', async () => {
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: undefined })
    render(<DesignSystemCssLabPage />)
    fireEvent.click(screen.getByRole('button', { name: 'Copy CSS' }))
    expect(await screen.findByRole('status')).toHaveTextContent(/clipboard unavailable/i)
  })
})
