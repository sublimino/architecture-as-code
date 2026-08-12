import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import App from './App'
import { PreferencesProvider } from './state/preferences'
import './styles/global.css'

ReactDOM.createRoot(document.getElementById('root')!).render(<React.StrictMode><BrowserRouter future={{ v7_startTransition: true, v7_relativeSplatPath: true }}><PreferencesProvider><a className="skip-link" href="#main-content">Skip to content</a><App /></PreferencesProvider></BrowserRouter></React.StrictMode>)
