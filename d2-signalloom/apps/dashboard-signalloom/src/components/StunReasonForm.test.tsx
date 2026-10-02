import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import StunReasonForm, { validateStunReason, STUN_REASON_MAX } from './StunReasonForm'

describe('validateStunReason', () => {
  it('rejects empty and whitespace-only input', () => {
    expect(validateStunReason('')).toMatchObject({ ok: false })
    expect(validateStunReason('   \t ')).toMatchObject({ ok: false })
  })

  it('trims, and accepts 1..256 characters', () => {
    expect(validateStunReason('  x  ')).toEqual({ ok: true, reason: 'x' })
    expect(validateStunReason('y'.repeat(STUN_REASON_MAX))).toMatchObject({ ok: true })
    expect(validateStunReason('y'.repeat(STUN_REASON_MAX + 1))).toMatchObject({ ok: false })
  })
})

describe('StunReasonForm', () => {
  function setup() {
    const onConfirm = vi.fn()
    const onCancel = vi.fn()
    render(<StunReasonForm agentName="Cardvault Agent" onConfirm={onConfirm} onCancel={onCancel} />)
    return { onConfirm, onCancel }
  }

  it('blocks an empty reason and says why', async () => {
    const { onConfirm } = setup()
    await userEvent.click(screen.getByRole('button', { name: /Confirm stun/ }))
    expect(onConfirm).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toHaveTextContent(/reason is required/i)
  })

  it('blocks a whitespace-only reason', async () => {
    const { onConfirm } = setup()
    await userEvent.type(screen.getByLabelText(/Reason for stunning Cardvault Agent/), '    ')
    await userEvent.click(screen.getByRole('button', { name: /Confirm stun/ }))
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it('sends free text, trimmed', async () => {
    const { onConfirm } = setup()
    await userEvent.type(screen.getByLabelText(/Reason for stunning/), '  exfil to unknown host  ')
    await userEvent.click(screen.getByRole('button', { name: /Confirm stun/ }))
    expect(onConfirm).toHaveBeenCalledWith('exfil to unknown host')
  })

  it('offers suggested reasons that fill the field', async () => {
    const { onConfirm } = setup()
    const suggestion = screen.getAllByRole('button', { name: /^Use reason: / })[0]
    const text = (suggestion.textContent ?? '').trim()
    await userEvent.click(suggestion)
    expect(screen.getByLabelText(/Reason for stunning/)).toHaveValue(text)
    await userEvent.click(screen.getByRole('button', { name: /Confirm stun/ }))
    expect(onConfirm).toHaveBeenCalledWith(text)
  })

  it('cancels without confirming', async () => {
    const { onConfirm, onCancel } = setup()
    await userEvent.click(screen.getByRole('button', { name: /Cancel/ }))
    expect(onCancel).toHaveBeenCalledTimes(1)
    expect(onConfirm).not.toHaveBeenCalled()
  })
})
