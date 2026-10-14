import { Link } from 'react-router-dom'
import { CopyableCodeBlock, DocLinkCard } from '../components/help/HelpCardComponents'

const KERNEL_DAEMONSET_YAML = `apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: stun-sentinel
  namespace: signalloom-system
  labels:
    app.kubernetes.io/name: stun-sentinel
    app.kubernetes.io/part-of: signal-loom
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: stun-sentinel
  template:
    metadata:
      labels:
        app.kubernetes.io/name: stun-sentinel
    spec:
      hostPID: true
      hostNetwork: true
      containers:
        - name: sentinel
          image: ghcr.io/signalloom/stun-sentinel:latest
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
            capabilities:
              add:
                - SYS_ADMIN
                - BPF
                - PERFMON
          env:
            - name: SIGNAL_LOOM_INGEST_URL
              value: "http://signalloom-ingest.signalloom-system.svc.cluster.local:8080"
            - name: COLLECTOR_EBPF_ENDPOINT_MODE
              value: "live-seam"
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: bpf-fs
              mountPath: /sys/fs/bpf
              mountPropagation: Bidirectional
            - name: cgroup-fs
              mountPath: /sys/fs/cgroup
              readOnly: false
            - name: debug-fs
              mountPath: /sys/kernel/debug
              readOnly: true
      volumes:
        - name: bpf-fs
          hostPath:
            path: /sys/fs/bpf
        - name: cgroup-fs
          hostPath:
            path: /sys/fs/cgroup
        - name: debug-fs
          hostPath:
            path: /sys/kernel/debug`

const HELM_SNIPPET = `# Add the official Signal Loom helm repository
helm repo add signalloom https://charts.signalloom.ai
helm repo update

# Install or upgrade the Kernel Sensor DaemonSet
helm upgrade --install kernel-sensor signalloom/kernel-sensor \\
  --namespace signalloom-system \\
  --create-namespace \\
  --set ingest.url="http://signalloom-ingest.signalloom-system.svc.cluster.local:8080" \\
  --set ebpf.mode="live-seam"`

const KUSTOMIZE_SNIPPET = `apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - https://github.com/osramp/sl-platform//d2-signalloom/infra/sensor?ref=main

patches:
  - target:
      kind: DaemonSet
      name: stun-sentinel
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/env/0/value
        value: "http://signalloom-ingest.signalloom-system.svc.cluster.local:8080"`

const SYSTEMD_UNIT = `# /etc/systemd/system/agentmaxxing-host-sensor.service
[Unit]
Description=Signal Loom AgentMaxxing Detective Host Sensor
After=network.target

[Service]
Type=simple
User=root
Environment=SIGNAL_LOOM_INGEST_URL=https://ingest.signalloom.internal
Environment=SIGNAL_LOOM_API_KEY=sl_sensor_live_secret_key
Environment=KANBAN_HOME=/var/run/kanban
ExecStart=/usr/local/bin/agentmaxxing-host-sensor --interval=2
Restart=always
RestartSec=5
ProtectSystem=strict
ProtectHome=read-only
ReadOnlyPaths=/proc /sys/fs/cgroup

[Install]
WantedBy=multi-user.target`

const SYSTEMD_COMMANDS = `# Reload systemd to detect the new service
sudo systemctl daemon-reload

# Enable and start the detective host sensor
sudo systemctl enable --now agentmaxxing-host-sensor

# Verify active status and telemetry heartbeat
sudo systemctl status agentmaxxing-host-sensor`

const DOCKER_COMMAND = `docker run -d \\
  --name agentmaxxing-host-sensor \\
  --restart unless-stopped \\
  --pid host \\
  --net host \\
  -v /proc:/proc:ro \\
  -v /sys/fs/cgroup:/sys/fs/cgroup:ro \\
  -e SIGNAL_LOOM_INGEST_URL="https://ingest.signalloom.internal" \\
  -e SIGNAL_LOOM_API_KEY="sl_sensor_live_secret_key" \\
  ghcr.io/signalloom/agentmaxxing-host-sensor:latest`

