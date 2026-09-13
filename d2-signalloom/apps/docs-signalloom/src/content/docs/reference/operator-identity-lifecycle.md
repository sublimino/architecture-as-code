---
title: Attributable Operator Lifecycle & Identity
description: Operator identity management, session authorization, and negative shared-identity rejection in Signal Loom.
---

Signal Loom enforces strictly attributable operator lifecycle management for partner organizations (such as AgentMaxxing Incorporated). Operators represent real human individuals responsible for registering, managing, and governing agents.

## Architectural Principles

1. **Individual Identity Binding**: Every operator account binds an immutable OpenID Connect (OIDC) `(issuer, subject)` pair to a single directory user. Generic, shared, automated, or anonymous accounts are strictly rejected.
2. **Server-Owned Tenant Derivation**: Tenant scope is derived exclusively from server-side verified principal mapping (`API_SUBJECT_TENANTS` / `API_ATTRIBUTABLE_OPERATOR_TENANTS`). Callers cannot supply or spoof tenant identifiers in request payloads.
3. **Fail-Closed Shared & Anonymous Rejection**: Request models validate `identity_kind == 'individual'`. Shared credential attempts return `403 Forbidden` with error code `shared_identity_forbidden`.
4. **Immediate De-Provisioning & Revocation**: Removing an operator transitions the identity status to `removed` and deactivates the user. Active tokens are immediately refused by server-side strict tenant gates.
5. **Attributable Audit Trail**: All lifecycle actions (creation, sign-in success/denial, removal) generate immutable audit records in `audit_events` with actor UUID, issuer, and subject attribution.

## API Endpoints

### 1. Authenticate / Retrieve Operator Session

- **Method**: `GET`
- **Path**: `/api/operator-identities/session`
- **Authentication**: OIDC Bearer Token
- **Responses**:
  - `200 OK`: Returns authenticated operator profile and allowed actions (`OperatorSessionResponse`).
  - `401 Unauthorized`: Missing or invalid authentication (`authentication_required`, `anonymous_operator_forbidden`).
  - `403 Forbidden`: Account is inactive, removed (`operator_removed`), or shared (`shared_identity_forbidden`).
  - `503 Service Unavailable`: Identity database unavailable.

### 2. Provision Operator Identity

- **Method**: `POST`
- **Path**: `/api/operator-identities`
- **Authentication**: OIDC Bearer Token (requires `admin` role or initial self-bootstrap)
- **Request Body** (`OperatorIdentityCreateRequest`):
  - `provider_subject` (string, required): Unique subject identifier from OIDC provider.
  - `email` (string, required): Individual email address.
  - `display_name` (string, required): Human-readable name.
  - `role` (`admin` | `editor` | `viewer`, default: `editor`): Role assignment.
  - `identity_kind` (`individual`, constant).
- **Responses**:
  - `201 Created`: Returns created operator record.
  - `403 Forbidden`: Non-admin caller or unmanaged tenant.
  - `409 Conflict`: Identity already exists.

### 3. List Tenant Operators

- **Method**: `GET`
- **Path**: `/api/operator-identities`
- **Authentication**: OIDC Bearer Token (requires `admin` role)
- **Responses**:
  - `200 OK`: Returns list of operators in the caller's tenant (`OperatorIdentitiesResponse`).
  - `403 Forbidden`: Caller lacks administrator role.

### 4. Remove / De-provision Operator

- **Method**: `POST`
- **Path**: `/api/operator-identities/{identity_id}/remove`
- **Authentication**: OIDC Bearer Token (requires `admin` role)
- **Request Body** (`OperatorIdentityRemovalRequest`):
  - `reason` (string, required): Explanation for de-provisioning (minimum 3 characters).
- **Responses**:
  - `200 OK`: Returns removed operator record with removal metadata (`OperatorRemovalResponse`).
  - `404 Not Found`: Target operator identity not found.
  - `409 Conflict`: Attempting to remove the last remaining active administrator (`last_operator_admin`).

## Role Authorization Matrix

| Role | Sign In (`operator:sign-in`) | List Operators (`operator:list`) | Create Operator (`operator:create`) | Remove Operator (`operator:remove`) |
| :--- | :---: | :---: | :---: | :---: |
| `admin` | Allow | Allow | Allow | Allow |
| `editor` | Allow | Deny | Deny | Deny |
| `viewer` | Allow | Deny | Deny | Deny |
| Removed / Inactive | Deny | Deny | Deny | Deny |

## Audit Event Types

| Lifecycle Action | Event Type | Outcome Detail |
| :--- | :--- | :--- |
| Operator Provisioning | `operator.created` | `operator.create` (completed) |
| Successful Sign-in | `operator.sign_in_succeeded` | `operator.sign_in` (allowed) |
| Denied Sign-in | `operator.sign_in_denied` | `operator.sign_in` (denied) |
| Operator Removal | `operator.removed` | `operator.remove` (completed) |
