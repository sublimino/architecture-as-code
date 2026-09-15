# SLCD-P4-2 — Outbound Inference Socket Detector

> **Did fd-avoidance fully succeed? Yes — completely, with no escalation required.**
> The detector performs socket-to-process correlation without reading `/proc/<pid>/fd`,
> `/proc/<pid>/fdinfo` or `/proc/<pid>/net`. P1-4's pins for all three are unweakened and
> green. `PROHIBITED_PROC_ENTRIES` is byte-identical to its pre-card value.
>
> | | |
> |---|---|
> | **Card** | `SLCD-P4-2 (implementation)` |
> | **Module** | `d2-signalloom/apps/agentmaxxing-host-sensor/network.py` |
> | **Range artefact** | `data/inference_providers.json` — see [slcd-p4-2-cidr-ranges.md](./slcd-p4-2-cidr-ranges.md) |
> | **Corpus** | `testdata/slcd_p4_2_observed_destinations.json` — 47 real destinations |
> | **Tests** | `test_network_socket_detector.py` (37) + `test_negative_security.py` |
> | **Host** | `andy`, Linux `7.1.3+deb13-amd64`, uid 1000, no capability grants |
> | **Base ref** | `refs/heads/integration/slcd-v0.1.0` |

---

## 1. The tension this card was told to expect, and how it resolved

The proposal specifies socket attribution as "matching local socket inodes from
`/proc/net/tcp` to process file descriptors under `/proc/<pid>/fd/`". That is how `ss -p` and
`lsof` work, and it is unbuildable here: `fd`, `fdinfo` and `net` are all members of
`PROHIBITED_PROC_ENTRIES` (`proc.py:14-32`), each pinned by a dedicated P1-4 negative test.
Implementing the proposal literally requires deleting from that set — a mission-wide
stop-and-report condition, not a refactor this card had the authority to perform.

The card anticipated this and required an escalation if fd-free correlation could not cover
the required case. **No escalation was needed.** The premise that inode→fd scanning is the
only correlation path is simply false: the kernel exposes a second, unrelated interface.

`NETLINK_SOCK_DIAG` emits `INET_DIAG_CGROUP_ID` for **every** socket. Two properties make it
work here:

1. **It needs no privilege.** Verified: the full dump runs as uid 1000 with no capabilities.
2. **It needs no extension request.** `inet_diag_req_v2.idiag_ext` is a `u8`, so extension 21
   could not be requested even if one wanted to. The kernel emits the attribute
   unconditionally in `inet_sk_diag_fill`. An implementation that tries to set the ext bit
   gets `struct.error`, which is a useful early signal that it has misread the interface.

A process's cgroup is readable at `/proc/<pid>/cgroup` — **not** a prohibited entry, and
already read elsewhere in this sensor by `cgroups.CgroupV2Reader`. `name_to_handle_at(2)` on
the cgroup directory returns the kernfs node id, which is the same 64-bit value the kernel put
in the netlink attribute. Socket and process therefore meet in cgroup-id space, and the
per-process descriptor tables are never opened.

### Correlation proof

```
my cgroup id (name_to_handle_at on /sys/fs/cgroup + /proc/self/cgroup):  5805759
socket opened to 1.1.1.1:443, located via netlink by source port:        cgroup_id=5805759
MATCH: True
```

This is pinned as a live test, not a one-off:
`LiveNetlinkCorrelationTests.test_end_to_end_socket_to_process_correlation_without_fd` opens a
real socket, finds it in the netlink dump and asserts the two ids are equal.

### The step that is easy to get wrong

`name_to_handle_at` is called on the **cgroupfs directory**, not on the procfs file. The two-step
matters: `/proc/<pid>/cgroup` is read as *text* to obtain the unified-hierarchy path, that path
is appended to `/sys/fs/cgroup`, and the handle is taken on the resulting directory. Handling
the procfs file instead would compare a procfs inode against a kernfs inode — two unrelated
integers — and every socket would simply fail to match, silently degrading the detector to
dedicated-ranges-only. The equality above is the check that rules that out, and it is pinned by
a live test rather than argued from the code.

---

## 1a. The aperture change — this widened, and saying so is part of the deliverable

Avoiding the prohibited entry is not by itself a privacy win, and it would be dishonest to
present it as one without this section.

