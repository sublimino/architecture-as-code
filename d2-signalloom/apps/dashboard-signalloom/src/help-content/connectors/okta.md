# Connecting your Okta org to Signal Loom

This guide walks through creating a read-scoped API token in your Okta org
so Signal Loom can discover non-human identities: API service integrations
and federated identity providers: in your Okta directory.

## What Signal Loom needs, and why

Okta doesn't have a first-class "non-human identity" concept the way Entra
has service principals. Signal Loom's Okta connector scans two object types
that are the closest real equivalent:

| Object type | API | Why it matters |
|---|---|---|
| API Service app integrations | `/api/v1/apps` | Okta's machine-to-machine credential: apps using the `client_credentials` OAuth grant, not a human sign-in flow |
| Federated identity providers | `/api/v1/idps` | Trust relationships with external IdPs (SAML/OIDC/social): a different kind of non-human trust surface, not a credential your org issued |

> **Not scanned in this version:** Okta has no queryable "service account"
> user flag (there's no `SERVICE_ACCOUNT` user type in Okta's model) and no
> API endpoint to list org-wide API tokens: both would require guessing at
> conventions specific to your org, so they're left out rather than
> half-supported. If per-token visibility matters to you, let us know.

The connector uses a single read-scoped API token: Okta API tokens inherit
whatever permissions the creating admin's own role has, rather than a
separately configurable scope, so use an account with the narrowest role
that can still read users/apps/IdPs (typically a custom read-only admin
role, or Super Admin if that's what's available).

## Step 1: Create the API token

1. Sign in to your Okta admin console (`https://<your-org>-admin.okta.com`).
2. In the left sidebar, go to **Security → API**, then the **Tokens** tab.
3. Click **Create token**, name it something identifiable (e.g.
   `signal-loom-nhi-connector`), and confirm.
4. **Copy the token value immediately**: Okta only shows it once. (The
   token list will afterward only show a **Token ID** for reference: that's
   not the secret value and can't be used to re-derive it.)

## Step 2: Provide credentials to Signal Loom

You'll need two values for the connector setup screen in your Signal Loom
dashboard:

- **Okta Domain**: your org's admin domain, e.g. `acme.okta.com`
  (custom domains aren't supported yet: use the default `*.okta.com` /
  `*.oktapreview.com` / `*.okta-emea.com` domain).
- **API Token**: from Step 1.

Signal Loom stores the token encrypted; it is never displayed again after
initial entry.

## What gets scanned

- Every **API Service** app integration in your org, flagged if it isn't
  using the expected `client_credentials` grant.
- Every **federated identity provider**, flagged if it isn't in an `ACTIVE`
  status.

User accounts (human or otherwise) are not scanned by this connector.

## Rotation

Okta API tokens don't expire on a fixed schedule by default and can be
revoked manually at any time from the same **Security → API → Tokens**
screen. Since there's no server-enforced expiry for Signal Loom to detect
and surface automatically, we recommend rotating this token on a **90-day**
cadence as a matter of practice: create a new token, update it in your
Signal Loom connector settings, then revoke the old one once the next scan
completes successfully.
