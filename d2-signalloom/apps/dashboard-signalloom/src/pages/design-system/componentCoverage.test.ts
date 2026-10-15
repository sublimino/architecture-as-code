import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import ts from 'typescript'
import { COMPONENT_COVERAGE, coverageKey } from './componentCoverage'
import { CORE_SPECIMEN_NAMES } from './CoreSpecimens'
import { EXTRA_SPECIMEN_NAMES } from './ExtraSpecimens'
import { WORKFLOW_SPECIMEN_NAMES } from './WorkflowSpecimens'

type VisualSymbol = { source: string; symbol: string }

const SRC_ROOT = path.resolve(__dirname, '../..')

function containsJsx(node: ts.Node): boolean {
  let found = false
  const visit = (child: ts.Node) => {
    if (ts.isJsxElement(child) || ts.isJsxSelfClosingElement(child) || ts.isJsxFragment(child)) {
      found = true
      return
    }
    ts.forEachChild(child, visit)
  }
  visit(node)
  return found
}

function hasModifier(node: ts.Node, kind: ts.SyntaxKind): boolean {
  return Boolean(ts.canHaveModifiers(node) && ts.getModifiers(node)?.some((modifier) => modifier.kind === kind))
}

function returnsOnlyNull(node: ts.Node): boolean {
  if (!ts.isFunctionLike(node) || !('body' in node) || !node.body) return false
  const body = node.body
  if (!ts.isBlock(body)) return body.kind === ts.SyntaxKind.NullKeyword

  const returns: (ts.Expression | undefined)[] = []
  const visit = (child: ts.Node) => {
    if (child !== node && ts.isFunctionLike(child)) return
    if (ts.isReturnStatement(child)) returns.push(child.expression)
    ts.forEachChild(child, visit)
  }
  visit(body)
  return returns.length > 0 && returns.every((expression) => expression?.kind === ts.SyntaxKind.NullKeyword)
}

function visualSymbolsInSource(source: ts.SourceFile, sourcePath: string): VisualSymbol[] {
  const declarations = new Map<string, ts.Node>()
  const exportedLocals = new Set<string>()

  for (const statement of source.statements) {
    if ((ts.isFunctionDeclaration(statement) || ts.isClassDeclaration(statement)) && containsJsx(statement) && !returnsOnlyNull(statement)) {
      const name = statement.name?.text ?? 'default'
      declarations.set(name, statement)
      if (hasModifier(statement, ts.SyntaxKind.ExportKeyword)) exportedLocals.add(name)
    }

    if (ts.isVariableStatement(statement)) {
      for (const declaration of statement.declarationList.declarations) {
        if (!ts.isIdentifier(declaration.name) || !declaration.initializer || !containsJsx(declaration.initializer) || returnsOnlyNull(declaration.initializer)) continue
        declarations.set(declaration.name.text, declaration)
        if (hasModifier(statement, ts.SyntaxKind.ExportKeyword)) exportedLocals.add(declaration.name.text)
      }
    }

    if (ts.isExportAssignment(statement) && ts.isIdentifier(statement.expression)) {
      exportedLocals.add(statement.expression.text)
    }
    if (ts.isExportAssignment(statement) && !ts.isIdentifier(statement.expression)) {
      if (containsJsx(statement.expression)) {
        declarations.set('default', statement.expression)
        exportedLocals.add('default')
      } else if (ts.isCallExpression(statement.expression)) {
        const wrapped = statement.expression.arguments.find(ts.isIdentifier)
        if (wrapped && declarations.has(wrapped.text)) exportedLocals.add(wrapped.text)
      }
    }

    if (ts.isExportDeclaration(statement) && statement.exportClause && ts.isNamedExports(statement.exportClause)) {
      for (const element of statement.exportClause.elements) {
        exportedLocals.add((element.propertyName ?? element.name).text)
      }
    }
  }

  const includePageLocals = sourcePath.startsWith('pages/') || sourcePath.startsWith('views/')
  return [...declarations]
    .filter(([name]) => exportedLocals.has(name) || includePageLocals)
    .map(([symbol]) => ({ source: sourcePath, symbol }))
}

