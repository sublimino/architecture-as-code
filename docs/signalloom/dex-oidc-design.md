# Signal Loom local Dex/OIDC design

<!-- machine-tag: SLDPB25-P1-3-DEX-OIDC-DESIGN-2026-07-27T12:20:00+01:00 -->
<!-- scope: local-demo-design-and-deterministic-contracts-only -->

## Purpose and boundary

The dashboard currently uses Auth0 upstream. For the local Signal Loom demo,
Dex is the deliberately bounded OIDC replacement. It provides dashboard login
metadata and signing keys inside the demo cluster; it does not federate to
Auth0, Entra, or any production identity provider. This document describes the
checked-in local contract, not a production federation design.

Dex is deployed in `inf-signalloom` with in-memory storage and one replica.
That makes its state and signing material ephemeral by design. It is suitable
only for a disposable local demo.

## OIDC provider contract

| Item | Local value | Contract |
| --- | --- | --- |
| Issuer | `http://dex.inf-signalloom.svc.cluster.local:5556/dex` | Exact `iss` value and discovery base. |
| Discovery | `http://dex.inf-signalloom.svc.cluster.local:5556/dex/.well-known/openid-configuration` | Client discovers endpoints from this document. |
| JWKS | `http://dex.inf-signalloom.svc.cluster.local:5556/dex/keys` | Key set named by discovery `jwks_uri`; key rotation follows Dex's ephemeral lifecycle. |
| Dashboard client ID | `signalloom-dashboard` | Public identifier used by the dashboard authorization-code flow. |
| Redirect URI | `http://localhost:5173/callback` | Only registered local callback; no wildcard callback is allowed. |
| API audience scope | `audience:server:client_id:signalloom-api` | Requests an ID token for the compatibility API. |
| Requested scopes | `openid profile email groups audience:server:client_id:signalloom-api` | `openid` is required; presentation claims are not authorization inputs. |

The dashboard client secret is the existing local fixture in `dex.yaml`. It is
named `signalloom-dashboard-local-only`, must never be reused outside this
demo, and must be replaced by externally managed credentials before any hosted
deployment. The literal value is not an application API signing key.

## Demo identity and tenant mapping

Dex has one static local user:

| Field | Value |
| --- | --- |
| Subject (`sub`) | `demo-user` |
| Username | `demo-user` |
| Email | `demo-user@signalloom.local` |
| Password verifier | Checked-in bcrypt hash only |
| Tenant | `tenant-demo` |

The verifier is intentionally not plaintext. A test operator supplies the
corresponding local-demo password out of band; no password value belongs in
this repository, image, test output, or erratum.

For API authorization, `API_SUBJECT_TENANTS` is authoritative:
`demo-user -> tenant-demo`. `OIDC_TENANT_MAPPING` is retained as dashboard
configuration parity but is not read by the portal Python application. The API
derives tenant identity exclusively from a successfully validated `sub`; it
must ignore a client-provided tenant, group, or custom claim. A subject missing
from the server mapping receives `tenant_forbidden`.

## Token and validation contract

An OIDC ID token must contain `iss`, non-empty `sub`, `aud`, `azp`, `iat`, and
`exp`. The dashboard requests a token for `signalloom-api`; Dex issues it with
audience `signalloom-api` and authorized party `signalloom-dashboard`. The API
validates issuer equality, exact resource audience, authorized party,
expiration, and the JWT signature against discovery's JWKS. `email`,
`preferred_username`, and `groups` are optional presentation claims and do not
grant a tenant.

The compatibility API accepts only Dex-issued RS256 ID tokens retrieved from
the configured JWKS endpoint. It maps only a validated `sub` through
`API_SUBJECT_TENANTS`; client tenant, group, and custom claims are ignored.

## Auth test cases

| ID | Layer | Assertion | Expected result |
| --- | --- | --- | --- |
| OIDC-CONTRACT-001 | Unit | Manifest issuer, client, callback, and scopes match this document. | Pass. |
| OIDC-CONTRACT-002 | Unit | Static user has a bcrypt verifier; no plaintext password field exists. | Pass. |
| OIDC-CONTRACT-003 | Runtime | Discovery advertises the configured issuer and JWKS endpoint. | Pass when Docker is available. |
| OIDC-API-001 | API | Valid Dex RS256 ID token for mapped `demo-user` returns `tenant-demo`. | 200. |
| OIDC-API-002 | API | Token lacking `signalloom-api` audience is rejected. | 401 `invalid_token`. |
| OIDC-API-003 | API | Unknown subject is denied without mapping disclosure. | 403 `tenant_forbidden`. |
| OIDC-API-004 | API | Forged tenant claim cannot override server subject mapping. | 200 for mapped tenant only. |
| OIDC-RUNTIME-001 | Runtime | Dex starts and serves discovery plus non-empty JWKS. | Pass when Docker is available. |
| OIDC-BROWSER-001 | Deferred | Browser login, callback, nonce, expiry, and logout complete. | Not covered by this card. |

`d2-signalloom/test/dex-auth.bats` covers the static unit contract;
`d2-signalloom/test/dex-runtime.bats` covers the optional disposable Dex runtime
endpoints; and `src/tests/test_api_compat.py` covers API bearer authorization.
None issues a demo password, uses a production credential, or asserts a live
Auth0/Dex-to-API trust chain.
