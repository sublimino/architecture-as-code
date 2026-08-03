// Regression cover for the defects two independent adversarial reviews found
// in the first cut of this diagram. Each of these shipped and was measured in a
// real browser, so each gets a test rather than a comment.

import { describe, expect, it } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

import AgentTrustTopologyPage, { trustEdges, trustNodes } from '../../pages/AgentTrustTopologyPage'
import { deriveExternalBand, NODE_H } from './trustBoundaries'
import { borderPoint, bowFor, edgeGeometry, pointAt, wallFraction } from './trustGeometry'
import { deriveBoundaries } from './trustBoundaries'

describe('the external band is bounded by its members, not by the canvas', () => {
  // It used to be `canvasHeight - y`, mixing CSS pixels into graph coordinates.
  // It enclosed the external row by about 12px of luck; moving that row at all
  // left the workloads hanging outside the band that claims to contain them.
  it('encloses every external node wherever the external row is placed', () => {
    for (const shift of [0, 60, 120, 400]) {
      const shifted = trustNodes.map(node =>
        node.location === 'external' ? { ...node, y: node.y + shift } : node)
      const band = deriveExternalBand(shifted)!
      for (const node of shifted.filter(n => n.location === 'external')) {
        expect(node.y - NODE_H / 2, `top of ${node.id} at shift ${shift}`).toBeGreaterThanOrEqual(band.y)
        expect(node.y + NODE_H / 2, `bottom of ${node.id} at shift ${shift}`)
          .toBeLessThanOrEqual(band.y + band.height)
      }
    }
  })
})

describe('the denial wall stands on the boundary, not past it', () => {
  it('lands within a pixel of the tenant edge it represents', () => {
    const edge = trustEdges.find(item => item.denialKind === 'network-block')!
    const from = trustNodes.find(n => n.id === edge.from)!
    const to = trustNodes.find(n => n.id === edge.to)!
    const boundaries = deriveBoundaries(trustNodes)
    const acme = boundaries.find(b => b.id === 'boundary-acme')!

    const geom = edgeGeometry({ x: from.x, y: from.y }, { x: to.x, y: to.y }, bowFor(from, to))
    const wall = pointAt(geom.start, geom.control, geom.end, wallFraction(geom, boundaries, edge.from))

    // The crossing is on the right-hand wall of the Acme tenant box. A coarse
    // 60-step scan put it 7.53px beyond; bisection has to do far better, or the
    // packet that "gets as far as the wall and no further" visibly gets past it.
    const distanceOutside = wall.x - (acme.x + acme.width)
    expect(Math.abs(distanceOutside)).toBeLessThan(1)
  })
})

describe('edge attachment never inverts', () => {
  it('keeps the attachment point between the two nodes however close they are', () => {
    for (const gap of [40, 60, 120, 300]) {
      const from = { x: 0, y: 0 }
      const to = { x: gap, y: 0 }
      const point = borderPoint(from, to)
      expect(point.x, `gap ${gap}`).toBeGreaterThanOrEqual(0)
      expect(point.x, `gap ${gap}`).toBeLessThanOrEqual(gap)
    }
  })

  it('never draws a same-row edge backwards, however tight the spacing', () => {
    // At 60px the two 190px boxes overlap completely, so both attachment points
    // collapse onto the midpoint and the edge has no horizontal extent. That is
    // the honest outcome -- there is no sensible place to attach -- and it is
    // still strictly better than the unclamped behaviour, which produced
    // dx = -42 for a requested +60 and drew the relationship pointing the wrong
    // way. The guarantee is direction, not length.
    for (const gap of [60, 120, 210, 270]) {
      const geom = edgeGeometry({ x: 0, y: 0 }, { x: gap, y: 0 }, -1)
      expect(geom.end.x, `gap ${gap}`).toBeGreaterThanOrEqual(geom.start.x)
    }
    // At real spacing the edge has proper extent in the right direction.
    const real = edgeGeometry({ x: 0, y: 0 }, { x: 270, y: 0 }, -1)
    expect(real.end.x).toBeGreaterThan(real.start.x)
  })
})