function sourceFiles(directory: string): string[] {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const absolute = path.join(directory, entry.name)
    if (entry.isDirectory()) return sourceFiles(absolute)
    if (!entry.name.endsWith('.tsx') || /\.(?:test|spec)\.tsx$/.test(entry.name)) return []
    return [absolute]
  })
}

function actualVisualSymbols(): VisualSymbol[] {
  return sourceFiles(SRC_ROOT).flatMap((absolute) => {
    const sourcePath = path.relative(SRC_ROOT, absolute).split(path.sep).join('/')
    const source = ts.createSourceFile(
      sourcePath,
      fs.readFileSync(absolute, 'utf8'),
      ts.ScriptTarget.Latest,
      true,
      ts.ScriptKind.TSX,
    )
    return visualSymbolsInSource(source, sourcePath)
  })
}

function appRoutePatterns(): RegExp[] {
  const source = ts.createSourceFile(
    'App.tsx',
    fs.readFileSync(path.join(SRC_ROOT, 'App.tsx'), 'utf8'),
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX,
  )
  const paths: string[] = []
  const visit = (node: ts.Node) => {
    if (ts.isJsxAttribute(node) && ts.isIdentifier(node.name) && node.name.text === 'path' && node.initializer) {
      if (ts.isStringLiteral(node.initializer)) paths.push(node.initializer.text)
      if (ts.isJsxExpression(node.initializer) && node.initializer.expression && ts.isStringLiteral(node.initializer.expression)) {
        paths.push(node.initializer.expression.text)
      }
    }
    ts.forEachChild(node, visit)
  }
  visit(source)
  return paths.filter((route) => route !== '*').map((route) => new RegExp(`^${route
    .split('/')
    .map((segment) => segment.startsWith(':') ? '[^/]+' : segment === '*' ? '.*' : segment.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
    .join('/')}$`))
}

