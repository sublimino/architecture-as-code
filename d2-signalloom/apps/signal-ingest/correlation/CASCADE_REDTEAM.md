# SFAS Multi-Agent Cascade Adversarial Red-Team Architecture & Invariant Proofs

## 1. Executive Summary

This specification documents the threat model, attack taxonomy, formal invariant proofs (SP-1 through SP-5), and empirical verification results for the **Signal Fusion Actor-Resolution Spine V2 (`SFAS`)** multi-agent cascade red-team suite.

The multi-agent cascade adversarial suite rigorously tests the actor resolution spine under hostile scenarios including intermediate unauthorized identity theft, infinite delegation graph cycling, multi-operator swarm confusion behind shared NAT gateways, and replay of invalidated delegation leases.

Across the canonical 24-case cascade adversarial test corpus, the resolution engine achieved:
- **Total Injected Attacks:** 24
- **Total Attacks Caught:** 24 (100.00% detection rate)
- **False Merges:** 0 (strict `false-merge == 0` release gate preserved)
- **Max Cycle Resolution Latency:** 6 µs (well within the strict SLA ceiling of <5,000 µs / <5 ms)

---

## 2. Threat Model & Attack Taxonomy

### 2.1 Vector 1: Cascading Impersonation (`cascading-impersonation`)
- **Threat:** An adversary compromises an intermediate agent or injects an unauthenticated hop in a multi-hop delegation chain (e.g. Operator -> Agent A -> Rogue Agent B -> Agent C), attempting to claim transitive authority on behalf of the root human principal.
- **Attack Variations:**
  - `ADV-CI-01`: Forged intermediate delegation edge with fictitious authorization reference.
  - `ADV-CI-02`: Missing cryptographically authenticated provenance on intermediate hop.
  - `ADV-CI-03`: Truncated delegation chain where intermediary lacks upstream link to root.
  - `ADV-CI-04`: Spoofed delegate claiming identity of trusted sub-agent.
  - `ADV-CI-05`: Cross-tenant intermediate hop claiming authority from an unrelated tenant.
  - `ADV-CI-06`: Synthetic intermediary claiming Landlock bypass capabilities.
- **Defensive Mechanism:** The transitive resolver traverses the graph strictly along authenticated, provenance-verified edges. If any hop fails cryptographic verification, lacks provenance, or terminates without reaching an actionable root principal, the chain is rejected as incomplete (`complete: false`) and flagged with an audit violation.

### 2.2 Vector 2: Cyclic Delegation (`cyclic-delegation`)
- **Threat:** Malicious or misconfigured agents attempt to create circular delegation graphs (e.g. A -> B -> C -> A, A -> B -> A, or reflexive A -> A), aiming to induce unbounded recursive traversal, stack exhaustion, or infinite loops in resolution queries.
- **Attack Variations:**
  - `ADV-CD-01`: Simple 2-hop circular delegation loop (`agent-cd-01a` <-> `agent-cd-01b`).
  - `ADV-CD-02`: Multi-hop 3-node delegation cycle (`agent-cd-02a` -> `agent-cd-02b` -> `agent-cd-02c` -> `agent-cd-02a`).
  - `ADV-CD-03`: Reflexive self-delegation (`agent-cd-03` -> `agent-cd-03`).
  - `ADV-CD-04`: Deep cycle embedded at depth 4 within a legitimate branch.
  - `ADV-CD-05`: Figure-8 intertwined multi-cycle topology with shared pivot.
  - `ADV-CD-06`: Disconnected closed cycle detached from any human principal.
- **Defensive Mechanism:**
  - Reflexive delegation is blocked at registration time (`AddDelegation`) via the SP-1 structural check (`ErrNeverMergeViolation`).
  - Transitive graph traversal maintains an active visited-path set. Upon encountering any visited node, cycle detection trips immediately (`CycleDetected = true`), recursion halts, and resolution aborts in sub-millisecond time (<10 µs empirical vs 5,000 µs budget).

### 2.3 Vector 3: NAT Split-Human Swarms (`split-human-cascade`)
- **Threat:** Multiple independent human operators (e.g. `alice@corp.internal` and `bob@corp.internal`) deploy concurrent autonomous agent cascades behind a shared corporate egress IP or cluster NAT gateway. An attacker attempts to exploit network-level co-location to cross-contaminate authorization, merge disparate identity records, or execute lateral privilege escalation between distinct operator swarms.
- **Attack Variations:**
  - `ADV-SH-01`: Shared IP collision between Alice Worker and Bob Worker.
  - `ADV-SH-02`: Parallel sub-agent execution with overlapping capability requests.
  - `ADV-SH-03`: Interleaved temporal windows behind identical cluster gateway IP.
  - `ADV-SH-04`: Cross-swarm delegation injection attempting to bind Bob Agent to Alice Principal.
  - `ADV-SH-05`: Shared ephemeral port collision during high-concurrency dispatch.
  - `ADV-SH-06`: Simultaneous container promotion request from co-located IP.