export default function DeploySensorHelpPage() {
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
          to="/settings/help/onboard-agent"
          className="btn btn-secondary"
          style={{ textDecoration: 'none', fontSize: 12, padding: '4px 10px' }}
        >
          Next: Onboard an Agent →
        </Link>
      </div>

      {/* Header */}
      <div style={{ marginBottom: 28 }}>
        <span className="kicker" style={{ color: 'var(--cyan)', textTransform: 'uppercase', letterSpacing: '0.08em', fontSize: 11, fontWeight: 700 }}>
          Telemetry Ingestion & Runtime Defense
        </span>
        <h1 className="display" style={{ fontSize: 28, fontWeight: 700, margin: '6px 0 10px', color: 'var(--text)' }}>
          Help to Deploy Sensor
        </h1>
        <p style={{ fontSize: 14, lineHeight: 1.6, color: 'var(--muted)', margin: 0, maxWidth: 820 }}>
          Signal Loom relies on two complementary sensor layers to achieve zero-blindspot observability and Tier-0 runtime
          containment without intercepting customer prompt payloads or breaking developer velocity.
        </p>
      </div>

      {/* Architecture Overview */}
      <div className="card" style={{ padding: '24px 28px', marginBottom: 24 }} data-testid="architecture-section">
        <h2 className="kicker" style={{ color: 'var(--cyan)', fontSize: 13, marginBottom: 12 }}>
          Architectural Overview: Telemetry Ingestion Pipeline
        </h2>
        <p style={{ fontSize: 13.5, lineHeight: 1.65, color: 'var(--text)', marginBottom: 16 }}>
          Telemetry flows from distributed nodes into Signal Loom’s centralized Policy Engine and Signal Fusion service.
          The detective pipeline operates under a strict <strong>Zero-Customer-Payload</strong> privacy invariant:
          prompts and credentials never cross the boundary; only cryptographic digests, numeric counters, and kernel events are ingested.
        </p>

        {/* 5-Plane Telemetry Flow Grid */}
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 12, marginBottom: 16 }}>
          <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 8, border: '1px solid var(--border)' }}>
            <span style={{ fontSize: 10, fontWeight: 700, color: 'var(--cyan)', textTransform: 'uppercase' }}>1. Kernel Sensor</span>
            <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', margin: '4px 0' }}>eBPF & Tetragon</div>
            <div style={{ fontSize: 11.5, color: 'var(--muted)', lineHeight: 1.4 }}>
              Captures in-kernel execve, openat, and socket events. Enforces cgroup freezing on stun.
            </div>
          </div>

          <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 8, border: '1px solid var(--border)' }}>
            <span style={{ fontSize: 10, fontWeight: 700, color: 'var(--teal)', textTransform: 'uppercase' }}>2. Host Sensor</span>
            <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', margin: '4px 0' }}>AgentMaxxing Sensor</div>
            <div style={{ fontSize: 11.5, color: 'var(--muted)', lineHeight: 1.4 }}>
              Passive procfs and netlink sock_diag detector identifying autonomous coding harnesses.
            </div>
          </div>

          <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 8, border: '1px solid var(--border)' }}>
            <span style={{ fontSize: 10, fontWeight: 700, color: 'var(--violet)', textTransform: 'uppercase' }}>3. Ingestion Gateway</span>
            <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', margin: '4px 0' }}>Go Signal Gateway</div>
            <div style={{ fontSize: 11.5, color: 'var(--muted)', lineHeight: 1.4 }}>
              Validates codingagent.v1 wire contracts, HMAC-SHA256 deduplication, and rate limiting.
            </div>
          </div>

          <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 8, border: '1px solid var(--border)' }}>
            <span style={{ fontSize: 10, fontWeight: 700, color: 'var(--amber)', textTransform: 'uppercase' }}>4. Policy & Fusion</span>
            <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', margin: '4px 0' }}>CEL Engine & Stun</div>
            <div style={{ fontSize: 11.5, color: 'var(--muted)', lineHeight: 1.4 }}>
              Evaluates findings across all 5 streams, correlates attack chains, and dispatches stuns.
            </div>
          </div>

          <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 8, border: '1px solid var(--border)' }}>
            <span style={{ fontSize: 10, fontWeight: 700, color: 'var(--text)', textTransform: 'uppercase' }}>5. Presentation</span>
            <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', margin: '4px 0' }}>Dashboard & API</div>
            <div style={{ fontSize: 11.5, color: 'var(--muted)', lineHeight: 1.4 }}>
              Visualizes real-time Weave activity, Trust Topology, and FAIR Risk exposures.
            </div>
          </div>
        </div>
      </div>

      {/* Sensor 1: Kernel Sensor */}
      <div className="card" style={{ padding: '24px 28px', marginBottom: 24 }} data-testid="kernel-sensor-section">
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
          <span style={{ background: 'var(--cyan)', color: 'var(--on-accent)', borderRadius: 4, padding: '2px 8px', fontSize: 11, fontWeight: 700 }}>
            LAYER 1
          </span>
          <h2 className="display" style={{ fontSize: 20, fontWeight: 700, margin: 0 }}>
            Kernel Sensor: eBPF & Tetragon / Sentinel
          </h2>
        </div>
        <p style={{ fontSize: 13.5, lineHeight: 1.65, color: 'var(--text)', marginBottom: 16 }}>
          The Kernel Sensor runs as a Kubernetes <code>DaemonSet</code> on cluster worker nodes. It probes in-kernel tracepoints
          (such as <code>sys_enter_execve</code>, <code>sys_enter_openat</code>, and socket calls) to detect unauthorized child processes,
          credential file accesses, and abnormal socket connections. When a policy violation triggers a containment event,
          the sentinel executes <strong>Tier-0 in-kernel cgroup freezing</strong> (<code>cgroup.freeze = 1</code> in sub-20ms).
        </p>

        <h3 className="label" style={{ color: 'var(--text)', fontSize: 13, marginBottom: 8 }}>
          Option A: Direct Manifest Apply (kubectl)
        </h3>
        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 8 }}>
          Apply the standard privileged DaemonSet into your cluster:
        </p>
        <CopyableCodeBlock
          code="kubectl apply -f https://deploy.signalloom.ai/kernel-sensor/daemonset.yaml"
          language="bash"
          title="Quick Install CLI"
          testId="kernel-cli-snippet"
        />

        <details style={{ marginBottom: 16 }}>
          <summary style={{ cursor: 'pointer', fontSize: 12.5, fontWeight: 600, color: 'var(--cyan)', marginBottom: 8 }}>
            View Full DaemonSet Manifest YAML
          </summary>
          <CopyableCodeBlock
            code={KERNEL_DAEMONSET_YAML}
            language="yaml"
            title="kernel-sensor-daemonset.yaml"
            testId="kernel-yaml-snippet"
          />
        </details>

        <h3 className="label" style={{ color: 'var(--text)', fontSize: 13, marginBottom: 8 }}>
          Option B: Helm Chart Installation
        </h3>
        <CopyableCodeBlock
          code={HELM_SNIPPET}
          language="bash"
          title="Helm Commands"
          testId="kernel-helm-snippet"
        />

        <h3 className="label" style={{ color: 'var(--text)', fontSize: 13, marginBottom: 8 }}>
          Option C: GitOps & Kustomize
        </h3>
        <CopyableCodeBlock
          code={KUSTOMIZE_SNIPPET}
          language="yaml"
          title="kustomization.yaml snippet"
          testId="kernel-kustomize-snippet"
        />
      </div>

      {/* Sensor 2: Host Sensor */}
      <div className="card" style={{ padding: '24px 28px', marginBottom: 24 }} data-testid="host-sensor-section">
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
          <span style={{ background: 'var(--teal)', color: 'var(--on-accent)', borderRadius: 4, padding: '2px 8px', fontSize: 11, fontWeight: 700 }}>
            LAYER 2
          </span>
          <h2 className="display" style={{ fontSize: 20, fontWeight: 700, margin: 0 }}>
            Host Sensor: AgentMaxxing Detective Daemon
          </h2>
        </div>
        <p style={{ fontSize: 13.5, lineHeight: 1.65, color: 'var(--text)', marginBottom: 16 }}>
          The host sensor (<code>agentmaxxing-host-sensor</code>) monitors autonomous coding agent harnesses running on developer machines,
          CI runners, and execution hosts. It passively scans <code>/proc/&lt;pid&gt;/stat</code>, tracks Kanban session states,
          extracts transcript counters, and maps outbound socket inodes via Netlink <code>SOCK_DIAG</code> without ever reading process memory or command arguments.
        </p>

        <h3 className="label" style={{ color: 'var(--text)', fontSize: 13, marginBottom: 8 }}>
          Option A: Linux Systemd Service (Workstations & Build Hosts)
        </h3>
        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 8 }}>
          Create <code>/etc/systemd/system/agentmaxxing-host-sensor.service</code> with your ingest endpoint:
        </p>
        <CopyableCodeBlock
          code={SYSTEMD_UNIT}
          language="ini"
          title="Systemd Unit Configuration"
          testId="host-systemd-unit-snippet"
        />
        <CopyableCodeBlock
          code={SYSTEMD_COMMANDS}
          language="bash"
          title="Service Activation Commands"
          testId="host-systemd-cmds-snippet"
        />

        <h3 className="label" style={{ color: 'var(--text)', fontSize: 13, marginBottom: 8 }}>
          Option B: Standalone Containerized Host Sensor (Docker / Podman)
        </h3>
        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 8 }}>
          Run the container with host PID and network namespace access to observe coding agents:
        </p>
        <CopyableCodeBlock
          code={DOCKER_COMMAND}
          language="bash"
          title="Docker Run CLI"
          testId="host-docker-snippet"
        />
      </div>

      {/* Troubleshooting Tips */}
      <div className="card" style={{ padding: '24px 28px', marginBottom: 24 }} data-testid="troubleshooting-section">
        <h2 className="kicker" style={{ color: 'var(--amber)', fontSize: 13, marginBottom: 12 }}>
          Troubleshooting Common Sensor Issues
        </h2>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <div style={{ padding: '14px 16px', background: 'var(--surface2)', borderRadius: 8, borderLeft: '3px solid var(--amber)' }}>
            <div style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>
              1. Cgroups v2 Unified Hierarchy Missing or Hybrid Mode
            </div>
            <p style={{ fontSize: 12.5, color: 'var(--muted)', margin: '0 0 8px', lineHeight: 1.5 }}>
              Kernel sensors require unified cgroups v2 hierarchy for instantaneous cgroup freezing (<code>cgroup.freeze</code>).
            </p>
            <div style={{ fontSize: 12, fontFamily: 'monospace', color: 'var(--cyan)' }}>
              Diagnosis: mount | grep cgroup2<br />
              Fix: Add <code>systemd.unified_cgroup_hierarchy=1</code> to kernel boot parameters in <code>/etc/default/grub</code> and reboot.
            </div>
          </div>

          <div style={{ padding: '14px 16px', background: 'var(--surface2)', borderRadius: 8, borderLeft: '3px solid var(--error)' }}>
            <div style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>
              2. BPF Permissions & Capability Dropping (Operation Not Permitted)
            </div>
            <p style={{ fontSize: 12.5, color: 'var(--muted)', margin: '0 0 8px', lineHeight: 1.5 }}>
              The eBPF probe requires elevated permissions to attach to kernel tracepoints and load BPF bytecode.
            </p>
            <div style={{ fontSize: 12, fontFamily: 'monospace', color: 'var(--cyan)' }}>
              Diagnosis: kubectl logs -n signalloom-system daemonset/stun-sentinel | grep -i bpf<br />
              Fix: Ensure Pod spec has <code>securityContext.privileged: true</code> and capabilities <code>BPF</code>, <code>PERFMON</code>, <code>SYS_ADMIN</code>.
            </div>
          </div>

          <div style={{ padding: '14px 16px', background: 'var(--surface2)', borderRadius: 8, borderLeft: '3px solid var(--teal)' }}>
            <div style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>
              3. Kernel Headers & BTF (BPF Type Format) Verification
            </div>
            <p style={{ fontSize: 12.5, color: 'var(--muted)', margin: '0 0 8px', lineHeight: 1.5 }}>
              CO-RE (Compile Once - Run Everywhere) relies on <code>/sys/kernel/btf/vmlinux</code>. Older kernels (&lt;5.15) require kernel headers.
            </p>
            <div style={{ fontSize: 12, fontFamily: 'monospace', color: 'var(--cyan)' }}>
              Diagnosis: test -f /sys/kernel/btf/vmlinux &amp;&amp; echo "BTF OK" || echo "BTF Missing"<br />
              Fix: Upgrade to Linux kernel &gt;= 5.15, or run <code>sudo apt-get install linux-headers-$(uname -r)</code>.
            </div>
          </div>

          <div style={{ padding: '14px 16px', background: 'var(--surface2)', borderRadius: 8, borderLeft: '3px solid var(--violet)' }}>
            <div style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>
              4. Netlink Socket Diag Access (CONFIG_INET_DIAG)
            </div>
            <p style={{ fontSize: 12.5, color: 'var(--muted)', margin: '0 0 8px', lineHeight: 1.5 }}>
              Host sensors read active socket inodes to map process cgroups to external inference provider IPs.
            </p>
            <div style={{ fontSize: 12, fontFamily: 'monospace', color: 'var(--cyan)' }}>
              Diagnosis: grep CONFIG_INET_DIAG /boot/config-$(uname -r)<br />
              Fix: Ensure kernel module <code>inet_diag</code> is loaded (<code>sudo modprobe inet_diag</code>).
            </div>
          </div>
        </div>
      </div>

      {/* Documentation Links */}
      <div className="card" style={{ padding: '24px 28px', marginBottom: 24 }} data-testid="doc-links-section">
        <h2 className="kicker" style={{ color: 'var(--cyan)', fontSize: 13, marginBottom: 14 }}>
          Related Documentation & Guides
        </h2>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))', gap: 14 }}>
          <DocLinkCard
            title="Detective Telemetry Architecture"
            description="End-to-end passive observability pipeline for autonomous coding agents across host sensor discovery, Go ingestion, and Weave visualization."
            href="/docs/security/detective-telemetry-architecture/"
            badge="Architecture"
            testId="doc-link-detective-telemetry"
          />
          <DocLinkCard
            title="Detection Coverage & CEL Rules"
            description="How observations from kernel sensors and host collectors are evaluated against versioned CEL policy bundles and attack correlation engines."
            href="/docs/operate/detection-coverage/"
            badge="Operations"
            testId="doc-link-detection-coverage"
          />
          <DocLinkCard
            title="Agent Containment & Response Runbook"
            description="Operational runbook for multi-plane response: cgroup freeze, Cilium mesh isolation, OpenBao token revocation, and SPIRE entry removal."
            href="/docs/operate/containment-runbook/"
            badge="Runbook"
            testId="doc-link-containment-runbook"
          />
        </div>
      </div>
    </div>
  )
}
