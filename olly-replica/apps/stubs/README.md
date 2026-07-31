# Pipeline stubs (built: `apps/cmd/mapping-stub`, `apps/cmd/replay-producer`)

Small services that carry the routing contract, not business logic. Both
ship in the `olly/stubs` image (persisted in the in-cluster Zot registry as
`zot.registry.svc.cluster.local:5000/acme/images/olly/stubs:latest`).

- **replay-producer** (`/replay-producer` in the image): emits one
  synthetic Netcool/BigPanda-style event onto `netcool.io.events` with
  source `replay`, validated against
  `contracts/eligible-event.v1.schema.json` before publishing. It refuses
  to emit a drifted payload. Run one through the pipeline with
  `make -C olly-replica replay`.
- **io-mapping-service stub** (the image entrypoint): three duties.
  *Subscription gate*: events for apps outside `SUBSCRIBED_APPS` end the
  flow ("raw incident raised"). *Routing*: eligible events are declined
  (the replica declines everything so the Olly branch always exercises) and
  published to the IO-Declined topic. *Writing*: it consumes the
  `event_response` topic and is **the only component that writes to
  ServiceNow**. Every payload is validated against
  `contracts/rca-enrichment.v1.schema.json` first (a spoofed or malformed
  payload is dropped and counted, never written), then the ticket is
  updated: the in-memory store (HTTP `GET /incidents/{correlation-id}`) is
  the stand-in and the test suite's assertion surface. Once the ServiceNow
  PDI is provisioned, put its credentials in a local `.env` (gitignored) and
  let make create the secret, no code or manifest change:

  ```bash
  cp .env.example .env    # fill in SERVICENOW_URL / SERVICENOW_USER / SERVICENOW_PASSWORD
  make olly-pdi-secret    # creates the servicenow-pdi secret, restarts the stub
  ```

Olly Sentinel never holds the write path; that separation is deliberate.
