# Connecting your OpenAI org to Signal Loom

This guide walks through creating an Admin API key in your OpenAI
organization so Signal Loom can discover non-human identities: API keys,
service accounts, and project-scoped credentials: across your org.

## What Signal Loom needs, and why

OpenAI's Admin API exposes org- and project-level credential objects that
are a direct fit for NHI discovery:

| Object type | API | Why it matters |
|---|---|---|
| Org Admin API keys | `/v1/organization/admin_api_keys` | Org-owner-level credentials: the same class of key this connector itself uses, and the highest-privilege NHI class in an OpenAI org |
| Project API keys | `/v1/organization/projects/{id}/api_keys` | Credentials scoped to a single project |
| Project service accounts | `/v1/organization/projects/{id}/service_accounts` | Automation identities scoped to a single project |

> **Not scanned in this version:** org members
> (`/v1/organization/users`) are not scanned: that endpoint returns human
> account records, and there's no reliable field distinguishing a
> bot-driven member from a person, so it's left out rather than guessed at.
> There is also no separate "org-level service account" object in OpenAI's
> model: service accounts exist only inside a project.

The connector uses a single Admin API key. Admin keys are org-wide and
read/write over the Admin API surface: there is no read-only admin key
type in OpenAI's platform today, so use an account with the narrowest org
role available when creating it.

## Step 1: Create the Admin API key

1. Sign in to the [OpenAI platform dashboard](https://platform.openai.com/).
2. Go to **Organization → API keys**, then the **Admin keys** tab (distinct
   from the regular **API keys** tab: a project API key will not work
   here).
3. Click **Create new admin key**, name it something identifiable (e.g.
   `signal-loom-nhi-connector`), and confirm.
4. **Copy the key value immediately**: OpenAI only shows it once. It will
   start with `sk-admin-`.

## Step 2: Provide credentials to Signal Loom

You'll need these values for the connector setup screen in your Signal Loom
dashboard:

- **OpenAI Admin API Key**: from Step 1. Must start with `sk-admin-`.
- **Organization ID** (optional): e.g. `org-xxxxxxxx`, for your own
  reference. OpenAI's Admin API has no endpoint to look up or verify an org
  ID, so this is stored but not checked against anything.

Signal Loom stores the key encrypted; it is never displayed again after
initial entry.

## What gets scanned

- Every **org-level Admin API key**, flagged if it has never been used or
  is expiring soon (Admin keys can optionally be created with an expiry).
- Every **project-scoped API key**, flagged if it has never been used.
- Every **project-scoped service account**, flagged if it holds the
  project's `owner` role.
- All of the above across every active project in your org.

Org member (human) accounts are not scanned by this connector.

## Rotation

OpenAI Admin API keys don't expire on a fixed schedule and can be revoked
manually at any time from the same **Organization → API keys → Admin keys**
screen. Since there's no server-enforced expiry for Signal Loom to detect
and surface automatically, we recommend rotating this key on a **180-day**
cadence as a matter of practice: create a new key, update it in your
Signal Loom connector settings, then revoke the old one once the next scan
completes successfully.
