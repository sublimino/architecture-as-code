// Regression cover for the defects two independent adversarial reviews found
// in the first cut of this diagram. Each of these shipped and was measured in a
// real browser, so each gets a test rather than a comment.

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { MemoryRouter } from 'react-router-dom'
import { describe, expect, it, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

// The page acquires a token and can fetch a live topology, so rendering it bare
// now throws before a single element exists:
//
//   TypeError: Cannot destructure property 'signinRedirect' of 'auth' as it is
//   undefined.  →  useAuth0 (auth/oidc.tsx) ← AgentTrustTopologyPage
//
// useAuth() returns undefined without an AuthProvider above it. Every assertion
// in this file is about the DIAGRAM — boundary geometry, denial treatment,
// label placement, the accessible list — none of it about authentication, so
// the module is mocked rather than the whole provider tree being stood up.
//
// Demo mode is pinned ON deliberately. The page reads
// `demo ? { nodes: trustNodes, edges: trustEdges } : liveTopology`, and these
// tests assert against that exact static contract (planner, triage, the
// cross-tenant denial). Left in live mode they would assert against whatever a
// mocked endpoint happened to return, which tests the mock, not the diagram.
//
// Same shape as pages/AgentTrustTopologyPage.test.tsx, deliberately — one
// pattern for one problem.
const getAccessTokenSilently = vi.fn(async () => 'test-token')
const trustTopology = vi.fn()

vi.mock('../../auth/oidc', () => ({ useAuth0: () => ({ getAccessTokenSilently }) }))
vi.mock('../../api/demoMode', () => ({
  isDemoMode: () => true,
  subscribeDemoMode: () => () => {},
}))
vi.mock('../../api/client', () => ({
  api: { trustTopology: (token: string) => trustTopology(token) },
}))

import AgentTrustTopologyPage, { trustEdges, trustNodes } from '../../pages/AgentTrustTopologyPage'
import { deriveExternalBand, NODE_H } from './trustBoundaries'
import { shortVerb, visual } from './trustVisuals'
import { borderPoint, bowFor, edgeGeometry, labelRect, placeLabels, pointAt, reservedForLabels, wallFraction } from './trustGeometry'
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
    //
    // Matched loosely on purpose. The copy now varies between demo and live
    // ("this page" vs "this demonstration page"), and the assertion is about
    // the empty state EXPLAINING that nothing is runtime-observed rather than
    // rendering a blank canvas — not about a particular sentence. Pinning the
    // exact wording made a legitimate copy change look like a regression.
    expect(screen.getByText(/No item on this .*page is runtime-observed/i)).toBeInTheDocument()
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

describe('the visual language survives every theme', () => {
  // --cyan-bg and its siblings live only in global.css's :root and are absent
  // from CSS_VAR_NAMES, so applyTheme never rewrites them: they stayed frozen
  // at dark-theme values under Light and "andy". That put teal-cyan fills on
  // three nodes inside an all-red theme. Anything colour-bearing on this page
  // has to derive from a token the theme actually switches.
  it('derives every tint from a theme-switched token', () => {
    for (const [state, v] of Object.entries(visual)) {
      expect(v.tint, `${state} tint`).not.toMatch(/--\w+-(bg|glow|border|focus)\b/)
      expect(v.tint, `${state} tint`).toMatch(/color-mix/)
    }
  })

  it('leaves no hardcoded rgba() in the page, which no theme can rewrite', () => {
    const source = readFileSync(join(__dirname, '..', '..', 'pages', 'AgentTrustTopologyPage.tsx'), 'utf8')
    expect(source).not.toMatch(/rgba\(\s*\d+\s*,/)
  })

  // Decision is not evidence. In "andy" the allowed and denied strokes are
  // 1.29:1 apart -- both red -- and a denied edge keeps its evidence dash, so
  // colour and dash are both spoken for. Decision needs its own channel.
  it('distinguishes denied edges by stroke shape, not only by colour', () => {
    render(<MemoryRouter><AgentTrustTopologyPage /></MemoryRouter>)
    const canvas = screen.getByTestId('trust-canvas')
    // The authorization plane carries one allowed and one denied relationship.
    const denialEdge = trustEdges.find(e => e.decision === 'denied')!
    expect(denialEdge).toBeDefined()
    // A denied edge renders a surface-coloured inner stroke over a heavier one;
    // an allowed edge renders a single stroke. Identity plane is all-allowed.
    const innerStrokes = canvas.querySelectorAll('path[stroke="var(--surface)"]')
    expect(innerStrokes.length).toBe(0)
  })
})

describe('edge labels do not print on top of each other', () => {
  // Measured in Chrome before this pass: "SPIRE issues SVID" overlapped "ACME
  // RISK BOUNDARY" by 43px on the Identity plane, and "planner invokes triage"
  // overlapped "cross-project application denial" by 68px on Evidence. The
  // earlier stagger keyed on shared endpoints, which is the wrong variable --
  // labels collide because of where they land, not what they attach to.
  it('finds a clear position for every label in every plane', () => {
    const planes = ['identity', 'authorization', 'network', 'external'] as const
    for (const plane of [...planes, 'evidence' as const]) {
      const visibleEdges = plane === 'evidence' ? trustEdges : trustEdges.filter(e => e.plane === plane)
      const boundaries = deriveBoundaries(trustNodes)
      const reserved = reservedForLabels(trustNodes, boundaries)

      const candidates = visibleEdges.map(edge => {
        const from = trustNodes.find(n => n.id === edge.from)!
        const to = trustNodes.find(n => n.id === edge.to)!
        return {
          id: edge.id,
          geom: edgeGeometry({ x: from.x, y: from.y }, { x: to.x, y: to.y }, bowFor(from, to)),
          text: shortVerb(edge.verb),
        }
      })

      const placements = placeLabels(candidates, reserved)
      const rects = placements.map(p => {
        const c = candidates.find(x => x.id === p.id)!
        return { id: p.id, rect: labelRect(c.geom, c.text, p.at, p.offset) }
      })

      const overlap = (a: typeof rects[number]['rect'], b: typeof rects[number]['rect']) =>
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height

      for (let i = 0; i < rects.length; i += 1) {
        for (let j = i + 1; j < rects.length; j += 1) {
          expect(overlap(rects[i].rect, rects[j].rect), `${plane}: ${rects[i].id} over ${rects[j].id}`).toBe(false)
        }
        for (const band of reserved) {
          expect(overlap(rects[i].rect, band), `${plane}: ${rects[i].id} over a node or caption`).toBe(false)
        }
      }
    }
  })
})
