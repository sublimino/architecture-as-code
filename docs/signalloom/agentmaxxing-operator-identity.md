# AgentMaxxing operator identity and removal contract

**Contract:** AMXO-P1-1
**Version:** 1.0.0
**Approved by:** Andrew Martin
**Approval evidence:** the AMXO-P1-1 implementation task contract dated 2026-09-12

## Approved identity decision

AgentMaxxing operators use an individually attributable OIDC identity. The
canonical key is the exact `(issuer, subject)` pair from a JWT that Signal Loom
has cryptographically validated. The issuer is server configuration, not a
request field. The subject binds globally to one tenant directory user through
`operator_identities`; it cannot be reused for another tenant.

Provisioning requires the person's individual mailbox, display name, and
immutable provider subject. Signal Loom does not seed or invent a partner
person. The first real AgentMaxxing operator remains unprovisioned until those
attributes arrive through the authenticated provisioning route. Test identities
under the reserved `.example` domain are fixtures only and are not partner
approval evidence.

Shared role accounts and anonymous credentials are prohibited. A create request
can express only `identity_kind=individual`; any shared or anonymous value fails
Pydantic validation. Authentication independently checks the persisted kind so
a legacy or malformed shared row also fails closed. Missing JWT subjects fail
at the existing bearer-token boundary.

Tenant scope is derived from `API_SUBJECT_TENANTS` after JWT verification. No
operator lifecycle request model contains a tenant, actor, timestamp, or audit
outcome field. Extra fields are rejected.

## Approved authorization matrix

The existing constrained `platform_users.role` values are authoritative for
the partner operator routes.

| Role | Sign in | List operators | Create operator | Remove operator |
| :--- | :---: | :---: | :---: | :---: |
| `admin` | Allow | Allow | Allow | Allow |
| `editor` | Allow | Deny | Deny | Deny |
| `viewer` | Allow | Deny | Deny | Deny |
| Unregistered, inactive, shared, anonymous, removed | Deny | Deny | Deny | Deny |

The one-time bootstrap path is server-side only: a configured Signal Loom
superadmin may create its own individual issuer-subject binding as `admin` only
while the tenant has zero active administrators. Once an active administrator
exists, persisted role authorization governs every lifecycle operation. A
tenant-keyed transaction advisory lock serializes bootstrap and administrator
removal decisions so concurrent requests cannot create competing initial
administrators or remove the final active administrator.

Strict partner tenants are listed in `API_ATTRIBUTABLE_OPERATOR_TENANTS`. Every
compatibility API request from one of those tenants checks active persisted
operator membership before its handler runs. Removal therefore denies later API
access even while an old, otherwise-valid OIDC token remains unexpired.

## Attributable audit model

Lifecycle actions append to the existing server-owned `audit_events` table.
The application writes `actor_user_id`, `actor_issuer`, and `actor_subject`; the
database supplies the event timestamp. The existing human-readable `actor`
value remains for display compatibility, but immutable identifiers are the
attribution authority.

Events use the existing checked vocabulary:

| Operator outcome | Audit event type | Server detail action |
| :--- | :--- | :--- |
| Provisioned | `operator.created` | `operator.create` |
| Sign-in accepted | `operator.sign_in_succeeded` | `operator.sign_in` |
| Sign-in denied | `operator.sign_in_denied` | `operator.sign_in` |
| Removed | `operator.removed` | `operator.remove` |

The client cannot submit audit events. Removal reasons are retained on the
operator record as authenticated administrator input; the audit event records
only the server-observed transition and target identifiers.

## Removal and de-provisioning workflow

**Accountable owner:** Andrew Martin.
**Operational executor:** an active AgentMaxxing `admin` operator.

1. Confirm an active successor before removing the final administrator.
2. Submit the target identity UUID and a non-empty removal reason.
3. Signal Loom serializes tenant administration, then locks actor and target rows.
4. Signal Loom marks the identity `removed` and the directory user `deactivated`.
5. Signal Loom records removal time, administrator user UUID, and reason.
6. Signal Loom appends the attributable `operator.removed` audit event.
7. The transaction commits the lifecycle change and audit row together.
8. Subsequent sign-in or compatibility API access fails with `operator_removed`.

Removal never deletes the directory user, OIDC binding, role history, or audit
history. Repeating an already completed removal returns the existing removed
record without a second state transition. Restoring a removed identity is not
part of P1-1; a fresh reviewed lifecycle decision is required.

## Runtime and privacy boundaries

This implementation reads identity metadata only. It does not inspect customer
file contents, process memory, streamed payloads, network payloads, or external
partner infrastructure. It does not alter the Go signed-session verifier.

The SQL upgrade is additive migration `038_operator_identities.sql`; historical
migration `008_platform_users.sql` remains unchanged so already-initialized
databases receive the new contract deterministically.
