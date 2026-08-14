# Streaming the instructor log

> Living documentation. The argument is made in full in the comment block at the top of
> `d2-signalloom/apps/dashboard-signalloom/src/api/demoRunner.ts`; this file is the
> operator-facing summary of it.

The SuperCred instructor panel shows the output of a privileged demo phase while it is
still running. The failure this whole area exists to prevent is a **blank log on stage**,
and every decision below follows from that.

## Two transports, and which one you get

**A waiting read, by default.** `GET …/log?wait=` is a long poll: it parks until there are
bytes past your offset, the run reaches a terminal state, or the deadline passes. This is
what turns the log from a poll with a half-interval latency floor into something that
delivers within milliseconds of the producer emitting. A wait that expires is a normal
empty read, not an error.

Two details in `demo_runner.py` that are less obvious than they look:

* Waiters are woken when a run **ends**, not only when it produces output. Missing that is
  the subtle half — the last thing a phase does is exit, not print, so a waiter woken only
  by output would sit out its whole deadline at the end of every single phase.
* The buffer test and the park happen under the same lock the writer takes, which is why
  `_log_changed` is a `Condition` over `run._lock` rather than a bare `Event`. Between "is
  there anything new?" and "wait" there is no window in which a notify can be delivered
  and lost.
* Concurrent `wait=` calls are capped well under anyio's default thread limiter, so parked
  waiters can never be the reason a control-plane call has no thread to run on. The real
  load is one instructor with a handful of tabs; the cap exists for the abandoned ones,
  which a browser produces every time a tab is closed mid-wait.

**SSE, opt-in only.** `GET /demo-api/runs/{id}/stream` pushes the same chunks as they are
written. It is real and it is tested. It is deliberately not the default:

```
?logTransport=sse                                  # one demo, no residue
localStorage['signalloom.logTransport'] = 'sse'    # sticky for a machine
```

There is no UI for this and there should not be. An instructor picking a transport
mid-demo is making a decision they have no way to evaluate.

## Why SSE lost

Its characteristic failure produces exactly the outcome the panel exists to avoid, with no
error to react to. Any intermediary that buffers — nginx (`proxy_buffering` is on by
default and the `/demo-api/` block does not turn it off), a Kubernetes Gateway compressor
filter, ngrok, venue wifi running a transparent proxy — accepts the connection, answers
the headers, and then holds every byte until the response completes. Nothing errors.
`onerror` never fires. The log sits empty for the length of the phase and the panel has no
way to know.

A waiting read cannot fail that way. It is an ordinary short response, so a buffering
proxy has nothing to hold.

Because the error will not come, the SSE path carries a **first-byte watchdog** instead of
trusting one: a proxy holding the response produces zero bytes, while a healthy connection
produces the runner's banner or its keepalive comment, so silence past a short deadline is
the buffering detector.

## Two implementation constraints worth knowing

**`fetch()`, not `EventSource`.** `EventSource` cannot set a request header. Authenticating
it would mean putting the bearer token in the query string — into the nginx access log,
into every proxy log in between, and into the browser's own history, three places that
outlive the session the token belongs to. It also cannot send
`ngrok-skip-browser-warning`, which the free tier requires and which is how the demo gets
published. The cost of `fetch()` is framing the byte stream by hand.

**Frames are JSON, always.** SSE treats a bare CR as a line terminator, so raw text in a
`data:` field would be silently mangled by any progress bar or spinner in the runner's
`kubectl` output. The parser is written against JSON payloads and nothing else is a valid
frame.

## Audit

Starting a phase is a privileged, cluster-mutating action and it writes an audit row —
from the server, before the process is spawned, naming the operator from their token. What
it deliberately does not record is whether the cluster action succeeded, because the runner
cannot see that. See [`audit-trail.md`](audit-trail.md).

## Tests

| Suite | What it covers |
|-------|----------------|
| `test/acceptance/supercred-log-streaming.spec.ts` | live cluster; the log renders while the script is still running |
| `test/acceptance/supercred-log-streaming-harness.spec.ts` | harness; three cases on the default transport, a fourth opting into SSE and asserting the *same* temporal behaviour |
| `d2-signalloom/apps/dashboard-signalloom/src/pages/supercredInstructor.test.tsx` | panel behaviour, including that the browser writes no audit event |