Scanning `/proc/<pid>/fd` is **narrow**: it sees one process, the one being inspected. A
`SOCK_DIAG` dump is **host-wide**: unrestricted, it returns the 5-tuples of every socket on the
machine — the operator's browser, their bank, their VPN, their employer's internal services.
The prohibited-entry rule was not written with this interface in mind, so nothing in
`PROHIBITED_PROC_ENTRIES` constrains it. **This card traded a narrow-but-forbidden aperture for
a wide-but-permitted one, and that trade needs to be visible rather than inferred.**

Mitigation, implemented rather than merely documented: `NetlinkSockDiag.dump` accepts
`restrict_to_cgroups`, and `SocketDetector.detect(restrict_to_harness_cgroups=True)` narrows the
dump to the harness cgroups. A non-matching record is discarded **inside the parse loop, before
its destination address is decoded into a string**, so unrelated destinations are never
materialised in the process at all. `test_unrelated_destination_is_dropped_before_its_address_is_decoded`
pins the ordering specifically, because a gate placed after classification would leave the
addresses in memory and would still pass a naive test.

The flag defaults to `False` because the false-positive measurement in §4 needs the whole table
to score negatives. **Production collection must set it `True`.** That is a wiring obligation on
the integration card, recorded in §7.

Two residual exposures, neither eliminated:

- **cgroup paths are user-chosen strings.** `/user.slice/.../docker-<name>.scope` and transient
  systemd scope names carry container and project names. They stay in process memory and are
  never emitted, but a careless log line or exception message would leak them — the same class
  the zero-payload invariant exists to prevent, and one the fd pin would not catch.
  `test_no_cgroup_path_reaches_an_exception_message` pins the error paths.
- **In-kernel filtering is not implemented.** `INET_DIAG_BC_CGROUP_COND` bytecode would push
  the restriction into the kernel so the userspace process never receives unrelated sockets at
  all. Userspace discard is weaker: the bytes transit this process before being dropped.

---

## 2. The precision limit, stated plainly

**cgroup membership is one-to-many.** This is not a bug in the approach, it is the approach's
actual resolution, and pretending otherwise would be the "confident wrong attribution" failure
P2-2 already ruled out for harness identification.

The detector attributes a socket to a *cgroup*, and from there to the *set* of candidate PIDs
in that cgroup. Where that set holds exactly one harness process the attribution is
unambiguous. Where it holds several, `SocketClassification.ambiguous` is `True` and
`candidate_pids` carries the whole set. It is never narrowed by picking one.

On a developer workstation ambiguity is the normal case, not the exception. The cgroup that
owns this session's inference traffic is a systemd `tmux-spawn` scope also containing `bash`,
`bun`, `esbuild`, `git`, `python3` and `nono`. Per-PID attribution at that granularity is not
available without reading a prohibited entry, and the honest report is the candidate set.

**What this costs:** the telemetry can say "this cgroup's coding-agent workload sent N bytes to
Anthropic", not "PID 12345 sent N bytes to Anthropic". For the proposal's stated purpose —
estate-level visibility into autonomous coding operations — cgroup granularity is sufficient.
If per-PID attribution is later required, that is a new decision with a new privacy analysis,
not something to smuggle in by relaxing the prohibited set.

---

## 3. Classification boundary

No DNS resolution of destinations. No reverse lookups. No TLS handshake inspection. No packet
payload access. Enforced two ways, because either alone is insufficient:

- **Static (AST, not text):** `test_module_source_contains_no_resolver_call` walks the module's
  AST for `gethostbyaddr`, `getnameinfo`, `getfqdn`, `gethostbyname`, `getaddrinfo`. A text
  scan was tried first and rejected — it fires on the module's own prose, which is the
  "guard satisfied by a comment" failure in reverse.
- **Runtime:** `test_runtime_dns_tripwire_never_fires_during_a_detection_cycle` replaces every
  resolver in the `socket` module with a function that raises, then runs a full cycle. This is
  what catches a call built from a variable that no static scan can see.

The detector also refuses to shell out. `ss -p` and `lsof` resolve PIDs by scanning
`/proc/<pid>/fd`; a subprocess boundary would place the prohibited read one hop outside
anything this repository's tests can observe. `test_detector_does_not_shell_out_to_ss_or_lsof`
pins the absence of `subprocess`, `popen`, `system`, `fork`, `execv` and `spawn` from the
module's executable symbols.

