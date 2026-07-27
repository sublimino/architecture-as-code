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

## Update — end-to-end local login enablement (2026-07-27)

<!-- machine-tag: SLDPB25-P2-LOGIN-ENABLEMENT-2026-07-27 -->

The sections above describe the *contract-level* design (P1-3 / P2-3), which was
validated with unit and contract tests only. Enabling a real, browser-driven
`demo-user` login against the migrated dashboard required the following bounded,
local-demo-only changes. Each is a deliberate divergence with its rationale.

### Issuer is now browser-reachable

| Item | New local value |
| --- | --- |
| Issuer (`iss`) | `http://localhost:5173/dex` |
| Discovery / auth / token / JWKS (browser) | `http://localhost:5173/dex/{.well-known/openid-configuration,auth,token,keys}` |
| JWKS fetch (API, in-cluster) | `http://dex.inf-signalloom.svc.cluster.local:5556/dex/keys` |

The dashboard is served single-origin behind a port-forward at `localhost:5173`;
its nginx proxies `/dex` → the in-cluster Dex service and `/api` → the
compatibility API, so the browser reaches every OIDC endpoint at one origin
(no CORS). Dex's issuer is therefore set to `http://localhost:5173/dex`.
This creates an intentional **split-horizon**: the browser and the API both
validate the `iss` string `http://localhost:5173/dex`, while the API *fetches*
JWKS from the cluster-internal service URL (`API_JWKS_URL` is decoupled from
`API_JWT_ISSUER`). The port `5173` is load-bearing — the redirect URI and issuer
are pinned to it.

### Dashboard is a public PKCE client

`signalloom-dashboard` is now a **public client** (`public: true`, no secret).
A single-page app cannot hold a confidential secret, so the authorization-code
flow uses **PKCE (S256)** and no client secret is embedded in the image or repo.
Cross-client audience for `signalloom-api` is unchanged (`trustedPeers`).

### Demo password is a checked-in bcrypt hash

For a self-verifying local demo the password is now `demo-user`, stored as a
bcrypt hash in `dex.yaml` (`$2b$…`). This is a **local-demo-only** credential;
it must never be reused and must be replaced by externally managed credentials
before any hosted deployment. The dashboard requests it via the standard flow;
no plaintext password appears in test output or image layers.

### Subject mapping keys on the real Dex `sub`

Dex emits `sub` as its connector-encoded identifier (a base64 protobuf of
`userID` + connector), e.g. `CglkZW1vLXVzZXISBWxvY2Fs` for `demo-user`/`local` —
**not** the raw `demo-user`. `API_SUBJECT_TENANTS` therefore maps the actual
encoded `sub` → `tenant-demo` (the readable `demo-user` key is retained for
clarity). The server still derives tenancy *only* from the validated `sub`.

### JWT header `typ` is optional

Dex ID tokens omit the `typ` header. The API validator previously required
`typ == "JWT"` and so rejected every real Dex token (it had only been
contract-tested against synthetic tokens). It now accepts an **absent** `typ`
while still rejecting a present-but-wrong one; `alg == RS256` remains mandatory.

### Browser login is now covered

`OIDC-BROWSER-001` is no longer deferred: `test/acceptance/signalloom-login.spec.ts`
drives the full port-forward → Dex login → `demo-user`/`demo-user` → dashboard
flow in real Chrome and asserts the dashboard renders with authenticated `/api`
data and no console/API errors.

### Dex liveness probe

With a path-based issuer (`…/dex`), Dex serves health under the issuer path, so
the bare `/healthz` liveness probe 404s and crash-loops the pod. The liveness
probe now targets a served path (`/dex/.well-known/openid-configuration`).
