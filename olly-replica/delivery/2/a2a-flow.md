# A2A identity chain: COIN + PlainID + EEMS

## Terms

- **PlainID PDP** (Policy Decision Point): evaluates Rego policy at token issuance and returns the permitted actions.
- **EEMS**: the entitlement store. Holds per-user attributes (`has_<action>_access`, `max_<action>_limit`, `gp_numbers`, `approved_domains`).
- **PIP** (Policy Information Point): the role EEMS plays. The PDP calls it for the attributes it needs to decide.

## The model

- COIN token exchange carries the user's internal ACME id through every hop (H2M -> M2M).
- PlainID PDP evaluates Rego at token issuance, calling EEMS as a PIP for entitlement attributes.
- AuthZ-CTX propagates across A2A hops (agent-a -> agent-b), narrow-only (a hop can drop or lower an action, never add one).
- One `authz_ctx_id` answers "who authorized this?" in a single audit query.

## Step by step

1. **Human / Scheduler** presents its ACME id and requests an H2M COIN token.
2. **COIN token exchange** (OAuth2 grant, H2M -> M2M-enhanced) at the **Mock COIN JWT Issuer `:8001`**: issues the M2M-enhanced token with `username = ACME id` preserved, and calls the PDP. **[OBO]** the human stays the token subject and the agent is the actor, so every downstream call reads as "agent, on behalf of ACME id."
3. **PlainID PDP `:8002`**, called synchronously at issuance: Rego policy evaluation, calls EEMS as the PIP, derives `permitted_actions`, embeds them in the JWT.
4. **EEMS PIP REST `:8003`**: attribute fetch, returns `has_<action>_access`, `max_<action>_limit`, `gp_numbers`, `approved_domains`.
5. **PlainID-enriched COIN JWT** returned to the caller.
6. **agent-a `:8080`** holds `<action>/limit`, creates the **AuthZ-CTX**, gates every tool with `@requires_permissions` (MCP scopes AuthZ `:9001`, `<action>` `:9002`, EEMS-PIP `:9003`). **[Agent card]** the card at `/.well-known/agent-card.json` declares the schemes a caller authenticates with (COIN M2M, and the AuthZ-CTX header on the hop), so auth is discoverable and versioned instead of hardcoded.
7. **A2A hop**: a true A2A `message/send` carries the **`X-AuthZ-CTX`** header to the next agent, with `permitted_actions` intersected (narrow-only, never widened). **[A2A]**
8. **agent-b `:8090`** takes `<action>/<role>`, retrieves the AuthZ-CTX, and re-validates it independently (MCP scopes AuthZ `:9011`, `<action>` `:9012`, EEMS-PIP `:9013`).
9. One **`authz_ctx_id`** anchors the entire chain.
10. **Jarvis audit log** (OTel -> Splunk): ACME id, PlainID policy, EEMS attributes, PERMIT/DENY, agent chain, and timestamp, all linked by that one id.

## In the delivered replica

agent-a is `olly-sentinel`, agent-b is `orbit`, and the COIN / PlainID / EEMS trio is the in-cluster `olly-authz` service. The `agent-card.*.v1.json` files here declare `coin_m2m` (the M2M identity), `authz_ctx` (the `X-AuthZ-CTX` header the receiving agent enforces and narrows), and `approval_jwt` (the signed HITL approval).
