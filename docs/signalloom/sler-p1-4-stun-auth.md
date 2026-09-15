# SLER-P1-4: Stun Sentinel /stun Authentication & NetworkPolicy Defense-in-Depth

**Task ID:** `SLER-P1-4`  
**Phase:** Phase 1 Implementation (`SLER-P1-4`)  
**Shortcode:** `SLER`  
**Component:** `d2-signalloom/apps/stun-sentinel`  
**Date:** 2026-09-15  

---

## 1. Executive Summary & Exploit Path Analysis

### 1.1 The Pre-Existing Vulnerability & Exploit Path

Prior to `SLER-P1-4`, the Tier 0 kernel containment daemon `stun-sentinel` presented a severe asymmetric authentication vulnerability and structural type signature gap:

1. **Privileged, Node-Wide Footprint:**
   - `stun-sentinel` runs as a DaemonSet (`d2-signalloom/deploy/stun-sentinel-daemonset.yaml:79-114`) with `hostPID: true` (`:103`), `privileged: true` (`:136`), `runAsUser: 0` (`:138`), and a read-write host mount of `/sys/fs/cgroup` (`:144-147`).
   - The namespace `signalloom-system` explicitly bypasses Pod Security Standards (`pod-security.kubernetes.io/enforce: privileged`, `:34-36`).
   - `stun-sentinel` exposes an unauthenticated or weakly gated HTTP server on port 8080.

2. **The Structural Engine Gap (`Freezer.Freeze` vs `Freezer.Unfreeze`):**
   - In `d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go`, `Unfreeze(cgroupPath, credential string)` (`:575`) enforced governance token validation via `f.validator(credential)`.
   - In contrast, `Freeze(cgroupPath string)` (`:507`) and `FreezePod(podUID string)` (`:557`) accepted **no credential parameter at all**.
   - At the type system level, the `Freezer` engine was structurally incapable of enforcing credentials on freeze actions.

3. **The Asymmetric DoS Exploit Path:**
   - Any process or network-adjacent pod in the cluster capable of reaching the daemon's listen port (`:8080`) could issue `POST /stun` with a target `pod_uid`.
   - The daemon would resolve the pod's cgroup and write `1` to `cgroup.freeze`, freezing arbitrary agent or system pods in-kernel (putting all processes into uninterrupted D-state sleep).
   - Because `Unfreeze` required a valid `STUN_RESUME_TOKEN`, the unauthorized caller could freeze arbitrary pods across the node fleet but could not unfreeze them.
   - The operator would lose containment control, and arbitrary workloads could be subjected to unrecoverable Denial of Service.

4. **The HostNetwork / NetworkPolicy Bypass:**
   - As documented in `d2-signalloom/infra/agent-swarm/networkpolicy.yaml:12-13`, when the sentinel operates on node/host networking, standard CNI `NetworkPolicy` rules attaching to container veth devices cannot filter host interface traffic.
   - Declaring the endpoint "protected by NetworkPolicy" without application-layer authentication was a critical false sense of security.

---

## 2. Technical Remediation & Architectural Hardening

### 2.1 Type-Level Signature Refactor (`pkg/cgroup/freezer.go`)

To ensure the type system itself prevents unauthenticated freeze invocations:

1. **Method Signature Parity:**
   ```go
   // pkg/cgroup/freezer.go:525
   func (f *Freezer) Freeze(cgroupPath, credential string) (*FreezeResult, error)

   // pkg/cgroup/freezer.go:575
   func (f *Freezer) FreezePod(podUID, credential string) (*FreezeResult, error)

   // pkg/cgroup/freezer.go:589
   func (f *Freezer) Unfreeze(cgroupPath, credential string) (*FreezeResult, error)

   // pkg/cgroup/freezer.go:643
   func (f *Freezer) UnfreezePod(podUID, credential string) (*FreezeResult, error)
   ```

2. **Dual Validator Isolation:**
   - `Freezer` now maintains distinct validators for freeze and resume operations:
     ```go
     type Freezer struct {
         root            string
         deadline        time.Duration
         freezeValidator CredentialValidator
         resumeValidator CredentialValidator
     }
     ```
   - Both default strictly to `DenyAllCredentials` (`freezer.go:122`) in `New(...)`. Any caller that forgets to wire a validator fails closed with `ErrUnauthorized` (`cgroup: governance credential did not validate`).
   - Configuration options `WithFreezeCredentialValidator(v)` and `WithCredentialValidator(v)` (aliased as `WithResumeCredentialValidator`) allow explicit injection of token validators.

