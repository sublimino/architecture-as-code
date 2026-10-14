/**
 * CEL (Common Expression Language) Prettifier and Formatter
 *
 * Intelligently formats CEL expressions into readable multi-line code with
 * consistent indentation, logical operator splitting (&&, ||), ternary alignment,
 * and macro argument spacing.
 */

export interface PrettifyOptions {
  indentSize?: number
  maxLineLength?: number
}

/**
 * Prettifies a CEL expression into indented, multi-line readable code.
 */
export function prettifyCel(expr: string, options: PrettifyOptions = {}): string {
  if (!expr || !expr.trim()) return expr

  const trimmed = expr.trim()

  // Do not format comment-only blocks or empty expressions
  if (trimmed.startsWith('/*') && trimmed.endsWith('*/') && !trimmed.includes('\n')) {
    return trimmed
  }

  const indentSize = options.indentSize ?? 2
  const indentStr = ' '.repeat(indentSize)

  // Step 1: Tokenize string literals and comments to protect them from splitting
  const stringPlaceholders: string[] = []
  let safeExpr = trimmed.replace(
    /("(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|\/\*[\s\S]*?\*\/|\/\/[^\n]*)/g,
    (match) => {
      stringPlaceholders.push(match)
      return `__CEL_STR_${stringPlaceholders.length - 1}__`
    }
  )

  // Step 2: Normalize spacing around binary operators
  safeExpr = safeExpr
    .replace(/\s+/g, ' ')
    .replace(/\s*([=!<>]={1,2})\s*/g, ' $1 ')
    .replace(/\s*(&&|\|\|)\s*/g, ' $1 ')
    .replace(/\s*\?\s*/g, ' ? ')
    .replace(/\s*:\s*/g, ' : ')
    .replace(/\(\s+/g, '(')
    .replace(/\s+\)/g, ')')
    .replace(/\[\s+/g, '[')
    .replace(/\s+\]/g, ']')
    .replace(/,\s*/g, ', ')

  // If short and has no complex operators, keep single line
  const hasLogicalOps = safeExpr.includes(' && ') || safeExpr.includes(' || ') || safeExpr.includes(' ? ')
  if (safeExpr.length <= 60 && !hasLogicalOps) {
    return restorePlaceholders(safeExpr, stringPlaceholders)
  }

  // Step 3: Split into logical lines by tracking parenthesis and brace depths
  const lines: string[] = []
  let current = ''
  let depth = 0
  let i = 0

  while (i < safeExpr.length) {
    const ch = safeExpr[i]

    if (ch === '(' || ch === '[' || ch === '{') {
      depth++
      current += ch
      i++
      continue
    }

    if (ch === ')' || ch === ']' || ch === '}') {
      depth = Math.max(0, depth - 1)
      current += ch
      i++
      continue
    }

    // Check for ternary operators at top level (depth <= 1)
    if (depth <= 1 && safeExpr.slice(i, i + 3) === ' ? ') {
      lines.push(current.trim())
      current = '? '
      i += 3
      continue
    }

    if (depth <= 1 && safeExpr.slice(i, i + 3) === ' : ') {
      lines.push(current.trim())
      current = ': '
      i += 3
      continue
    }

    // Check for logical operators: split if depth <= 1
    if (depth <= 1 && (safeExpr.slice(i, i + 4) === ' && ' || safeExpr.slice(i, i + 4) === ' || ')) {
      const op = safeExpr.slice(i + 1, i + 3)
      lines.push(current.trim())
      current = `${op} `
      i += 4
      continue
    }

    current += ch
    i++
  }

  if (current.trim()) {
    lines.push(current.trim())
  }

  // Step 4: Apply indentation to multi-line parts
  const formattedLines = lines.map((line, idx) => {
    if (idx === 0) return line
    // Continuation lines (starting with &&, ||, ?, :) indent one level
    if (line.startsWith('&& ') || line.startsWith('|| ') || line.startsWith('? ') || line.startsWith(': ')) {
      return indentStr + line
    }
    return indentStr + line
  })

  const result = formattedLines.join('\n')
  return restorePlaceholders(result, stringPlaceholders)
}

function restorePlaceholders(str: string, placeholders: string[]): string {
  return str.replace(/__CEL_STR_(\d+)__/g, (_, idx) => {
    return placeholders[Number(idx)] ?? ''
  })
}
