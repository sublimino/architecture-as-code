---
title: Support engineer onboarding
description: Trace a failed request through scoped metadata and prepare a safe escalation.
---

Read the [glossary](/dev-docs/reference/glossary/) first. The result is an escalation record, not a repair.

## Prerequisites and limits

The procedure needs a named environment, an approved namespace, scoped read access, and a restricted evidence destination.

WARNING: Do not collect raw logs, request bodies, tokens, or Secret objects.
They can contain customer payloads or credentials.

The [root guide](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/AGENTS.md) recommends `make doctor` for cluster diagnosis.
Its broad report needs owner review before collection or sharing.
This path uses narrower metadata instead.

## Check health

Run these commands from the repository root against the approved context.

1. Check the current context.

   ```bash
   kubectl config current-context
   ```

2. Check dashboard deployment counts.

   ```bash
   kubectl -n fe-signalloom get deployment dashboard-signalloom -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas'
   ```

3. Check the dashboard Service ports.

   ```bash
   kubectl -n fe-signalloom get service dashboard-signalloom -o custom-columns='NAME:.metadata.name,PORT:.spec.ports[*].port,TARGET:.spec.ports[*].targetPort'
   ```

4. Check dashboard endpoint readiness.

   ```bash
   kubectl -n fe-signalloom get endpointslices -l kubernetes.io/service-name=dashboard-signalloom -o custom-columns='NAME:.metadata.name,READY:.endpoints[*].conditions.ready'
   ```

5. Compare the counts with the expected deployment state.

Ready counts show availability metadata. They do not prove authentication, backend access, or enforcement.

## Trace a failed request

The request path crosses the browser, ingress, dashboard proxy, Service, and backend.
The [proxy configuration](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/d2-signalloom/apps/dashboard-signalloom/nginx.conf) defines backend prefixes.

1. Record the route path without its query string.
2. Record the response status and content type.
3. Read the proxy rule for that prefix.
4. Check the named backend Service metadata.
5. Check its EndpointSlice readiness through the Service selector.
6. Record the earliest failed hop.

If scoped pod execution is approved, use this body-free Fleet Manager probe.

```bash
kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- \
  curl --max-time 10 -sS -o /dev/null -w '%{http_code} %{content_type}\n' \
  http://localhost:8080/fleet-api/v1/fleet/topology
```

| Observation | Interpretation | Next check |
| :--- | :--- | :--- |
| `200 application/json` | This route answered with JSON. | Compare the failing browser path. |
| `200 text/html` | A page response can indicate the SPA fallback. | Inspect the proxy prefix. |
| `502` | The upstream request failed. | Check Service and endpoint metadata. |
| `504` | The upstream request timed out. | Review network rules and backend availability. |
| `401` or `403` | Access failed or needs authentication. | Review the approved identity path without tokens. |

A status code alone does not prove the cause. A timeout does not prove a NetworkPolicy denial.
The [slice triage guide](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/d2-signalloom/AGENTS.md#diagnose-backend-service-connections) supplies further context.

## Collect and escalate

1. Record the environment and observation time with timezone.
2. Record the source revision or deployed image digest.
3. Copy only approved metadata fields.
4. Replace sensitive names with stable case aliases.
5. Record each command and its redacted result.
6. Describe user impact without customer content.
7. Send the record to the responsible component owner.
8. Check that the owner accepts the escalation.

Use the [assessment fields](/dev-docs/reference/security-assessment-template/) when the failure concerns a security control.

Stop if diagnosis needs raw logs, broader access, secret reads, or mutation.
Do not restart, patch, reconcile, seed, or delete resources as part of this procedure.
