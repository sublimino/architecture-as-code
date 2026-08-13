import type { CSSProperties } from 'react'
import PixelLoader from './PixelLoader'

// ─────────────────────────────────────────────────────────────────────────────
// BUTTON WAIT — the loader family's in-button member.
//
// This is PixelLoader with four decisions taken for it, and those four
// decisions are the entire reason it is a component rather than a call-site
// idiom. It had been invented twice already: FleetDemoPage had a private
// function of this name driving five buttons, and SuperCredPage,
// RbacImporterPanel and CredentialEvidencePanel each open-coded the same thing
// with their own width constants. Two shapes for one idea, and they had drifted
// — some buttons showed a word and some did not, some announced twice and some
// were nameless while busy.
//
// A loader that OWNS A LINE and a loader INSIDE A CONTROL are not the same
// component wearing different sizes. Four things invert:
//
// 1. NO VISIBLE WORD. A standalone loader must say what is running, because
//    nothing else on the line does. In a button, the button's own text just
//    said it — "Deploy Fleet" was there a frame ago and the operator is the
//    person who clicked it. Repeating "Deploying" inside is noise, and at 13px
//    inside an 11px control it is noise that is out of scale. So `label` is
//    rendered for assistive technology only. It is the ACCESSIBLE name, not a
//    caption.
//
// 2. THE BUTTON MUST NOT RESIZE. A standalone loader may grow; nothing is
//    beside it. A button that grows drags its whole toolbar sideways, and the
//    elapsed figure gains a character twice — at 10.0s and again at 1m 0.0s —
//    so a shrink-to-fit control visibly jumps mid-demo, which reads to a room
//    as a fault. The width here is RESERVED, not measured: `WAIT_W` already
//    fits the figure at its longest, and PixelLoader's tabular figures stop
//    the digits jittering underneath it. The call site's job is the other
//    half — a `minWidth` on the button that already fits its busy state, so
//    the idle→busy swap does not move anything either.
//
// 3. IT MUST NOT STEAL THE ACCESSIBLE NAME. Replacing a button's text with a
//    grid of squares removes the only thing that named the control. Every call
//    site had noticed, and every call site had fixed it locally with
//    `aria-label={loading ? 'Stunning' : undefined}` — except the three that
//    got away with it because their loader still showed a visible word.
//    That ternary is now HERE, as a visually-hidden span, for one reason: the
//    obligation is created by this component (it is what deleted the text), so
//    it belongs to this component. Leaving it at the call site means the next
//    button to adopt this is a coin toss on whether its author remembers. A
//    call site that wants a different name may still set `aria-label` on the
//    button and it wins, per the accessible-name computation — pinned in the
//    tests.
//
// 4. NO NESTED LIVE REGION. PixelLoader is `role="status"` `aria-live="polite"`
//    by default, which is right when it is the only thing announcing. Inside an
//    interactive control it is wrong on its own terms: a live region in a
//    <button> is announced on focus and again on every mutation, and this one
//    mutates ten times a second. `announce={false}` stops the region being
//    created; the `aria-hidden` wrapper then keeps the grid and the counting
//    digits out of the accessibility tree entirely, leaving the button with a
//    name and nothing else. Several of these buttons also sit beside a
//    LoadingState, which IS a live region for the same operation — one
//    announcement per operation, and it is the one that survives the phase
//    change into success or failure.
//
// Reduced motion, the elapsed clock and the theme tokens are not re-decided
// here. They are PixelLoader's, unchanged, because the in-button wait must
// look like a smaller member of the same family and not like a second loader.
// The variant is deliberately not passed either, so this follows the family
// default wherever that goes.
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Grid + gap + the figure at its longest ("1m 5.0s"), with no word.
 *
 * One number for every in-button wait in the app. The four call sites had
 * 78 / 124 / 144 twice over, which is why they did not look like each other.
 */
const WAIT_W = 78

/** Tighter than PixelLoader's default 10: inside a control, 10 reads as slack. */
const WAIT_GAP = 6

/**
 * Inline rather than the `.sr-only` class in global.css, which does the same
 * job for Sidebar. Here the hiding is load-bearing for LAYOUT, not just for
 * politeness: if the rule ever failed to reach this element the label would
 * become visible text inside a width-reserved button, which is the exact
 * jitter decision 2 exists to prevent. A style attribute cannot fail to arrive.
 */
const HIDDEN_LABEL: CSSProperties = {
  position: 'absolute',
  width: 1,
  height: 1,
  overflow: 'hidden',
  clip: 'rect(0, 0, 0, 0)',
  whiteSpace: 'nowrap',
}

export interface ButtonWaitProps {
  /**
   * What is running, for assistive technology — "Deploying", not "Loading".
   * Never rendered visibly; see decision 1. This becomes the button's
   * accessible name while its own text is gone, so it should read as a name.
   */
  label?: string
  /**
   * Test id for the loader root. Children follow PixelLoader's convention:
   * `${testId}-grid`, `${testId}-label`, `${testId}-elapsed`.
   */
  testId?: string
}

export default function ButtonWait({
  label = 'Working',
  testId = 'button-wait',
}: ButtonWaitProps) {
  return (
    <>
      <span aria-hidden="true" style={{ display: 'inline-flex' }}>
        <PixelLoader
          testId={testId}
          label=""
          announce={false}
          style={{ width: WAIT_W, maxWidth: '100%', gap: WAIT_GAP }}
        />
      </span>
      {/* Not inside the aria-hidden wrapper, and not a sibling by accident:
          this span is the button's accessible name. See decision 3. */}
      <span style={HIDDEN_LABEL}>{label}</span>
    </>
  )
}
