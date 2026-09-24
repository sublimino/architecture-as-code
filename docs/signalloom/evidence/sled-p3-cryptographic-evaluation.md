# SLED-P3-GOV cryptographic shredding evaluation

**Verdict: NOT VERIFIED.** Date: 2026-09-22, America/Chicago.

The inspected integration tree has no established delivered SLED Stage 3 key
destruction implementation. `scripts/eap/build_sled_specs.py:540–571` is a card
specification, not a cryptographic erasure implementation. The tenant helper
`tenant_isolation.py:229–237` only sets an in-memory active flag to false.
Neither action destroys encryption material.

Canonical identity was executed, not inferred from prose:

```text
derive_customer_hash('kurasi') = 6f82ad81
derive_customer_hash('kusari') = 4b53ab6b
```

This card targets `kurasi`, namespace/key name `eap-6f82ad81`, workload identity
`spiffe://osramp.local/ns/eap-6f82ad81/sa/tenant-app`, and transit path
`transit/keys/eap-6f82ad81`. Other proposal artifacts spell the company `kusari`;
those are not interchangeable identities.

| Assertion | Evidence required | Result |
| --- | --- | --- |
| Transit key permanently destroyed rather than archived | Inspect deletion authorization/configuration and actual destroy operation | No eligible implementation established |
| Subsequent key metadata read returns HTTP 404 | Before/after calls using an authorized synthetic key and correct mount | Not executed |
| Prior ciphertext cannot be decrypted | Known synthetic ciphertext and failed post-destruction decrypt | Not executed |
| Historical versions cannot recover material | Version inventory, export/backup policy, restore-path assessment | Not verified |
| SPIRE entries removed before volume release | Targeted identity inventory and successful pruning postcondition | Not verified |
| Failure blocks namespace/PV deletion | Fault-injected key/identity failure in the complete pipeline | Not run; complete pipeline unavailable |

Even an authenticated 404 alone proves only path absence on the queried endpoint,
not elimination of exports, backups, replicas, snapshots, cached data keys, or
plaintext previously written to host storage. The shredding claim must state its
actual threat model and retention boundary. No encryption keys or credentials
were fetched or logged by this governor; no shared key was destroyed.
