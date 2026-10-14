import { Link } from 'react-router-dom'
import { CopyableCodeBlock, DocLinkCard } from '../components/help/HelpCardComponents'

const WORKLOAD_DEPLOYMENT_YAML = `apiVersion: apps/v1
kind: Deployment
metadata:
  name: agent-customer-support
  namespace: fe-signalloom-agents
  labels:
    app.kubernetes.io/name: agent-customer-support
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: agent-customer-support
  template:
    metadata:
      labels:
        app.kubernetes.io/name: agent-customer-support
        # Mandatory discovery label:
        signalloom.ai/agent: "true"
        # Framework classification:
        signalloom.ai/framework: "custom"
        # LLM foundation model:
        signalloom.ai/model: "claude-sonnet-4"
        # Tenant boundary isolation:
        signalloom.ai/tenant: "tenant-default"
        # Security profile (nono-evidenced or standard-baseline):
        signalloom.io/workload-profile: "nono-evidenced"
      annotations:
        # Operator accountability:
        signalloom.ai/owner: "security-team@example.com"
        # Monthly token consumption ceiling:
        signalloom.ai/token-budget: "1000000"
    spec:
      serviceAccountName: agent-customer-support
      containers:
        - name: agent
          image: ghcr.io/myorg/support-agent:v1.2.0
          env:
            - name: SPIFFE_ENDPOINT_SOCKET
              value: "unix:///spiffe-workload-api/agent.sock"
          resources:
            limits:
              cpu: "2"
              memory: "4Gi"
            requests:
              cpu: "500m"
              memory: "1Gi"`

const SPIRE_REGISTRATION_CLI = `# Register the agent workload with SPIRE server to mint a cryptographic SPIFFE SVID
spire-server entry create \\
  -spiffeID "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-customer-support" \\
  -parentID "spiffe://signalloom.demo/spire/server" \\
  -selector "k8s:ns:fe-signalloom-agents" \\
  -selector "k8s:sa:agent-customer-support" \\
  -ttl 3600`

const OPENBAO_POLICY_HCL = `# Write secret access policy for the agent
bao policy write agent-customer-support - <<EOF
path "secret/data/agents/agent-customer-support/*" {
  capabilities = ["read", "list"]
}
EOF`

const OPENBAO_JWT_ROLE = `# Bind the SPIFFE SVID claim to OpenBao JWT authentication role
bao write auth/jwt/role/agent-customer-support \\
  role_type="jwt" \\
  bound_audiences="openbao.signalloom.internal" \\
  user_claim="sub" \\
  bound_subject="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-customer-support" \\
  token_policies="agent-customer-support" \\
  token_ttl="1h"`

const API_CLAIM_BY_ID_CURL = `# Claim a discovered agent by ID via REST API
curl -sS -X POST "https://dashboard.signalloom.internal/api/v1/agents/agent-customer-support/claim" \\
  -H "Authorization: Bearer \${SIGNAL_LOOM_TOKEN}" \\
  -H "Content-Type: application/json" \\
  -d '{
    "token_budget": 1000000,
    "framework": "custom",
    "model": "claude-sonnet-4",
    "notes": "Claimed via automated onboarding pipeline"
  }'`

const API_CLAIM_BY_POD_CURL = `# Claim a discovered agent by Pod Name and Namespace
curl -sS -X POST "https://dashboard.signalloom.internal/api/v1/agents/claim" \\
  -H "Authorization: Bearer \${SIGNAL_LOOM_TOKEN}" \\
  -H "Content-Type: application/json" \\
  -d '{
    "pod_name": "agent-customer-support-7df9f-xyz",
    "namespace": "fe-signalloom-agents"
  }'`

const API_MINT_TOKEN_CURL = `# Mint an enrollment token for external / out-of-cluster agents
curl -sS -X POST "https://dashboard.signalloom.internal/api/v1/agents/tokens" \\
  -H "Authorization: Bearer \${SIGNAL_LOOM_TOKEN}" \\
  -H "Content-Type: application/json" \\
  -d '{
    "agent_name": "external-worker-01",
    "expires_in_hours": 72
  }'`

