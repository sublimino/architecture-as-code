# Calibration — `cis-kubernetes` v1.8.0

One derivation per priced check, keyed by check id. Grep a check id in this
directory and you get both its expression and its basis.

Read [the calibration statement](../../README.md#the-calibration-statement) and
then [ANCHORS.md](../../ANCHORS.md). Nothing here is a measurement. A derivation
records what the estimate was calibrated against and which part of it is
judgement.

## What the magnitude is a share of

A `riskTriple` here is the **attributable share of one loss event assigned to
one failed control**. The event-level figures are the `SCN-*` magnitudes in
[`risk/org/acme.yaml`](../../../../risk/org/acme.yaml). The implied share below
is this check's `riskTriple` mode divided by that scenario's mode.

| Scenario | Mode |
| :--- | ---: |
| `SCN-UNAUTH-CHANGE` | £60,000 |
| `SCN-SECRET-EXFIL` | £180,000 |
| `SCN-INJECTION-ACT` | £110,000 |
| `SCN-SUPPLY-TAMPER` | £250,000 |
| `SCN-TRUST-SUBVERT` | £500,000 |

## The frequency decomposition

`LEF = P_org × S_path × C_check`. See
[ANCHORS.md](../../ANCHORS.md#the-frequency-decomposition).

### `P_org`, shared by every check in this pack

The organisation-year base rate of any cyber loss event. Anchor
`AC-LEF-ORG-BASE`, confidence **B**. It is a property of the institution rather
than of the pack. It is stated once here and belongs in
[`risk/org/acme.yaml`](../../../../risk/org/acme.yaml) once that file carries a
revenue band. The IRIS evidence is relative, not absolute. It supports the
scaling with size and supports nothing about Acme's own rate.

### `S_path`, shared by control family

| Family | `S_path` basis | Anchor | Confidence |
| :--- | :--- | :--- | :--- |
| `cred` | Credential exposure. 98 per cent of financial losses from cyber events involve compromise of valid account credentials. Servers are compromised about three times more often than user devices and carry more than ten times the loss. | `AC-ATTRIB-CRED` | **B** |
| `escape` | Host-namespace and container escape. No published attribution exists for the share of loss events running through a container boundary. The share is inferred from the exposure of the cluster API surface. | `AC-PREV-K8S` | **C** |
| `harden` | Kubernetes hardening. Defence in depth with no single attributable path. The smallest shares in the estate for that reason. | `AC-PREV-K8S` | **C** |

### `C_check`, per check

The conditional contribution of this one misconfiguration, informed by
prevalence. **Confidence D on every row.** No dataset prices a pod-spec field.
`AC-PREV-K8S` measures cloud IAM and cluster endpoints, not pod templates, so
even the prevalence input is a proxy for a proxy.

## Per-check derivation

| Check | Scenario | `riskTriple` mode | Implied share | Family | `C_check` reasoning | LEF confidence |
| :--- | :--- | ---: | ---: | :--- | :--- | :--- |
| `sa-token-automount-disabled` | `SCN-SECRET-EXFIL` | 25,000 | 0.14 | `cred` | An auto-mounted token is a usable credential at rest in every pod. The estate's stated template: its 0.5/1.5/4.0 frequency is the shape every other family should move toward. | D |
| `no-privileged-containers` | `SCN-TRUST-SUBVERT` | 120,000 | 0.24 | `escape` | A privileged container is a node compromise, and a node compromise invalidates the evidence chain. Highest share in the pack. | D |
| `no-host-pid` | `SCN-TRUST-SUBVERT` | 90,000 | 0.18 | `escape` | Host PID namespace exposes every process on the node, including credential material in process memory. | D |
| `no-host-ipc` | `SCN-TRUST-SUBVERT` | 50,000 | 0.10 | `escape` | Host IPC is a narrower path than host PID. Shared memory only. | D |
| `no-host-network` | `SCN-TRUST-SUBVERT` | 70,000 | 0.14 | `escape` | Host network reaches the node's loopback services, which is where the kubelet and cloud metadata sit. | D |
| `no-privilege-escalation` | `SCN-TRUST-SUBVERT` | 45,000 | 0.09 | `escape` | A precondition for escape rather than an escape. Below the researched `escape` band, consistent with being one step in a chain. | D |
| `no-root-containers` | `SCN-TRUST-SUBVERT` | 50,000 | 0.10 | `escape` | Root inside the container is a precondition for most published escapes. | D |
| `no-net-raw` | `SCN-SECRET-EXFIL` | 15,000 | 0.08 | `harden` | NET_RAW allows on-path interception within the pod network. A credential path, but a noisy and narrow one. | D |
| `no-added-capabilities` | `SCN-TRUST-SUBVERT` | 40,000 | 0.08 | `harden` | Covers every added capability, so the share is an average over a wide range of severities. | D |
| `capabilities-dropped-all` | `SCN-TRUST-SUBVERT` | 15,000 | 0.03 | `harden` | Defence in depth. The capabilities a runtime grants by default are already covered by narrower checks. | D |
| `no-windows-hostprocess` | `SCN-TRUST-SUBVERT` | 120,000 | 0.24 | `escape` | Equivalent to privileged on Linux by design. Priced the same on purpose. | D |
| `no-hostpath-volumes` | `SCN-TRUST-SUBVERT` | 100,000 | 0.20 | `escape` | A writable host path is a direct route to node compromise through the kubelet's own files. | D |
| `no-host-ports` | `SCN-SECRET-EXFIL` | 10,000 | 0.06 | `harden` | Exposure of a service rather than a credential path. Low share. | D |
| `no-secrets-in-env` | `SCN-SECRET-EXFIL` | 30,000 | 0.17 | `cred` | A secret in the environment is readable by any process in the container and lands in crash dumps and logs. Inside the researched `cred` band. | D |
| `seccomp-runtime-default` | `SCN-TRUST-SUBVERT` | 15,000 | 0.03 | `harden` | Reduces kernel attack surface. No attributable path of its own. | D |
| `security-context-applied` | `SCN-TRUST-SUBVERT` | 5,000 | 0.01 | `harden` | A hygiene check. The floor of the estate, correctly. | D |
| `no-default-namespace` | `SCN-UNAUTH-CHANGE` | 3,000 | 0.05 | `harden` | Blast-radius hygiene. Priced against unplanned change rather than compromise. | D |

## Shares that sit outside their family band

The researched family bands are in
[ANCHORS.md](../../ANCHORS.md#family-ranges). One row in this pack sits
outside its band, and it is recorded rather than retuned.

| Check | Band | Implied | Reading |
| :--- | :--- | ---: | :--- |
| `no-privilege-escalation` | `escape` 0.10 to 0.35 | 0.09 | Marginally low. Defensible if the check is read as one link in a chain rather than as the escape. No change made. |

Every other row in this pack falls inside its band. That is the one genuinely
reassuring result of this pass, and it is reassuring about internal
consistency only. It says nothing about whether the bands are right.
