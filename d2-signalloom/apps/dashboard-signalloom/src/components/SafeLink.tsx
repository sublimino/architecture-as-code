import type { ReactNode, CSSProperties, MouseEventHandler } from 'react'
import { Link, useInRouterContext, type To } from 'react-router-dom'

export interface SafeLinkProps {
  to: To
  children: ReactNode
  className?: string
  style?: CSSProperties
  'data-testid'?: string
  title?: string
  onMouseEnter?: MouseEventHandler<HTMLAnchorElement>
  onMouseLeave?: MouseEventHandler<HTMLAnchorElement>
  onClick?: MouseEventHandler<HTMLAnchorElement>
}

/**
 * SafeLink renders a react-router Link if inside a Router context,
 * or falls back gracefully to a standard anchor <a> tag if rendered outside.
 */
export function SafeLink({ to, children, ...rest }: SafeLinkProps) {
  const inRouter = useInRouterContext()
  const href = typeof to === 'string' ? to : `${to.pathname ?? ''}${to.search ?? ''}${to.hash ?? ''}`

  if (inRouter) {
    return (
      <Link to={to} {...rest}>
        {children}
      </Link>
    )
  }

  return (
    <a href={href} {...rest}>
      {children}
    </a>
  )
}

export default SafeLink