describe('the page under filtering', () => {
  // Measured in Chrome as hot=0, dim=20: hovering an item and then filtering it
  // away left every node, edge and boundary faded with nothing highlighted, and
  // moving the mouse did not recover it. A vanished element never fires
  // mouseleave, and on touch there is no mouseleave at all.
  it('never dims the whole diagram with nothing highlighted', async () => {
    const user = userEvent.setup()
    render(<AgentTrustTopologyPage />)

    await user.hover(screen.getByRole('button', { name: /planner · in-cluster/i }))
    await user.selectOptions(screen.getByLabelText('Tenant'), 'northstar')

    const canvas = screen.getByTestId('trust-canvas')
    const dimmed = canvas.querySelectorAll('.trust-node--dim').length
    const hot = canvas.querySelectorAll('.trust-node--hot').length
    expect(dimmed === 0 || hot > 0).toBe(true)
  })

  // A tenant operator opening the Identity plane for their own tenant saw
  // "9 nodes · 0 relationships", because SPIRE and OpenBao are tenant 'shared'
  // and were filtered out with the other tenants -- taking every SVID issuance
  // for that tenant's own agents with them.
  it('keeps shared platform services when filtering to one tenant', async () => {
    const user = userEvent.setup()
    render(<AgentTrustTopologyPage />)

    await user.selectOptions(screen.getByLabelText('Tenant'), 'acme')

    const list = screen.getByRole('group', { name: 'Selectable topology items' })
    expect(within(list).getByRole('button', { name: /^SPIRE issuer ·/ })).toBeInTheDocument()
    expect(within(list).getByRole('button', { name: /^OpenBao ·/ })).toBeInTheDocument()
    // The point of keeping them: the tenant's identity chain is visible again.
    expect(within(list).getAllByRole('button', { name: /SPIRE issues SVID/ }).length).toBeGreaterThan(0)
  })

  it('explains an empty result instead of showing a blank canvas', async () => {
    const user = userEvent.setup()
    render(<AgentTrustTopologyPage />)

    await user.selectOptions(screen.getByLabelText('Evidence'), 'observed')

    expect(screen.getByText(/Nothing matches these filters/i)).toBeInTheDocument()
    // The page's central claim, stated where the reader trips over it.
    expect(screen.getByText(/No item on this page is runtime-observed/i)).toBeInTheDocument()
    expect(screen.queryByTestId('trust-canvas')).not.toBeInTheDocument()
  })
})

describe('relationships are distinguishable from each other', () => {
  // spire->planner and spire->investigator cross DIFFERENT TENANTS but every
  // other field matches, so both the buttons and the inspector panels were
  // byte-identical. On a page about which identity trusts which, that is a
  // failure of its core job.
  it('gives every selectable relationship a unique accessible name', () => {
    render(<AgentTrustTopologyPage />)
    const list = screen.getByRole('group', { name: 'Selectable topology items' })
    const names = within(list).getAllByRole('button').map(b => b.textContent ?? '')
    expect(new Set(names).size).toBe(names.length)
  })

  it('names both endpoints in the inspector so two similar edges differ', async () => {
    const user = userEvent.setup()
    render(<AgentTrustTopologyPage />)
    await user.click(screen.getByRole('button', { name: /^Evidence plane$/i }))

    const list = screen.getByRole('group', { name: 'Selectable topology items' })
    const inspector = screen.getByRole('complementary', { name: 'Persistent topology details' })

    await user.click(within(list).getByRole('button', { name: /SPIRE issuer → planner/ }))
    const first = inspector.textContent ?? ''
    await user.click(within(list).getByRole('button', { name: /SPIRE issuer → investigator/ }))
    const second = inspector.textContent ?? ''

    expect(first).not.toBe(second)
    expect(first).toContain('SPIRE issuer → planner')
    expect(second).toContain('SPIRE issuer → investigator')
  })

  it('marks which item is currently pinned', async () => {
    const user = userEvent.setup()
    render(<AgentTrustTopologyPage />)
    const list = screen.getByRole('group', { name: 'Selectable topology items' })
    const planner = within(list).getByRole('button', { name: /planner · in-cluster/i })

    expect(planner).toHaveAttribute('aria-pressed', 'false')
    await user.click(planner)
    expect(planner).toHaveAttribute('aria-pressed', 'true')
  })
})

describe('the canvas is decoration, the list is the interface', () => {
  // React Flow made every node a tabbable role=group described by its stock
  // "press enter to select, arrows to move, delete to remove" text. All three
  // were false here, so screen-reader users met 15 dead stops carrying wrong
  // instructions before reaching the buttons that work -- and heard every node
  // name twice.
  it('hides the drawn canvas from assistive technology', () => {
    render(<AgentTrustTopologyPage />)
    expect(screen.getByTestId('trust-canvas')).toHaveAttribute('aria-hidden', 'true')
  })

  it('reaches every node and relationship through the button list', () => {
    render(<AgentTrustTopologyPage />)
    const list = screen.getByRole('group', { name: 'Selectable topology items' })
    const buttons = within(list).getAllByRole('button')
    // Identity plane: all 15 nodes plus its 3 relationships.
    expect(buttons.length).toBe(trustNodes.length + 3)
  })

  it('labels the Decision filter with the word shown next to it', () => {
    render(<AgentTrustTopologyPage />)
    // WCAG 2.5.3: a voice-control user saying "Decision" has to be able to hit
    // the control that visibly reads "Decision".
    expect(screen.getByLabelText('Decision')).toBeInTheDocument()
  })
})
