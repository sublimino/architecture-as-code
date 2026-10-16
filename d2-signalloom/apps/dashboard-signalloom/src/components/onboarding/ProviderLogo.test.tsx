import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import ProviderLogo from './ProviderLogo'

describe('ProviderLogo', () => {
  it('renders official Kubernetes logo for k8s and kubernetes providerIds', () => {
    const { unmount } = render(<ProviderLogo providerId="k8s" displayName="Kubernetes Cluster" />)
    const k8sImg = screen.getByRole('img', { name: /Kubernetes Cluster logo/i })
    expect(k8sImg).toBeInTheDocument()
    expect(k8sImg.getAttribute('src')).toMatch(/kubernetes\.svg/i)
    unmount()

    render(<ProviderLogo providerId="kubernetes" displayName="Kubernetes" />)
    const kubernetesImg = screen.getByRole('img', { name: /Kubernetes logo/i })
    expect(kubernetesImg).toBeInTheDocument()
    expect(kubernetesImg.getAttribute('src')).toMatch(/kubernetes\.svg/i)
  })

  it('renders official GitHub logo for github providerId', () => {
    render(<ProviderLogo providerId="github" displayName="GitHub Enterprise" />)
    const githubImg = screen.getByRole('img', { name: /GitHub Enterprise logo/i })
    expect(githubImg).toBeInTheDocument()
    expect(githubImg.getAttribute('src')).toMatch(/github\.svg/i)
  })

  it('renders fallback initial-letter avatar when provider is unknown', () => {
    render(<ProviderLogo providerId="unknown_custom_idp" displayName="Zeta Auth" />)
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
    expect(screen.getByText('Z')).toBeInTheDocument()
  })
})
