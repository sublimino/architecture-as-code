import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { OidcProvider } from './auth/oidc'
import App from './App'
import './index.css'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <OidcProvider>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </OidcProvider>
)
