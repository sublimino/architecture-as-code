# Signal Loom D2: Isometric System Map

Interactive isometric visualisation of the Signal Loom D2 platform architecture.
Each building's shape communicates its infrastructure role; coloured paths trace
real control, data, identity, and GitOps flows between services.

## Viewing

Serve the directory and open it in a browser:

```bash
# from repo root
python3 -m http.server 8901 --bind 0.0.0.0 -d docs/system-map
# then open http://localhost:8901
```

Or with any static file server:

```bash
npx serve docs/system-map -p 8901
bunx serve docs/system-map -p 8901
```

Drag to pan, scroll to zoom, hover any building for service details (port,
namespace, source file path). Toggle paths and labels with the bottom-right
controls.

## Building shapes

| Shape | Visual | Represents |
|-------|--------|------------|
| Gateway Arch | Two pillars + beam, animated traffic arrows | Ingress (Envoy) |
| Tower | Tall narrow block, rooftop spire | Core vertical services |
| Compound | Base block + setback upper tower | Multi-layer services (API, orchestrator) |
| Warehouse | Low block with pitched roof, loading bays | Pipeline/batch (Policy Engine, OSRamp ingest) |
| Fortress | Crenellated walls, corner turrets | Security-critical (OpenBao, SPIRE, CardVault) |
| Silo | Cylinder with banding, pipe connector | Data stores (PostgreSQL, Zot) |
| Antenna Mast | Tapered tower, satellite dish, signal rings | Observability (Prometheus, Trivy) |
| Dome | Block base + geodesic lattice dome | AI/LLM inference (CPAI, LLM Guard, Sentinel) |
| Platform | Low slab with grid + server racks | Infrastructure base (Kind cluster) |

## Data path colours

| Colour | Type |
|--------|------|
| Cyan | Control flow (request/response) |
| Teal | Data flow (storage, metrics) |
| Violet | Identity / auth (OIDC, SPIFFE, cosign) |
| Amber (dashed) | GitOps reconciliation (Flux) |

## Updating the map

The map is a single self-contained HTML file (`index.html`) with no external
dependencies. All rendering is done via Canvas API with inline JavaScript.

### When to update

Update the map when:
- A new service is added or removed from the platform
- A service changes port, namespace, or deployment topology
- A new data/control path is introduced between services
- The Flux fleet structure changes (new cluster, new tenant)

### How to update

The map data lives in two arrays near the top of the `<script>` block:

**`BUILDINGS`**: one entry per service:
```js
{ id: 'service-id',          // unique identifier
  col: 9, row: 3,            // grid position (spread out for readability)
  w: 2, d: 1.5,              // footprint in tiles (width x depth)
  h: 4.0,                    // height (encodes complexity)
  shape: 'compound',         // one of: tower, warehouse, compound, silo,
                              //         fortress, antenna, dome, gate, platform
  zone: 'app',               // zone key (see ZONES object for colours)
  name: 'Service Name',
  port: '8000',              // ClusterIP port or '-'
  ns: 'namespace',           // Kubernetes namespace
  role: 'One-line description of what this service does.',
  file: 'd2-signalloom/apps/service/' }  // source path from repo root
```

**`CONNECTIONS`**: one entry per data/control path:
```js
{ from: 'source-id', to: 'target-id',
  type: 'control',           // control | data | identity | gitops
  label: 'short label' }
```

**`ZONE_PLATES`**: coloured ground regions grouping related services:
```js
{ c: 3, r: 2, w: 13, d: 8, color: '#8B5CF6', label: 'APPLICATION LAYER' }
```

### Shape selection guide

Choose the shape that communicates the service's architectural role:

- **gateway**: entry points, load balancers, ingress controllers
- **tower**: stateless request-serving services, APIs, UIs
- **compound**: services with multiple internal layers (API + workers)
- **warehouse**: batch processing, pipeline stages, policy evaluation
- **fortress**: anything holding secrets, keys, or identity material
- **silo**: databases, registries, persistent stores
- **antenna**: monitoring, scanning, observability collectors
- **dome**: AI/ML inference, LLM runtimes
- **platform**: infrastructure foundations, cluster hosts

### Positioning tips

- Spread buildings 2-3 tiles apart for readability
- Group related services within the same zone plate
- Place upstream services higher (lower row number) than downstream
- Keep connection paths short where possible: long diagonal paths are hard to read
- Update `ZONE_PLATES` boundaries when adding services outside existing zones

### Verification

After editing, serve locally and check:
1. All buildings render without overlap
2. Hover tooltips show correct metadata
3. Connection paths trace logical routes
4. Zone plates encompass their services
5. No console errors in browser DevTools

## File inventory

```
docs/system-map/
├── README.md      ← this file
└── index.html     ← the interactive map (self-contained, ~47KB)
```
