# Dex Connectors — Signal Loom Identity Federation

Signal Loom uses [Dex](https://dexidp.io/) as an OIDC federation hub. The base
deployment includes a local password database for demos. Production deployments
add one or more upstream identity connectors via the connectors overlay.

## Supported connectors

| Connector | Dex type | Use case |
| :---- | :---- | :---- |
| Local password | `enablePasswordDB` | Demo/dev — always available in the base config |
| Microsoft Entra ID | `microsoft` | Azure AD / Entra ID SSO (most enterprise banks) |
| Generic OIDC | `oidc` | Okta, Auth0, Keycloak, PingFederate, any OIDC provider |
| Google Workspace | `google` | Google-backed orgs, `hostedDomains` scoping |
| GitHub | `github` | Developer/OSS access, org + team filtering |

## Enabling remote connectors

1. Copy `overlays/connectors/dex-connectors-secret.yaml`
2. Replace all `REPLACE_WITH_*` placeholders with real IdP credentials
3. Apply the overlay:

```bash
kubectl kustomize d2-signalloom/infra/inf-signalloom/overlays/connectors \
  | kubectl apply -n inf-signalloom -f -
```

Each connector requires an OAuth app registration in the upstream IdP with the
redirect URI set to `https://<dashboard-host>/dex/callback`.

## Connector registration per IdP

### Microsoft Entra ID

1. Azure Portal → App registrations → New registration
2. Redirect URI: `https://dashboard.osramp.acme.local:30754/dex/callback`
3. Certificates & secrets → New client secret
4. API permissions: `openid`, `profile`, `email`
5. Copy Application (client) ID, Directory (tenant) ID, and client secret value

### Google

1. GCP Console → APIs & Services → Credentials → Create OAuth client ID
2. Application type: Web application
3. Authorised redirect URI: `https://dashboard.osramp.acme.local:30754/dex/callback`
4. Copy client ID and client secret

### GitHub

1. GitHub → Settings → Developer settings → OAuth Apps → New OAuth App
2. Authorization callback URL: `https://dashboard.osramp.acme.local:30754/dex/callback`
3. Copy Client ID and Client Secret
4. Optionally restrict to specific orgs/teams in the connector config

### Generic OIDC

1. Register an OAuth2/OIDC application in your provider
2. Set the redirect URI to `https://dashboard.osramp.acme.local:30754/dex/callback`
3. Note the issuer URL, client ID, and client secret
4. Verify that `/.well-known/openid-configuration` is reachable from the cluster

## Login flow

When multiple connectors are active, Dex renders a connector-picker page
(the Signal Loom-branded `login.html` template) with "Sign in with …" buttons
for each connector, plus the local password form. The user picks their IdP,
authenticates there, and is redirected back through Dex to the dashboard at
`/callback` → `/agents`.

## UI customisation

The login UI is Signal Loom-branded via the `dex-ui` ConfigMap
(`dex-ui.yaml`), mounted as Go HTML templates and a CSS theme. To iterate
locally:

```bash
# Edit the ConfigMap
vi d2-signalloom/infra/inf-signalloom/base/dex-ui.yaml

# Apply and restart
kubectl apply -n inf-signalloom -f d2-signalloom/infra/inf-signalloom/base/dex-ui.yaml
kubectl rollout restart -n inf-signalloom deploy/dex
```

Templates use Go `html/template` syntax. The form field names (`login`,
`password`) and action URLs (`{{ .PostURL }}`) are Dex conventions and must
not be changed.