export default function OnboardAgentHelpPage() {
  return (
    <div className="fade-in" style={{ maxWidth: 1040, margin: '0 auto' }}>
      {/* Navigation Breadcrumbs */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 20 }}>
        <div style={{ display: 'flex', gap: 14, alignItems: 'center' }}>
          <Link
            to="/settings"
            className="label"
            style={{ color: 'var(--muted)', textDecoration: 'none' }}
            data-testid="back-to-settings-link"
          >
            ← Back to Settings
          </Link>
          <span style={{ color: 'var(--border)' }}>/</span>
          <Link
            to="/agents"
            className="label"
            style={{ color: 'var(--muted)', textDecoration: 'none' }}
          >
            Agents
          </Link>
        </div>
        <Link
          to="/settings/help/deploy-sensor"
          className="btn btn-secondary"
          style={{ textDecoration: 'none', fontSize: 12, padding: '4px 10px' }}
        >
          ← Deploy Sensor Guide
        </Link>
      </div>

      {/* Header */}
      <div style={{ marginBottom: 28 }}>
        <span className="kicker" style={{ color: 'var(--cyan)', textTransform: 'uppercase', letterSpacing: '0.08em', fontSize: 11, fontWeight: 700 }}>
          Agent Governance & Attestation
        </span>
        <h1 className="display" style={{ fontSize: 28, fontWeight: 700, margin: '6px 0 10px', color: 'var(--text)' }}>
          Help to Onboard an Agent
        </h1>
        <p style={{ fontSize: 14, lineHeight: 1.6, color: 'var(--muted)', margin: 0, maxWidth: 820 }}>
          Follow this 3-step walkthrough to onboard AI agents into Signal Loom governance.
          Every onboarded workload receives a cryptographic SPIFFE identity, bounded OpenBao credential access,
          and tamper-evident telemetry tracking.
        </p>
      </div>

      {/* Step 1: Workload Manifest Labels & Annotations */}
      <div className="card" style={{ padding: '24px 28px', marginBottom: 24 }} data-testid="step-1-section">
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
          <span style={{ background: 'var(--cyan)', color: 'var(--on-accent)', borderRadius: 4, padding: '2px 8px', fontSize: 11, fontWeight: 700 }}>
            STEP 1
          </span>
          <h2 className="display" style={{ fontSize: 20, fontWeight: 700, margin: 0 }}>
            Workload Manifest Labels & Annotations
          </h2>
        </div>
        <p style={{ fontSize: 13.5, lineHeight: 1.65, color: 'var(--text)', marginBottom: 16 }}>
          Signal Loom discovers agents dynamically by inspecting Kubernetes workload metadata.
          To ensure accurate inventory classification and policy enforcement, annotate and label your Pod template:
        </p>

        {/* Labels & Annotations Table */}
        <div style={{ overflowX: 'auto', marginBottom: 18 }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}>
            <thead>
              <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
                <th style={{ textAlign: 'left', padding: '8px 12px', color: 'var(--muted)' }} className="label">Key</th>
                <th style={{ textAlign: 'left', padding: '8px 12px', color: 'var(--muted)' }} className="label">Required</th>
                <th style={{ textAlign: 'left', padding: '8px 12px', color: 'var(--muted)' }} className="label">Example Value</th>
                <th style={{ textAlign: 'left', padding: '8px 12px', color: 'var(--muted)' }} className="label">Description</th>
              </tr>
            </thead>
            <tbody>
              <tr style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={{ padding: '8px 12px' }}><code className="mono">signalloom.ai/agent</code></td>
                <td style={{ padding: '8px 12px', color: 'var(--cyan)', fontWeight: 600 }}>Required</td>
                <td style={{ padding: '8px 12px' }}><code className="mono">"true"</code></td>
                <td style={{ padding: '8px 12px', color: 'var(--muted)' }}>Flags the pod as an AI agent workload for automatic inventory discovery.</td>
              </tr>
              <tr style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={{ padding: '8px 12px' }}><code className="mono">signalloom.ai/framework</code></td>
                <td style={{ padding: '8px 12px', color: 'var(--muted)' }}>Recommended</td>
                <td style={{ padding: '8px 12px' }}><code className="mono">"custom" | "langchain" | "crewai"</code></td>
                <td style={{ padding: '8px 12px', color: 'var(--muted)' }}>Agent execution framework for runtime heuristic classification.</td>
              </tr>
              <tr style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={{ padding: '8px 12px' }}><code className="mono">signalloom.ai/model</code></td>
                <td style={{ padding: '8px 12px', color: 'var(--muted)' }}>Recommended</td>
                <td style={{ padding: '8px 12px' }}><code className="mono">"claude-sonnet-4" | "gpt-4o"</code></td>
                <td style={{ padding: '8px 12px', color: 'var(--muted)' }}>Model family used to validate outbound socket egress to inference providers.</td>
              </tr>
              <tr style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={{ padding: '8px 12px' }}><code className="mono">signalloom.ai/tenant</code></td>
                <td style={{ padding: '8px 12px', color: 'var(--cyan)', fontWeight: 600 }}>Required</td>
                <td style={{ padding: '8px 12px' }}><code className="mono">"tenant-default"</code></td>
                <td style={{ padding: '8px 12px', color: 'var(--muted)' }}>Tenant identifier to guarantee multi-tenant namespace isolation.</td>
              </tr>
              <tr style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={{ padding: '8px 12px' }}><code className="mono">signalloom.io/workload-profile</code></td>
                <td style={{ padding: '8px 12px', color: 'var(--muted)' }}>Recommended</td>
                <td style={{ padding: '8px 12px' }}><code className="mono">"nono-evidenced" | "standard-baseline"</code></td>
                <td style={{ padding: '8px 12px', color: 'var(--muted)' }}>Selects security badge and enables Landlock LSM confinement evidence.</td>
              </tr>
              <tr style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={{ padding: '8px 12px' }}><code className="mono">signalloom.ai/token-budget</code></td>
                <td style={{ padding: '8px 12px', color: 'var(--muted)' }}>Optional</td>
                <td style={{ padding: '8px 12px' }}><code className="mono">"1000000"</code></td>
                <td style={{ padding: '8px 12px', color: 'var(--muted)' }}>Annotation setting token threshold before raising alert findings.</td>
              </tr>
            </tbody>
          </table>
        </div>

        <h3 className="label" style={{ color: 'var(--text)', fontSize: 13, marginBottom: 8 }}>
          Sample Kubernetes Deployment Manifest
        </h3>
        <CopyableCodeBlock
          code={WORKLOAD_DEPLOYMENT_YAML}
          language="yaml"
          title="agent-deployment.yaml"
          testId="step1-yaml-snippet"
        />
      </div>

      {/* Step 2: SPIFFE ID registration & OpenBao access policy */}
      <div className="card" style={{ padding: '24px 28px', marginBottom: 24 }} data-testid="step-2-section">
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
          <span style={{ background: 'var(--teal)', color: 'var(--on-accent)', borderRadius: 4, padding: '2px 8px', fontSize: 11, fontWeight: 700 }}>
            STEP 2
          </span>
          <h2 className="display" style={{ fontSize: 20, fontWeight: 700, margin: 0 }}>
            SPIFFE ID Registration & OpenBao Access Policy
          </h2>
        </div>
        <p style={{ fontSize: 13.5, lineHeight: 1.65, color: 'var(--text)', marginBottom: 16 }}>
          Zero-trust agent governance mandates that every agent possesses an immutable cryptographic identity.
          Workloads obtain an x509 SVID from SPIRE and authenticate to OpenBao to retrieve leased secrets without long-lived static API tokens.
        </p>

        <h3 className="label" style={{ color: 'var(--text)', fontSize: 13, marginBottom: 8 }}>
          2.1 Register Workload in SPIRE Server
        </h3>
        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 8 }}>
          Workload entries bind the agent’s ServiceAccount and Namespace to its canonical SPIFFE ID:
        </p>
        <CopyableCodeBlock
          code={SPIRE_REGISTRATION_CLI}
          language="bash"
          title="SPIRE Entry Create CLI"
          testId="step2-spire-snippet"
        />

        <h3 className="label" style={{ color: 'var(--text)', fontSize: 13, marginBottom: 8 }}>
          2.2 Write OpenBao Vault Policy
        </h3>
        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 8 }}>
          Define least-privilege secret access rules scoped strictly to the agent’s path:
        </p>
        <CopyableCodeBlock
          code={OPENBAO_POLICY_HCL}
          language="bash"
          title="OpenBao Policy CLI"
          testId="step2-openbao-policy-snippet"
        />

        <h3 className="label" style={{ color: 'var(--text)', fontSize: 13, marginBottom: 8 }}>
          2.3 Map SPIFFE SVID to OpenBao JWT Role
        </h3>
        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 8 }}>
          Bind the SPIFFE subject to OpenBao’s JWT authentication engine:
        </p>
        <CopyableCodeBlock
          code={OPENBAO_JWT_ROLE}
          language="bash"
          title="OpenBao JWT Role CLI"
          testId="step2-openbao-role-snippet"
        />
      </div>

      {/* Step 3: Minting enrollment tokens & claiming discovered agents */}
      <div className="card" style={{ padding: '24px 28px', marginBottom: 24 }} data-testid="step-3-section">
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
          <span style={{ background: 'var(--violet)', color: 'var(--on-accent)', borderRadius: 4, padding: '2px 8px', fontSize: 11, fontWeight: 700 }}>
            STEP 3
          </span>
          <h2 className="display" style={{ fontSize: 20, fontWeight: 700, margin: 0 }}>
            Minting Enrollment Tokens & Claiming Discovered Agents
          </h2>
        </div>
        <p style={{ fontSize: 13.5, lineHeight: 1.65, color: 'var(--text)', marginBottom: 16 }}>
          Once deployed, workloads transition to the <strong>Discovered</strong> state in Signal Loom.
          A <em>Claim</em> permanently binds the workload to your tenant in PostgreSQL, preventing cross-tenant hijacking.
        </p>

        <div style={{ padding: '14px 18px', background: 'var(--surface2)', borderRadius: 8, marginBottom: 18 }}>
          <h3 className="label" style={{ color: 'var(--cyan)', fontSize: 13, marginTop: 0, marginBottom: 6 }}>
            Method A: Claim via Dashboard UI (Recommended)
          </h3>
          <ol style={{ fontSize: 13, color: 'var(--text)', lineHeight: 1.6, paddingLeft: 18, margin: 0 }}>
            <li>Open the <Link to="/agents" style={{ color: 'var(--cyan)' }}>Agents page</Link>.</li>
            <li>Locate the discovered agent row (e.g. <code>agent-customer-support</code>).</li>
            <li>Click the <strong>Claim</strong> button on the row or open the agent dossier.</li>
            <li>Verify the auto-populated SPIFFE ID, framework, and model parameters.</li>
            <li>Confirm the claim to assign ownership to your tenant.</li>
          </ol>
        </div>

        <h3 className="label" style={{ color: 'var(--text)', fontSize: 13, marginBottom: 8 }}>
          Method B: Claim via REST API (Scripted / CI/CD)
        </h3>
        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 8 }}>
          Claim an agent by ID directly using your tenant bearer token:
        </p>
        <CopyableCodeBlock
          code={API_CLAIM_BY_ID_CURL}
          language="bash"
          title="curl POST /api/v1/agents/{id}/claim"
          testId="step3-claim-id-snippet"
        />

        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 8 }}>
          Alternatively, claim by pod name and namespace if the agent ID is unknown:
        </p>
        <CopyableCodeBlock
          code={API_CLAIM_BY_POD_CURL}
          language="bash"
          title="curl POST /api/v1/agents/claim"
          testId="step3-claim-pod-snippet"
        />

        <h3 className="label" style={{ color: 'var(--text)', fontSize: 13, marginBottom: 8 }}>
          Method C: Minting Enrollment Tokens for External / Linux Agents
        </h3>
        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 8 }}>
          For out-of-cluster agents running on external Linux VMs, mint a short-lived enrollment token:
        </p>
        <CopyableCodeBlock
          code={API_MINT_TOKEN_CURL}
          language="bash"
          title="curl POST /api/v1/agents/tokens"
          testId="step3-mint-token-snippet"
        />
      </div>

      {/* Documentation Links */}
      <div className="card" style={{ padding: '24px 28px', marginBottom: 24 }} data-testid="doc-links-section">
        <h2 className="kicker" style={{ color: 'var(--cyan)', fontSize: 13, marginBottom: 14 }}>
          Related Documentation & Guides
        </h2>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))', gap: 14 }}>
          <DocLinkCard
            title="Onboard Your First Agent"
            description="Foundational walkthrough for registering an agent, verifying identity state, and inspecting inventory records."
            href="/docs/start/first-agent/"
            badge="Getting Started"
            testId="doc-link-first-agent"
          />
          <DocLinkCard
            title="Claim the Two Demonstration Agents"
            description="Claim agent-nono-evidenced and agent-standard-baseline side by side to compare Landlock LSM evidence against baseline containers."
            href="/docs/agents/dual-agent-onboarding/"
            badge="Walkthrough"
            testId="doc-link-dual-agent"
          />
          <DocLinkCard
            title="Signal Loom Quick Start Guide"
            description="High-level architectural overview from cluster bootstrap to live governance, policy evaluation, and audit logs."
            href="/docs/start/quick-start/"
            badge="Quick Start"
            testId="doc-link-quick-start"
          />
        </div>
      </div>
    </div>
  )
}