---

## 4. Measured false-positive rate

The proposal claims zero false positives. That claim was never measurable, because the CIDR
list it depends on did not exist. Both now exist, so here is a number instead of a claim.

**Corpus:** 47 distinct established outbound destinations captured on an ordinary developer
workstation during a working session, with coding agents, a browser, a music client, a
messaging client, a VPN agent and container tooling all running concurrently. Private,
loopback, link-local, CGNAT and site-relay addresses are excluded so no network topology is
committed; application names are not committed, only a traffic class.

### Full confusion matrix — both arms, identical destination set

Precision alone cannot judge a filter whose entire operation is to *attribute less*. Reporting
only a falling false-positive rate would be consistent with "the tiered arm also dropped half
the true flows", so both arms are scored over all 47 destinations:

| Method | TP | FP | TN | FN | Precision | **Recall** |
|---|---|---|---|---|---|---|
| **Untiered CIDR** — the method the proposal describes | 11 | **7** | 28 | 1 | 61.1% | **91.7%** |
| **Tiered + cgroup-corroborated** — what this card ships | 11 | **1** | 34 | 1 | 91.7% | **91.7%** |

**Recall is identical.** Tiering removes 6 of 7 false positives and converts not one true
positive into a false negative. That is the result that matters, and it is the one a
precision-only table would have left unproven.

The denominators in the FP rates below differ (18 vs 12) because they are *predicted
positives* — the quantity the intervention directly shrinks — not the negative class.

| Method | FP rate | 95% Wilson interval |
|---|---|---|
| Untiered CIDR | **7/18 = 38.9%** | [20.3%, 61.4%] |
| Tiered + corroborated | **1/12 = 8.3%** | [1.5%, 35.4%] |

**The intervals overlap, and n is small.** One-sided Fisher's exact on [[7,11],[1,11]] gives
p ≈ 0.07 — not significant at α = 0.05. The point estimates differ by 4.7×; the evidence does
not support stating that multiplier as an established effect size. What the data *does*
support, and what does not depend on the interval arithmetic, is the mechanism: every one of
the 6 eliminated false positives is a shared-tier match, and the shared-tier check is the thing
that eliminated them.

### Where the improvement comes from — audited, not assumed

The delta could in principle have come from the dedicated ranges rather than the tier logic.
Every one of the 7 untiered false positives was audited, not only the residual:

| Destination | Label | Matched provider | Tier | Suppressed by tiering? |
|---|---|---|---|---|
| `160.79.104.10:443` | other-app | anthropic | **dedicated** | no — survives as the residual |
| `35.186.224.33:443` | media-app | google-vertex | shared | yes |
| `104.20.26.192:443` | browser | openai | shared | yes |
| `104.26.1.147:443` | other-app | openai | shared | yes |
| `142.251.29.101:443` | browser | google-vertex | shared | yes |
| `172.66.1.120:443` | media-app | openai | shared | yes |
| `172.66.166.164:443` | browser | openai | shared | yes |

6 of 6 shared-tier false positives suppressed; the single dedicated-tier one survives. The
improvement is entirely attributable to the shared-tier corroboration requirement, which is
pinned by `test_the_improvement_comes_from_the_shared_tier_not_the_dedicated_ranges`.

### Tier assignment is not out-of-sample — stated rather than glossed

The tier for each range follows a rule that is independent of this corpus: *does anyone other
than the provider use this address space?* Cloudflare and Google publish their ranges as shared
infrastructure and Anthropic publishes its range as dedicated, so the assignments derive from
provider documentation rather than from which CIDRs happened to misfire here. **But the corpus
was captured before the tiers were finalised, and the Spotify-in-GCP observation did motivate
the design.** The 8.3% is therefore not a clean out-of-sample generalisation estimate, and is
not presented as one.

### Measurement-host cgroup topology — the condition the 8.3% depends on

The shared-tier check is only meaningful if harnesses occupy cgroups that ordinary desktop
applications do not. On a host where the terminal, editor and browser all share one
`session-N.scope`, "a harness process in the socket's cgroup" is satisfied by the whole desktop
and the check becomes a no-op.

