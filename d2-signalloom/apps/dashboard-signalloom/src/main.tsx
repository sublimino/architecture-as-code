import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { OidcProvider } from './auth/oidc'
import { FeatureFlagProvider } from './providers/FeatureFlagProvider'
import App from './App'
import './index.css'

// Handle Vite stale chunk 404s after new deployments by reloading to fetch latest manifest
if (typeof window !== 'undefined') {
  window.addEventListener('vite:preloadError', () => {
    const lastReload = sessionStorage.getItem('vite_preload_retry')
    const now = Date.now()
    if (!lastReload || now - parseInt(lastReload, 10) > 10000) {
      sessionStorage.setItem('vite_preload_retry', String(now))
      window.location.reload()
    }
  })

  window.addEventListener('unhandledrejection', (event) => {
    const msg = event.reason?.message || String(event.reason || '')
    if (
      msg.includes('Failed to fetch dynamically imported module') ||
      msg.includes('error loading dynamically imported module')
    ) {
      const lastReload = sessionStorage.getItem('vite_chunk_reload')
      const now = Date.now()
      if (!lastReload || now - parseInt(lastReload, 10) > 10000) {
        sessionStorage.setItem('vite_chunk_reload', String(now))
        window.location.reload()
      }
    }
  })
}

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false,
      retry: 1,
    },
  },
})

ReactDOM.createRoot(document.getElementById('root')!).render(
  <OidcProvider>
    <QueryClientProvider client={queryClient}>
      <FeatureFlagProvider>
        <BrowserRouter>
          <App />
        </BrowserRouter>
      </FeatureFlagProvider>
    </QueryClientProvider>
  </OidcProvider>
)