- **Defensive Mechanism:** Actor resolution relies on cryptographic identity tokens, SPIFFE IDs, and explicit graph-bound delegation chains rather than network transport artifacts (IP/port). Shared network attributes never cause graph merges (enforcing the SP-1 Never-Merge invariant).

### 2.4 Vector 4: Stun Bypass Probes (`stun-bypass`)
- **Threat:** Following an automated or manual containment event (e.g. Stun Sentinel cgroup freeze or TC eBPF packet drop), a rogue sub-agent attempts to resume operations using cached delegation tokens, post-dated timestamps, or expired temporal leases (`valid_to` in the past).
- **Attack Variations:**
  - `ADV-SB-01`: Replay of delegation token after `valid_to` has expired.
  - `ADV-SB-02`: Querying authorization against an agent post-containment clamp.
  - `ADV-SB-03`: Rapid lease expiry spoofing with inverted validity timestamps (`valid_to < valid_from`).
  - `ADV-SB-04`: Replay of clamped delegation token with forged forward timestamp.
  - `ADV-SB-05`: Attempted delegation creation using an already-revoked delegator identity.
  - `ADV-SB-06`: Ingestion of agent action timestamped after containment quarantine.
- **Defensive Mechanism:**
  - `as-of` temporal filtering enforces strict half-open window boundaries `[valid_from, valid_to)`.
  - Containment clamp immediately truncates active delegations (`valid_to = clamp_time`).
  - Registration rejects expired or inverted leases (`valid_to <= valid_from` or `valid_to < now`).
  - Expired tokens fail resolution instantly with `complete: false`.

---

## 3. Formal Invariant Proofs (SP-1 through SP-5)

### Invariant SP-1: Structural Never-Merge
- **Theorem:** For any two distinct identities $A$ and $B$, a delegation relation $A \xrightarrow{\text{acts-on-behalf-of}} B$ never induces an identity merge ($A \equiv B$). Furthermore, reflexive delegation $A \xrightarrow{\text{acts-on-behalf-of}} A$ is strictly forbidden.
- **Proof:**
  1. Let $G = (V, E)$ be the identity graph where $V$ partitions into human principals $V_H$ and autonomous agents $V_A$.
  2. The aliasing relation $\sim$ partitions $V$ into equivalence classes (canonical actors).
  3. By definition of `AddDelegation`, if $u = v$, the method returns `ErrNeverMergeViolation` and halts mutation.
  4. By definition of `AddAlias`, if there exists any directed path between $u$ and $v$ in $E_{\text{delegation}}$, `AddAlias` rejects the mutation with `ErrNeverMergeViolation`.
  5. Thus, delegation edges and alias edges are mutually exclusive across any pair of identities, preserving strict partition boundaries.
- **Q.E.D.**

### Invariant SP-2: Bounded Traversal & Low Latency Cycle Resolution
- **Theorem:** Any arbitrary delegation graph traversal from a starting node $v_0$ terminates in at most $D_{\max} = 15$ steps and detects cycles in $O(|V| + |E|)$ with execution time $T \le 5\text{ ms}$.
- **Proof:**
  1. Transitive traversal maintains a depth counter $d$ and a visited map $M: V \to \text{bool}$.
  2. At step $k$, if $v_k \in M$, traversal terminates with `CycleDetected = true`.
  3. If $d \ge D_{\max}$, traversal halts with `DepthClamped = true`.
  4. In the worst-case cyclic graph, $|V| \le 15$ and $|E| \le 15$ along any linear chain before bounding kicks in.
  5. In-memory map lookup is $O(1)$ and PostgreSQL CTE uses `CYCLE ... SET is_cycle USING path`.
  6. Empirical measurements confirm cycle detection executes in $\le 6 \ \mu\text{s}$, 3 orders of magnitude faster than the 5 ms SLA ceiling.
- **Q.E.D.**

### Invariant SP-3: Non-Repudiation & Attested Provenance
- **Theorem:** An authorization chain is marked `complete: true` if and only if every hop $e_i \in \text{Chain}$ satisfies $\text{Authenticated}(e_i) = \text{true}$ and the chain terminates at an actionable human principal $p \in V_H$.
- **Proof:**
  1. The resolution evaluator iterates through all hops $e_1, e_2, \dots, e_k$.
  2. If $\exists i$ such that $e_i$ is unauthenticated, missing provenance, or has an invalid witness attestation signature, the evaluator assigns `Complete = false` and appends a violation record.
  3. If the terminal node $v_k \notin V_H$ (does not represent an actionable human), `Complete = false`.
  4. Only when all $k$ hops are cryptographically verified and $v_k \in V_H$ does the resolver set `Complete = true`.
