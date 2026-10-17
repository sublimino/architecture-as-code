# Connecting Anthropic Claude to Signal Loom

This guide walks through giving Signal Loom an Anthropic API key so it can
discover the managed agents and models visible to that key.

## What Signal Loom reads, and why

Signal Loom keeps the connector in sync continuously (every 30 seconds by
default) and on demand when you press **Scan**. It makes read-only requests to
the Anthropic API with the stored key, and nothing else:

| Request | Why it matters |
|---|---|
| `GET https://api.anthropic.com/v1/agents` (managed agents beta) | Lists the managed agents the key can see, archived ones included: these are the non-human workloads Signal Loom tracks |
| `GET https://api.anthropic.com/v1/sessions` (managed agents beta) | Lists the agent sessions and their status (running, idle, terminated) |
| `GET https://api.anthropic.com/v1/sessions/{id}/events/stream` | Followed only while a session is running, so a status change shows within seconds |
| `GET https://api.anthropic.com/v1/models` | Lists the models available to the key (on a manual scan) |

Every request carries the `anthropic-workspace-id` header when a Workspace ID
is configured (see Step 2).

What the scan reports back:

- **Agents** and **Sessions**: the number returned by `/v1/agents` and
  `/v1/sessions`, only when every page of that listing was read. An agent or
  session the provider stops listing is marked gone, never deleted.
- **Models**: the number of models returned by `/v1/models`, only when that
  request succeeded.
- **Environments, tools and policy results**: not observed. The Anthropic
  API offers nothing the connector reads for these, so Signal Loom shows them
  as "not observed" rather than as zero.

If one request fails, the scan is reported as a **warning**. If both
fail or no key is stored, it is reported as an **error**. The scan logs
show which request failed. Signal Loom never substitutes sample data for
a failed scan.

> **Not used in this version:** the optional **Admin API Key** field is stored
> with the connector but no request uses it yet. Message batches are not read,
> whatever the permission list on the setup screen suggests.

## Step 1: Create an API key

1. Sign in to the [Anthropic Console](https://console.anthropic.com/).
2. Go to **Settings → API keys** and click **Create key**.
3. Pick the workspace whose agents you want Signal Loom to see, and name the
   key something identifiable (e.g. `signal-loom-connector`).
4. **Copy the key immediately**: the Console only shows it once. It starts
   with `sk-ant-`.

Anthropic API keys are not scoped to read-only operations: any key can also
send messages and spend credits. Create a dedicated key for Signal Loom so you
can revoke it without affecting anything else.

## Step 2: Provide credentials to Signal Loom

On the connector setup screen in your Signal Loom dashboard:

- **Anthropic API Key**: from Step 1. This is the only credential a scan uses.
- **Workspace ID**: **required if the key is organisation-scoped** (not tied
  to one workspace). Anthropic refuses requests from such a key unless
  the request names the workspace. Signal Loom sends it as the
  `anthropic-workspace-id` header on every call. Find it in **Console →
  Settings → Workspaces** (it starts with `wrkspc_`). A key created inside a
  workspace does not need it. Without it, **Test** and **Scan** report
  `workspace_required`: "This Anthropic key is organisation-scoped: enter the
  Workspace ID (Console → Settings → Workspaces) and test again."
- **Admin API Key** (optional): stored, not used.

Signal Loom stores the key encrypted. It is never displayed again after
initial entry.

## What you see after a scan

- **Settings → Connectors** shows the connector as **Synced** once a scan has
  run, and **Not yet scanned** before that.
- **See Log** shows one entry per request the scan made. Endpoint, status code
  and response details are visible to superadmins only.
- **View Environment** shows the connector record and the last scan's counts.
  Credit balance, network egress settings and policy results are not available
  from the Anthropic API and are not shown.

## Rotation

Anthropic API keys do not expire automatically. Rotate this key on a
**180-day** cadence. Create a new key, update it in connector settings,
and revoke the old key.
