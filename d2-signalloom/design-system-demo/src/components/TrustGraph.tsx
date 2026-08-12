import { memo, useCallback, useState } from 'react'
import {
  Background, BackgroundVariant, Controls, Handle, Position, type Node, type NodeProps,
  ReactFlow, ReactFlowProvider, useReactFlow,
} from '@xyflow/react'
import '@xyflow/react/dist/style.css'
import { Crosshair, LocateFixed, Minus, Plus, RotateCcw } from 'lucide-react'
import { graphEdges, graphNodes } from '../data/fixtures'
import { Link } from 'react-router-dom'
import { Badge } from './ui'

type LoomData = { label: string; kind: string; status: string; tone: string; description: string }

const LoomNode = memo(function LoomNode({ data, selected }: NodeProps<Node<LoomData>>) {
  return (
    <div className={`loom-node loom-node--${data.tone} ${selected ? 'loom-node--selected' : ''}`}>
      <Handle type="target" position={Position.Left} className="loom-node__handle" />
      <span className="loom-node__kind">{data.kind}</span>
      <strong>{data.label}</strong>
      <span className="loom-node__status"><i aria-hidden="true" />{data.status}</span>
      <Handle type="source" position={Position.Right} className="loom-node__handle" />
    </div>
  )
})

const nodeTypes = { loom: LoomNode }

function GraphToolbar({ onReset }: { onReset: () => void }) {
  const { zoomIn, zoomOut, fitView } = useReactFlow()
  return (
    <div className="graph-toolbar" aria-label="Map controls">
      <button onClick={() => void zoomIn()} aria-label="Zoom in" data-testid="zoom-in"><Plus size={16} /></button>
      <button onClick={() => void zoomOut()} aria-label="Zoom out" data-testid="zoom-out"><Minus size={16} /></button>
      <button onClick={() => void fitView({ padding: 0.15 })} aria-label="Fit graph"><LocateFixed size={16} /></button>
      <button onClick={() => { void fitView({ padding: 0.15 }); onReset() }} aria-label="Reset graph view" data-testid="graph-reset"><RotateCcw size={16} /></button>
    </div>
  )
}

function Canvas({ selectedId, onSelect }: { selectedId: string; onSelect: (id: string) => void }) {
  return (
    <div className="graph-canvas" data-testid="trust-graph">
      <ReactFlow
        nodes={graphNodes.map((node) => ({ ...node, selected: node.id === selectedId })) as Node<LoomData>[]}
        edges={graphEdges}
        nodeTypes={nodeTypes}
        fitView
        fitViewOptions={{ padding: 0.16 }}
        minZoom={0.45}
        maxZoom={2.2}
        nodesDraggable={false}
        nodesConnectable={false}
        panOnDrag
        panOnScroll
        zoomOnScroll
        zoomOnPinch
        zoomOnDoubleClick={false}
        proOptions={{ hideAttribution: true }}
        onNodeClick={(_, node) => onSelect(node.id)}
        onPaneClick={() => onSelect('')}
      >
        <Background variant={BackgroundVariant.Dots} gap={24} size={1} color="var(--graph-grid)" />
        <Controls showInteractive={false} style={{ display: 'none' }} />
        <GraphToolbar onReset={() => onSelect('')} />
      </ReactFlow>
    </div>
  )
}

export function TrustGraph() {
  const [selectedId, setSelectedId] = useState('cardvault')
  const selected = graphNodes.find((node) => node.id === selectedId) ?? graphNodes[0]
  const select = useCallback((id: string) => setSelectedId(id), [])

  return (
    <div className="graph-layout">
      <div className="graph-main">
        <div className="graph-summary">
          <div><Crosshair size={16} aria-hidden="true" /><span><strong>One credential path is blocked.</strong> CardVault cannot reach Payments API until its lease is rotated.</span></div>
          <Badge tone="attention">Observed + modeled</Badge>
        </div>
        <ReactFlowProvider><Canvas selectedId={selectedId} onSelect={select} /></ReactFlowProvider>
        <div className="graph-legend" aria-label="Map legend">
          <span><i className="legend-dot legend-dot--healthy" />Active trust</span>
          <span><i className="legend-line legend-line--blocked" />Blocked credential</span>
          <span><i className="legend-line legend-line--modeled" />Modeled relationship</span>
        </div>
      </div>
      <aside className="graph-inspector" aria-live="polite">
        <span className="eyebrow">Selected {selected.data.kind}</span>
        <h2>{selected.data.label}</h2>
        <Badge tone={selected.data.tone}>{selected.data.status}</Badge>
        <p>{selected.data.description}</p>
        <dl>
          <div><dt>Source</dt><dd>{selected.data.kind === 'Evidence' ? 'Audit exporter' : 'Demo estate'}</dd></div>
          <div><dt>Freshness</dt><dd>Observed 2 minutes ago</dd></div>
          <div><dt>Confidence</dt><dd>High</dd></div>
        </dl>
        <Link className="button button--primary" to="/audit">Trace related evidence</Link>
      </aside>
      <div className="graph-outline">
        <h3>Topology narrative</h3>
        <p>Keyboard-accessible alternative to the visual map. Choose an entity to inspect it.</p>
        <div className="outline-list">
          {graphNodes.map((node) => <button key={node.id} onClick={() => select(node.id)} onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); select(node.id) } }} aria-pressed={selectedId === node.id}><span>{node.data.label}</span><small>{node.data.kind} · {node.data.status}</small></button>)}
        </div>
      </div>
    </div>
  )
}