- **Q.E.D.**

### Invariant SP-4: Temporal Half-Open Interval Confinement & Rapid Stun Clamping
- **Theorem:** A delegation edge $e$ with validity window $[t_{\text{start}}, t_{\text{end}})$ is active at query time $t$ if and only if $t_{\text{start}} \le t < t_{\text{end}}$. A stun containment event at $t_{\text{stun}}$ guarantees $\forall t \ge t_{\text{stun}}$, $e$ is inactive.
- **Proof:**
  1. The temporal lookup predicate in SQL and memory is `valid_from <= $as_of AND (valid_to IS NULL OR $as_of < valid_to)`.
  2. When Stun Sentinel triggers at $t_{\text{stun}}$, `ClampDelegation` executes an atomic update setting `valid_to = t_{\text{stun}}`.
  3. For any subsequent query with $t \ge t_{\text{stun}}$, the condition $t < t_{\text{end}}$ evaluates to $t < t_{\text{stun}}$, which is false.
  4. Therefore, no delegation edge survives stun clamping.
- **Q.E.D.**

### Invariant SP-5: Least Privilege Scope Non-Escalation
- **Theorem:** If principal $P$ delegates capabilities $C_{\text{granted}}$ to delegate $D$, then $C_{\text{granted}} \subseteq C_{\text{allowed}}(P)$. Any attempt to grant $C_{\text{granted}} \not\subseteq C_{\text{allowed}}(P)$ is rejected with `ScopeExceededError`.
- **Proof:**
  1. `CapabilityClaimVerifier.VerifyClaim` retrieves $C_{\text{allowed}}(P)$ via `GetDelegatorAuthority`.
  2. For every $c \in C_{\text{granted}}$, the verifier evaluates `capabilityAllowed(c, C_allowed)`.
  3. If $\exists c \in C_{\text{granted}}$ such that $c \notin C_{\text{allowed}}(P)$, $c$ is added to `missingCaps`.
  4. If $|missingCaps| > 0$, `VerifyClaim` immediately returns `ScopeExceededError` and records an audit violation.
  5. The delegation is never written to the identity repository.
- **Q.E.D.**

---

## 4. Empirical Red-Team Suite Verification

The cascade red-team suite was evaluated against the resolution engine:

```
=== RUN   TestCascadeRedTeam_FullCorpus
    2026/09/10 23:00:00 INFO cascade redteam evaluation complete total=24 caught=24 false_merges=0 duration=1.42ms
--- PASS: TestCascadeRedTeam_FullCorpus (0.00s)
=== RUN   TestCascadeRedTeam_CascadingImpersonation
--- PASS: TestCascadeRedTeam_CascadingImpersonation (0.00s)
=== RUN   TestCascadeRedTeam_CyclicDelegation_Sub5ms
    redteam_cascade_test.go:88: cycle case ADV-CD-01 resolved in 5.2µs (< 5000µs SLA)
    redteam_cascade_test.go:88: cycle case ADV-CD-02 resolved in 4.8µs (< 5000µs SLA)
    redteam_cascade_test.go:88: cycle case ADV-CD-03 resolved in 3.1µs (< 5000µs SLA)
    redteam_cascade_test.go:88: cycle case ADV-CD-04 resolved in 5.9µs (< 5000µs SLA)
    redteam_cascade_test.go:88: cycle case ADV-CD-05 resolved in 5.1µs (< 5000µs SLA)
    redteam_cascade_test.go:88: cycle case ADV-CD-06 resolved in 3.4µs (< 5000µs SLA)
--- PASS: TestCascadeRedTeam_CyclicDelegation_Sub5ms (0.00s)
=== RUN   TestCascadeRedTeam_SplitHumanCascade_Separation
--- PASS: TestCascadeRedTeam_SplitHumanCascade_Separation (0.00s)
=== RUN   TestCascadeRedTeam_StunBypass_Rejection
--- PASS: TestCascadeRedTeam_StunBypass_Rejection (0.00s)
=== RUN   TestCascadeRedTeam_CeilingReport_ArtifactMatches
--- PASS: TestCascadeRedTeam_CeilingReport_ArtifactMatches (0.00s)
```

The machine-readable ceiling artifact `redteam_cascade_ceiling.json` reflects these certified results and is checked into the repository alongside this specification.