### 2.2 Scoped Token Separation (`cmd/stun-sentinel/main.go`)

1. **Distinct Environment Variables:**
   - `STUN_FREEZE_TOKEN`: Dedicated Secret-mounted credential authorizing `/stun` and `Freezer.Freeze`.
   - `STUN_RESUME_TOKEN`: Dedicated Secret-mounted credential authorizing `/resume` and `Freezer.Unfreeze`.
   - Neither token is ever exposed via CLI flags (preventing exposure in `/proc` or `ps`).

2. **Startup Fail-Fast Checks (`cmd/stun-sentinel/main.go:255-270`):**
   - If `STUN_FREEZE_TOKEN` is unset or empty: server refuses to start with `"stun-sentinel: STUN_FREEZE_TOKEN is required and cannot be empty"`.
   - If `STUN_RESUME_TOKEN` is unset or empty: server refuses to start with `"stun-sentinel: STUN_RESUME_TOKEN is required and cannot be empty"`.
   - If `STUN_FREEZE_TOKEN == STUN_RESUME_TOKEN`: server refuses to start with `"stun-sentinel: STUN_FREEZE_TOKEN and STUN_RESUME_TOKEN must be distinct credentials"`.

3. **HTTP Middleware & Handler Hardening (`requireBearer`):**
   - `requireBearer` intercepts `/stun` and `/resume` before JSON request parsing or cgroup lookups.
   - Missing or invalid tokens immediately reject with HTTP `401 Unauthorized` (`writeJSON(w, http.StatusUnauthorized, ...)`).
   - Constant-time comparison (`constantTimeTokenValidator`) ensures token evaluation does not leak length or timing information.
   - Using `STUN_RESUME_TOKEN` to call `/stun` returns HTTP 401; using `STUN_FREEZE_TOKEN` to call `/resume` returns HTTP 401.

### 2.3 NetworkPolicy Defence-in-Depth

1. **Manifest Configuration:**
   - Manifests updated in `d2-signalloom/deploy/stun-sentinel-daemonset.yaml:198-250` and `d2-signalloom/deploy/stun-sentinel-networkpolicy.yaml`.
   - Restricts ingress on port 8080 to pods from `fe-signalloom` with label `app.kubernetes.io/name=fleet-manager` or `app.kubernetes.io/part-of=signalloom`.
   - Egress restricted to DNS (port 53 UDP/TCP) and Kubernetes API (port 443/6443 TCP).

2. **HostNetwork Boundary Recognition:**
   - The manifest explicitly documents that for hostNetwork / node-network pods, application-level mutual authentication and token gates serve as the primary control, while NetworkPolicy provides defense-in-depth for standard container networking.

---

## 3. Verification & Evidence Citations

### 3.1 Unit & Integration Test Suite (`cmd/stun-sentinel/main_test.go`, `pkg/cgroup/freezer_test.go`)

- `TestStunRefusesWithoutCredential`: Asserts 401 Unauthorized when no Authorization header is provided.
- `TestStunRefusesWrongCredential`: Asserts 401 Unauthorized when an invalid token is provided.
- `TestStunRefusesResumeToken`: Asserts 401 Unauthorized when attempting cross-scope token usage.
- `TestStunFreezesAndEmitsHaltedEvent`: Asserts 200 OK and valid telemetry emission when valid `STUN_FREEZE_TOKEN` is provided.
- `TestFreezeAndUnfreezeValidatorsAreDistinct`: Proves engine-level validator isolation in `pkg/cgroup`.
- `TestFreezeDefaultsToRefusal`: Proves `DenyAllCredentials` default prevents unauthorized writes to `cgroup.freeze`.
- `TestRunRefusesWhenFreezeTokenUnsetOrEmpty`: Verifies startup fail-fast behavior.
- `TestRunRefusesWhenTokensAreEqual`: Verifies startup refusal on token collision.

All 5 packages in `d2-signalloom/apps/stun-sentinel` compile and pass 100% cleanly.
