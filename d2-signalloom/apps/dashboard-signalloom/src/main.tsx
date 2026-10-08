import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { OidcProvider } from './auth/oidc'
import { FeatureFlagProvider } from './providers/FeatureFlagProvider'
import App from './App'
import './index.css'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <OidcProvider>
    <FeatureFlagProvider>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </FeatureFlagProvider>
  </OidcProvider>
)