describe('visual symbol AST inventory', () => {
  it('finds functions, classes, arrows, memo, forwardRef and aliases without duplicates', () => {
    const source = ts.createSourceFile('pages/Synthetic.tsx', `
      import { forwardRef, memo } from 'react'
      export function FunctionVisual() { return <div /> }
      export class ClassVisual { render() { return <span /> } }
      export const ArrowVisual = () => <main />
      const MemoVisual = memo(() => <aside />)
      const RefVisual = forwardRef((_props, ref) => <button ref={ref} />)
      const AliasVisual = () => <footer />
      export { MemoVisual, RefVisual, AliasVisual as NamedAlias }
      export default AliasVisual
    `, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)

    expect(visualSymbolsInSource(source, 'pages/Synthetic.tsx').map(({ symbol }) => symbol).sort()).toEqual([
      'AliasVisual', 'ArrowVisual', 'ClassVisual', 'FunctionVisual', 'MemoVisual', 'RefVisual',
    ])
  })

  it('canonicalizes wrapped and anonymous default exports', () => {
    const wrapped = ts.createSourceFile('components/Wrapped.tsx', `
      import { memo } from 'react'
      const WrappedSource = () => <div />
      export default memo(WrappedSource)
    `, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
    const anonymous = ts.createSourceFile('components/Anonymous.tsx', `
      export default function () { return <main /> }
    `, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)

    expect(visualSymbolsInSource(wrapped, 'components/Wrapped.tsx')).toEqual([
      { source: 'components/Wrapped.tsx', symbol: 'WrappedSource' },
    ])
    expect(visualSymbolsInSource(anonymous, 'components/Anonymous.tsx')).toEqual([
      { source: 'components/Anonymous.tsx', symbol: 'default' },
    ])
  })

  it('includes view locals while excluding transparent null-returning declarations', () => {
    const source = ts.createSourceFile('views/Synthetic.tsx', `
      function ViewLocal() { return <section /> }
      function TransparentController() {
        const unusedRenderer = () => <aside />
        return null
      }
      export default function View() { return <ViewLocal /> }
    `, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)

    expect(visualSymbolsInSource(source, 'views/Synthetic.tsx')).toEqual([
      { source: 'views/Synthetic.tsx', symbol: 'ViewLocal' },
      { source: 'views/Synthetic.tsx', symbol: 'View' },
    ])
  })

  it('catalogues every actual visual symbol exactly once without stale entries', () => {
    const actual = actualVisualSymbols().map(coverageKey).sort()
    const registered = COMPONENT_COVERAGE.map(coverageKey).sort()
    expect(registered).toEqual(actual)
    expect(new Set(registered).size).toBe(registered.length)
  })

  it('gives linked representations reachable routes and concrete state instructions', () => {
    const routes = appRoutePatterns()
    for (const entry of COMPONENT_COVERAGE) {
      if (entry.kind === 'specimen' || entry.kind === 'route') {
        expect(entry.href).toMatch(/^\/(?:[^#]*)(?:#.*)?$/)
        expect(routes.some((route) => route.test(entry.href.split('#')[0])), `${coverageKey(entry)} -> ${entry.href}`).toBe(true)
      }
      if (entry.kind === 'route') {
        expect(entry.state.trim().length).toBeGreaterThan(4)
        expect(entry.reason.trim().length).toBeGreaterThan(8)
        expect(entry.state).not.toMatch(/relevant record or control/i)
      } else if (entry.kind !== 'specimen') {
        expect(entry.reason.trim().length).toBeGreaterThan(8)
      }
    }
  })

  it('uses the complete truthful representation vocabulary', () => {
    expect(new Set(COMPONENT_COVERAGE.map(({ kind }) => kind))).toEqual(new Set([
      'specimen', 'route', 'unwired', 'internal', 'guard', 'provider',
    ]))
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'components/AuditDetailDrawer.tsx#renderSyntaxHighlightedJson')).toMatchObject({ kind: 'internal' })
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'pages/ConnectorHelpPage.tsx#markdownComponents')).toMatchObject({ kind: 'internal' })
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'components/common/FeatureGate.tsx#FeatureGate')).toMatchObject({ kind: 'guard' })
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'providers/FeatureFlagProvider.tsx#FeatureFlagProvider')).toMatchObject({ kind: 'provider' })
  })

  it('leaves no visual symbol silently unrepresented', () => {
    expect(COMPONENT_COVERAGE.filter(({ kind }) => kind === 'unrepresented')).toEqual([])
  })

  it('records exact active routes and evidence-backed unwired symbols', () => {
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'components/NotificationBell.tsx#NotificationBell')).toMatchObject({
      kind: 'specimen', href: '/design-system#extra-examples',
    })
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'components/onboarding/OnboardingWizard.tsx#OnboardingWizard')).toMatchObject({
      kind: 'route', href: '/onboarding', state: expect.stringMatching(/wizard/i),
    })
    for (const key of [
      'components/SignalFusionDemoControls.tsx#SignalFusionDemoControls',
      'components/CookieSettingsModal.tsx#CookieSettingsModal',
    ]) {
      expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === key), key).toMatchObject({
        kind: 'unwired', reason: expect.stringMatching(/no application imports|no application render/i),
      })
    }
    for (const key of [
      'components/AgentCockpitTelemetry.tsx#TelemetryErrorBoundary',
      'components/onboarding/ProviderConfigureStep.tsx#ProviderConfigureStep',
      'components/trust/TrustTopologyCanvas.tsx#TrustTopologyCanvas',
    ]) {
      expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === key), key).toMatchObject({
        kind: 'specimen', href: '/design-system#extra-examples',
      })
    }
  })

  it('records the existing admin console symbols as explicit route-owned states, not isolated fixtures', () => {
    for (const key of [
      'components/admin/AdminNavTabs.tsx#AdminNavTabs',
      'pages/admin/FeaturesPage.tsx#FeaturesPage',
      'pages/admin/FeaturesPage.tsx#FlagToggle',
    ]) {
      expect(COMPONENT_COVERAGE.find(entry => coverageKey(entry) === key), key).toMatchObject({
        kind: 'route', href: '/admin/features',
        state: expect.stringMatching(/superadmin/i),
        reason: expect.stringMatching(/context|FeaturesPage/),
      })
    }
  })

  it('links header primitives to their labelled core specimens', () => {
    for (const entry of COMPONENT_COVERAGE.filter(({ source }) => source === 'components/headers/primitives.tsx')) {
      expect(entry).toMatchObject({ kind: 'specimen', href: '/design-system#core-examples' })
    }
  })

  it('records reviewed route states instead of filename-inferred fallbacks', () => {
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'components/CurrencySetting.tsx#CurrencySetting')).toMatchObject({
      kind: 'route', href: '/settings', state: expect.stringMatching(/currency/i),
    })
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'components/AgentIdentityTab.tsx#AgentIdentityTab')).toMatchObject({
      kind: 'route', href: '/agents/demo-agent', state: expect.stringMatching(/identity tab/i),
    })
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'components/admin/EditUserModal.tsx#EditUserModal')).toMatchObject({
      kind: 'route', href: '/admin/users', state: expect.stringMatching(/edit/i),
    })
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'components/demos/RevocationPanel.tsx#RevocationPanel')).toMatchObject({
      kind: 'route', href: '/demos/agentmaxxing', state: expect.stringMatching(/revocation/i),
    })
  })

  it('keeps same-name page symbols separate by exact source identity', () => {
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'pages/UsersPage.tsx#UsersPage')).toMatchObject({ href: '/users' })
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'pages/admin/UsersPage.tsx#UsersPage')).toMatchObject({ href: '/admin/users' })
  })

  it('registers CSS lab and wildcard behavior truthfully', () => {
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'pages/DesignSystemCssLabPage.tsx#DesignSystemCssLabPage')).toMatchObject({
      kind: 'route', href: '/design-system/css',
    })
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'pages/NotFoundPage.tsx#NotFoundPage')).toMatchObject({
      kind: 'specimen', href: '/design-system#error-pages',
    })
  })


  it('registers safe contextual fixtures without counting fixture helpers as shared', () => {
    for (const key of [
      'components/signals/WindowSelector.tsx#WindowSelector',
      'components/signals/FindingsList.tsx#FindingsList',
      'components/signals/SourceTable.tsx#SourceTable',
      'components/signals/presentation.tsx#LabelChips',
      'pages/admin/UserTable.tsx#RoleBadge',
      'pages/admin/UserTable.tsx#StatusIndicator',
      'pages/CollusionAccessPage.tsx#SubjectAgentLink',
      'pages/CollusionAccessPage.tsx#GroupMembersLink',
      'pages/CollusionAccessPage.tsx#CollaboratorGainsLinks',
    ]) {
      expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === key), key).toMatchObject({ kind: 'specimen', href: '/design-system#context-examples' })
    }
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'pages/design-system/ContextSpecimens.tsx#ContextSpecimens')).toMatchObject({
      kind: 'specimen', scope: 'fixture',
    })
  })

  it('uses exact symbols rather than broad subtree exclusions', () => {
    for (const entry of COMPONENT_COVERAGE) {
      expect(entry.symbol).not.toMatch(/subtree|\/$|\*/i)
      expect(entry.source).toMatch(/\.tsx$/)
    }
  })

  it('classifies supplied fixtures as specimens without promoting same-name page locals', () => {
    for (const symbol of [...CORE_SPECIMEN_NAMES, ...EXTRA_SPECIMEN_NAMES, ...WORKFLOW_SPECIMEN_NAMES]) {
      expect(COMPONENT_COVERAGE.some((entry) => entry.symbol === symbol && entry.kind === 'specimen')).toBe(true)
    }
    expect(COMPONENT_COVERAGE.find((entry) => coverageKey(entry) === 'pages/CredentialInventoryPage.tsx#ToolbarSearch')).toMatchObject({ kind: 'route' })
  })
})