On the measurement host, harnesses run under per-session systemd `tmux-spawn-<uuid>.scope`
units, separate from the desktop session scope. Of 47 destinations, **exactly one** sat in a
cgroup containing both a browser and a harness. **The 8.3% does not transfer to a host with
coarser cgroup topology**, and no evidence was gathered about the topology of any deployment
host. An estate rollout should measure its own rate rather than inherit this one.

### The one residual false positive is a label error, not a detector error

The remaining FP is `160.79.104.10:443`, inside Anthropic's dedicated range, whose corpus row
is labelled `other-app`. Inspection of that cgroup shows a process with comm `node-MainThread`
and `/proc/<pid>/exe` basename `node`, having sent 56,103,805 cumulative bytes to that
destination. That is Claude Code. The comm-based labelling oracle matches literal harness
names (`claude`, `agy`, `codex`) and does not recognise a Node-hosted harness.

**The label has deliberately not been corrected, and 0% is not claimed.** Re-labelling a row
after seeing which way it scores is how a measured rate quietly becomes an asserted one — the
exact failure this section exists to prevent. The reported 1/12 is therefore an **upper
bound**; the corrected figure is 0/12. The reason 0 cannot be *proved* with this oracle is
itself informative: distinguishing Claude Code from any other Node process requires reading
`/proc/<pid>/cmdline`, which is a prohibited entry. The measurement is bounded by the same
privacy invariant the detector is.

The limitation is recorded in the corpus artefact under `known_label_limitations` so it
travels with the data rather than living only in this document.

### What the numbers do and do not license

- They **do** falsify the proposal's zero-false-positive KPI *for the method the proposal
  describes*: 38.9% measured on real traffic.
- They **do** show the shipped method is materially better on the same corpus, from the same
  list, under the same oracle.
- They **do not** generalise to other estates. The rate depends on what else the workstation
  talks to. A host that never opens a browser will score better; a host running many
  Cloudflare-fronted services will score worse.
- The corpus is a single session on a single host. It is real, which synthetic fixtures are
  not, but it is not a population.

---

## 5. Schema conformance

Output projects to exactly P1-1's frozen two fields:

```json
{ "inference_endpoint": "api.anthropic.com", "egress_bytes": 45000 }
```

`egress_bytes` comes from `tcp_info.tcpi_bytes_sent` (`INET_DIAG_INFO`, `__u64` at offset 200),
with a length guard falling back to `tcpi_bytes_acked` on kernels predating the field — a
fallback that understates egress by the in-flight window and never overstates it. The value is
per-socket and cumulative for that socket's lifetime; on close and 5-tuple reuse a new socket
starts from zero, so a consumer differencing successive samples must key on the socket, not the
endpoint, or it will record a negative delta as a reset. `NetworkInfo` bounds the field at
2^53−1 in line with P1-1.

**`egress_bytes` is a length oracle, and this document names it rather than leaving it
implicit.** Byte counts against a known inference endpoint, sampled over time, correlate with
prompt and response size — the same differencing shape flagged for SLDP-P4-2's tombstones. It
remains within the bounded-integer posture and is not being removed here, but any consumer that
retains a time series of this field is building something the zero-payload invariant does not
by itself cover.

**Zero-payload chokepoint.** There is no shared `assert_zero_payload` construction chokepoint in
the sensor package for this module to route through; `network.py` has its own construction path
and inherits none of P4-1's closed string predicates. That is stated explicitly because
silently *widening* a shared predicate set to admit `api.anthropic.com` would have been a
cross-card regression affecting every other consumer. The containment here is the frozen
`ALLOWED_INFERENCE_ENDPOINTS` constant instead.

**`inference_endpoint` is guarded by set membership, not by the field regex.** This matters
more than it looks. `INFERENCE_ENDPOINT_REGEX` is `^[a-zA-Z0-9.-]{1,128}$`, which a raw IPv4
literal also satisfies — `NetworkInfo(inference_endpoint="160.79.104.10")` constructs and
validates without complaint. A destination address leaking into that field would therefore
pass every existing schema check while the field *name* still looked correct, which is exactly
the silent-widening failure the card warned about. `SocketDetector.to_network_info` instead
requires the value to be a member of the permitted endpoint set, and
`test_emit_rejects_a_raw_ip_smuggled_into_the_endpoint_field` pins the distinction by first
demonstrating that the regex alone permits the IP.

