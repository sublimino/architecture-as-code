# EAPR-P1-1 Part C — EAP mission capsule leases (2026-09-24)

Store: `~/.cline/kanban/auto-controller/` (the directory `MissionState.ts` reads via `resolveStateDirectory`).

## Before (jq '.lease' per capsule)

```
3b352918166b4dfa79a35f48-SLEA.json: {"status":"active","lease":{"name":"ajm-auto-kanban-slea-3b352918166b","generation":"20d65905e2b2390b","enabled":true,"armedAt":"2026-09-23T00:15:51.167Z","activatedAt":"2026-09-23T00:16:03.359Z","disabledAt":null}}
b6db94da0ed18b775266b505-SLET.json: {"status":"active","lease":{"name":"ajm-auto-kanban-slet-b6db94da0ed1","generation":"0b55f822d533ba45","enabled":true,"armedAt":"2026-09-23T00:15:51.989Z","activatedAt":"2026-09-23T00:16:03.399Z","disabledAt":null}}
f955d574ef08d2f9f3031bab-SLES.json: {"status":"active","lease":{"name":"ajm-auto-kanban-sles-f955d574ef08","generation":"eb3f3b0a852d7bdf","enabled":true,"armedAt":"2026-09-23T00:15:52.806Z","activatedAt":"2026-09-23T00:16:03.441Z","disabledAt":null}}
cab8eb878c6c49259d433c96-SLED.json: {"status":"active","lease":{"name":"ajm-auto-kanban-sled-cab8eb878c6c","generation":"142a715d93df2778","enabled":true,"armedAt":"2026-09-23T00:15:52.395Z","activatedAt":"2026-09-23T00:16:03.422Z","disabledAt":null}}
902e2b1a491a7c8846f7cdf7-SLTE.json: {"status":"active","lease":{"name":"ajm-auto-kanban-slte-902e2b1a491a","generation":"74299c1f799704d7","enabled":true,"armedAt":"2026-09-23T00:15:51.582Z","activatedAt":"2026-09-23T00:16:03.379Z","disabledAt":null}}
```

## Verb attempt (SLEA, sanctioned sequence stop → checkpoint lease_degraded → mark-disabled)

```
$ bun MissionState.ts stop --repo /home/andy/src/cp/osramp-demo --shortcode SLEA --reason "lease_degraded: …"
mission-state: mission digest integrity check failed
$ bun MissionState.ts checkpoint … --event lease_degraded --summary "…"
mission-state: mission digest integrity check failed
$ bun MissionState.ts mark-disabled … --job-name ajm-auto-kanban-slea-3b352918166b
mission-state: mission digest integrity check failed
$ bun MissionState.ts status --repo /home/andy/src/cp/osramp-demo --shortcode SLEA
mission-state: mission digest integrity check failed
```

## Root cause (evidence)

`readState` (MissionState.ts:~420) recomputes `sha256(JSON.stringify(stable(mission)))` and compares it to `.digest`. Every capsule fails because `mission.proposal` was rewritten on 2026-09-23 22:12 BST (SLTE 22:21) — the proposals were renamed to carry the shortcode prefix (and SLTE re-titled) — without recomputing the digest. The sibling `*.json.bak-rename-20260923` files are digest-consistent (`FULL` match) and differ from the live capsules only on `mission.proposal`:

```
--- 3b352918166b4dfa79a35f48-SLEA.json
<   "proposal": "Proposal — Signal Loom On-Demand EAP Environment Routing & Tailscale Provisioning Engine (2026-Q3).md",
>   "proposal": "Proposal — SLEA Signal Loom On-Demand EAP Environment Routing & Tailscale Provisioning Engine (2026-Q3).md",
--- b6db94da0ed18b775266b505-SLET.json
<   "proposal": "Proposal — Signal Loom EAP Tenant Isolation & Cryptographic Identity Engine (2026-Q3).md",
>   "proposal": "Proposal — SLET Signal Loom EAP Tenant Isolation & Cryptographic Identity Engine (2026-Q3).md",
--- f955d574ef08d2f9f3031bab-SLES.json
<   "proposal": "Proposal — Signal Loom EAP Synthetic Scenario & Audit Seeding Engine (2026-Q3).md",
>   "proposal": "Proposal — SLES Signal Loom EAP Synthetic Scenario & Audit Seeding Engine (2026-Q3).md",
--- cab8eb878c6c49259d433c96-SLED.json
<   "proposal": "Proposal — Signal Loom EAP Lifecycle, Heartbeat & Auto-Reaping Daemon (2026-Q3).md",
>   "proposal": "Proposal — SLED Signal Loom EAP Lifecycle, Heartbeat & Auto-Reaping Daemon (2026-Q3).md",
--- 902e2b1a491a7c8846f7cdf7-SLTE.json
<   "proposal": "Proposal — Signal Loom External Webhook Ingestion & Trigger Engine (2026-Q3).md",
>   "proposal": "Proposal — SLTE Signal Loom Inbound Agent Registration Engine (2026-Q3).md",
```

The last logged event in every `<id>-<SC>.jsonl` is `activated` (2026-09-23 00:16:03Z); the 22:12 rewrite appended no event, so it did not go through a MissionState verb.

## After

Unchanged — no verb can open the capsules, so no state was mutated and no JSON was hand-edited (card rule). `lease.enabled` remains `true` on all five; there is no scheduler behind any of them (CronList: "No scheduled jobs"; `crontab -l` and `systemctl --user list-timers` carry no kanban entries).

## Consequence for the D0 objective

No EAP board can relaunch from these capsules: the controller's own read path refuses them before any tick, and no scheduler exists. The sanctioned `lease_degraded` checkpoint could not be written. Recovery is a principal decision: either re-`prepare`/`approve` each mission against the renamed proposal (new digest, new capsule), or add a sanctioned `rename-proposal` verb to MissionState.ts that re-digests under lock and logs the event. Both are outside EAPR-P1-1 (no write access to `~/.andy_sync` this session, and re-approval is Andy's).
