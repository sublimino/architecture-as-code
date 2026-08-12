import { Link } from 'react-router-dom'
import { Compass } from 'lucide-react'
import { Card } from '../components/ui'

export default function NotFoundPage() { return <div className="not-found"><Card><Compass size={32} /><span className="eyebrow">404 · Route not found</span><h1>This path is outside the demo.</h1><p>Return to the trust overview and choose an investigation from the navigation.</p><Link className="button button--primary" to="/">Return to overview</Link></Card></div> }