**The allow-list is not its own source of truth.** Checking membership against the same JSON
that defines the ranges would mean adding a provider to the artefact silently widened the emit
surface, with no code change and no test movement — a guard that grows whenever its input
grows is not a guard. The permitted identifiers are frozen in code as
`ALLOWED_INFERENCE_ENDPOINTS`, and `InferenceProviderRanges.from_dict` **raises** if the
artefact declares an inference endpoint absent from that constant. Adding a provider therefore
requires a visible edit to a Python constant that appears in a diff.
`test_artefact_cannot_introduce_an_endpoint_absent_from_the_code_constant` pins it with a rogue
artefact declaring `exfil.example.com`.

**The oracle never degrades silently.** `SocketDetector.probe_cgroup_oracle` reports
`available`, `unavailable_no_cgroup_attribute` (kernel < 5.5, or no harness cgroup resolved) or
`unavailable_root_cgroup_only` (a cgroup v1 `net_cls`/`net_prio` controller is mounted, which
disables socket cgroup association so every socket reports root and would otherwise "match"
everything). On an unavailable oracle the detector falls back to dedicated and loopback ranges
only — a materially different false-positive profile — and `last_oracle_status` makes that
visible to the caller instead of leaving it to be inferred from a rate that quietly moved.

One further limitation, not mitigated: **a socket's cgroup is fixed at creation.** A harness
migrated between cgroups after opening a connection carries the old id on that socket, which
matters most for exactly the long-lived keepalive connections inference endpoints use.

`kind: control-plane` providers (OpenBao) are excluded from that set and can never be emitted.

---

## 6. Verification

```bash
cd d2-signalloom/apps/agentmaxxing-host-sensor
python3 -m unittest test_negative_security -v          # P1-4 pins, unweakened
python3 -m unittest test_network_socket_detector -v    # this card
python3 -m unittest discover -p 'test_*.py'            # whole package
```

Negative-security coverage added by this card:

| Assertion | Test |
|---|---|
| module's procfs surface is an allow-list equal to `{"cgroup"}` | `test_module_declares_its_procfs_surface_as_an_allow_list` |
| that surface is disjoint from `PROHIBITED_PROC_ENTRIES` | `test_declared_surface_is_disjoint_from_the_prohibited_set` |
| a full detection cycle makes zero prohibited `_safe_proc_path` calls | `test_runtime_tripwire_records_zero_prohibited_safe_proc_path_calls` |
| no prohibited procfs path literal in executable code | `test_static_scan_finds_no_fd_fdinfo_or_net_path_construction` |
| no subprocess escape hatch to `ss`/`lsof` | `test_detector_does_not_shell_out_to_ss_or_lsof` |
| `PROHIBITED_PROC_ENTRIES` unchanged by this card | `test_p4_2_did_not_weaken_the_prohibited_set` |
| `fd`/`fdinfo`/`net` pins still raise | `test_prohibit_procfs_{fd,fdinfo,net}_inspection` (pre-existing, P1-4) |

---

## 7. Open items for the phase Governor

1. **Wiring, with one obligation attached.** `SocketDetector` is not yet called from
   `collector.py`. Populating `CodingAgentTelemetry.network` is downstream integration work,
   left outside this card because `collector.py` is a shared-file collision risk. **The
   integration must pass `restrict_to_harness_cgroups=True`** — the default is `False` only so
   the §4 measurement can score negatives, and shipping the default would leave the wide
   aperture described in §1a open in production.
1b. **In-kernel filtering.** `INET_DIAG_BC_CGROUP_COND` bytecode would move the cgroup
   restriction into the kernel so unrelated sockets never reach userspace at all. Not
   implemented; userspace discard is the weaker mitigation currently in place.
2. **Lawful basis.** Workstation collection remains gated on the Legitimate Interest
   Assessment and works-council position. This card builds the detector; it does not enable
   collection, and nothing here should be read as clearing that gate.
3. **Per-PID attribution** is unavailable by design (§2). If the dashboard needs it, that is a
   new decision requiring its own privacy analysis — not a relaxation of the prohibited set.
4. **Range freshness.** The artefact is `2026-09-15.1`. Cloudflare and Google publish machine-
   readable range lists; a scheduled refresh with tier review is not yet built.
