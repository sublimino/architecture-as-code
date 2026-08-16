# Connecting your Azure AD / Entra ID directory to Signal Loom

This guide walks through registering an application in your Microsoft Entra ID
(Azure AD) tenant so Signal Loom can discover non-human identities (service
principals, app registrations, managed identities) in your directory.

## What Signal Loom needs, and why

Signal Loom's NHI (non-human identity) discovery scans your Entra directory
read-only to build an inventory of service principals and their privilege
level, credential age, and rotation status. It needs three Microsoft Graph
**application permissions** (not delegated: this is a background,
unattended scan, not a user-driven one):

| Permission | Why |
|---|---|
| `Application.Read.All` | Enumerate app registrations and service principals |
| `Directory.Read.All` | Resolve directory role assignments and group membership for privilege scoring |
| `AuditLog.Read.All` | Correlate sign-in activity to flag stale/dormant identities |

All three are read-only. Signal Loom never writes to your directory.

## Step 1: Register an application

In the Azure Portal, in **your own** Entra tenant (not Signal Loom's):

1. Go to **Entra ID → App registrations → New registration**.
2. Name it something identifiable, e.g. `signal-loom-nhi-connector`.
3. Supported account types: **Accounts in this organizational directory only**
   (single tenant).
4. No redirect URI needed: this app only uses the client-credentials flow.
5. Click **Register**. Note the **Application (client) ID** and
   **Directory (tenant) ID** from the Overview page: you'll need both.

## Step 2: Grant the 3 Graph API permissions

1. In the new app registration, go to **API permissions → Add a permission →
   Microsoft Graph → Application permissions**.
2. Search for and check:
   - `Application.Read.All`
   - `Directory.Read.All`
   - `AuditLog.Read.All`
3. Click **Add permissions**.
4. Click **Grant admin consent for `<your org>`**: this requires Global
   Administrator or Privileged Role Administrator in your tenant. Confirm the
   consent dialog.
5. Verify all three permissions show a green "Granted" status before moving on.

> If admin consent fails immediately after adding permissions with an error
> mentioning the service principal, wait ~15 seconds and retry: this is a
> known Azure AD replication delay right after an app registration is
> created, not a configuration problem on your end.

## Step 3: Create a client secret

1. Go to **Certificates & secrets → Client secrets → New client secret**.
2. Description: anything identifiable (e.g. `signal-loom-scan-2026`).
3. Expiry: Signal Loom recommends **6 months**, matching our credential
   rotation cadence. Longer-lived secrets increase risk if leaked; shorter
   ones mean more frequent rotation.
4. Click **Add**, then **copy the secret value immediately**: Azure only
   shows it once. If you lose it, you'll need to generate a new one.

## Step 4: Provide credentials to Signal Loom

You'll need three values for the connector setup screen in your Signal Loom
dashboard:

- **Directory (tenant) ID**: from Step 1
- **Client ID**: from Step 1 (the Application/client ID)
- **Client secret**: from Step 3

Signal Loom stores the client secret encrypted; it is never displayed again
after initial entry, and never leaves your tenant's scan pipeline.

## Rotation

Client secrets expire. Before yours does:

1. Repeat Step 3 to create a new secret (you can have two active at once
   during rotation: Azure allows multiple secrets per app).
2. Update the credential in your Signal Loom connector settings.
3. Delete the old secret from Certificates & secrets once the new one is
   confirmed working (next scheduled scan completes successfully).

Signal Loom's dashboard will show a warning when your connector's credential
is within 30 days of expiry.
