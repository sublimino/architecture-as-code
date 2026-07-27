import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ComponentProps } from 'react'
import WizardFieldRenderer from './WizardFieldRenderer'
import type { WizardFieldSpec } from '../../types/connectors'

const FIELDS: WizardFieldSpec[] = [
  { name: 'tenant_directory_id', label: 'Directory (tenant) ID', type: 'text', required: true, placeholder: '00000000-...' },
  { name: 'client_secret', label: 'Client secret', type: 'password', required: true, help_text: 'Found under Certificates & secrets.' },
  {
    name: 'region',
    label: 'Region',
    type: 'select',
    options: [
      { value: 'us', label: 'United States' },
      { value: 'eu', label: 'Europe' },
    ],
  },
]

function setup(overrides: Partial<ComponentProps<typeof WizardFieldRenderer>> = {}) {
  const onChange = vi.fn()
  render(
    <WizardFieldRenderer
      fields={FIELDS}
      values={overrides.values ?? {}}
      onChange={overrides.onChange ?? onChange}
      disabled={overrides.disabled}
    />,
  )
  return { onChange }
}

describe('WizardFieldRenderer', () => {
  it('renders one input per field, labelled', () => {
    setup()
    expect(screen.getByLabelText(/directory \(tenant\) id/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/client secret/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/region/i)).toBeInTheDocument()
  })

  it('marks required fields with an asterisk', () => {
    setup()
    expect(screen.getByText(/directory \(tenant\) id \*/i)).toBeInTheDocument()
    expect(screen.getByText(/^region$/i)).toBeInTheDocument() // not required — no asterisk
  })

  it('renders string fields as plain text inputs', () => {
    setup()
    const input = screen.getByLabelText(/directory \(tenant\) id/i) as HTMLInputElement
    expect(input.type).toBe('text')
    expect(input.placeholder).toBe('00000000-...')
  })

  it('renders secret fields as masked password inputs', () => {
    setup()
    const input = screen.getByLabelText(/client secret/i) as HTMLInputElement
    expect(input.type).toBe('password')
  })

  it('never pre-fills a secret field from a passed-in value (write-only)', () => {
    setup({ values: {} })
    const input = screen.getByLabelText(/client secret/i) as HTMLInputElement
    expect(input.value).toBe('')
  })

  it('renders select fields with the given options', () => {
    setup()
    expect(screen.getByRole('option', { name: 'United States' })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Europe' })).toBeInTheDocument()
  })

  it('shows field help text when provided', () => {
    setup()
    expect(screen.getByText(/found under certificates & secrets/i)).toBeInTheDocument()
  })

  it('calls onChange with the field key and new value on input', async () => {
    const { onChange } = setup()
    await userEvent.type(screen.getByLabelText(/directory \(tenant\) id/i), 'x')
    expect(onChange).toHaveBeenCalledWith('tenant_directory_id', 'x')
  })

  it('calls onChange with the field key on select change', async () => {
    const { onChange } = setup()
    await userEvent.selectOptions(screen.getByLabelText(/region/i), 'eu')
    expect(onChange).toHaveBeenCalledWith('region', 'eu')
  })

  it('disables all inputs when disabled is true', () => {
    setup({ disabled: true })
    expect(screen.getByLabelText(/directory \(tenant\) id/i)).toBeDisabled()
    expect(screen.getByLabelText(/client secret/i)).toBeDisabled()
    expect(screen.getByLabelText(/region/i)).toBeDisabled()
  })

  it('reflects controlled values passed in', () => {
    setup({ values: { tenant_directory_id: 'abc-123' } })
    expect(screen.getByLabelText(/directory \(tenant\) id/i)).toHaveValue('abc-123')
  })
})
