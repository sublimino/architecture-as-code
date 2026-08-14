// The provenance line that sits beside converted money figures.
//
// A converted number with no stated rate and no stated date is a number nobody
// can defend when a regulator asks how the figure on slide 12 was arrived at.
// That is the entire reason the FX table is checked in rather than fetched, so
// the date it carries has to reach the screen — a rate table nobody can see is
// worth no more than a network call nobody recorded.
//
// Renders nothing when there is nothing to disclose (the user is viewing
// figures in their source currency, so no conversion happened). Silence in that
// case is deliberate: a "converted at 1.0" line on every unconverted page
// trains readers to skip the line on the pages where it matters.

export interface ConversionNoteProps {
  /** From `useMoney().conversionNote` — null when nothing was converted. */
  note: string | null
  testId?: string
}

export default function ConversionNote({ note, testId = 'conversion-note' }: ConversionNoteProps) {
  if (note === null) return null

  return (
    <div
      data-testid={testId}
      style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4 }}
    >
      {note}
    </div>
  )
}
