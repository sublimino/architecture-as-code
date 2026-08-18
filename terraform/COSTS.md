# Costs — what a demo environment actually costs, and the levers

Figures are **order of magnitude**, in GBP, at `europe-west2` (London) list
price, for planning only. They are derived from published list rates, not from a
bill — no apply has been run. Treat the totals as "which order of magnitude am I
in", not as a quote. Re-check against the GCP pricing calculator before
committing to a number in front of anyone.

Rounding convention: one significant figure below £10, two above.

---

## 1. Per demo environment, running continuously for one month

| Driver | Shape | ~£/month | Notes |
|---|---|---|---|
| **VM (`n2-standard-16`)** | 16 vCPU / 64 GB, on-demand, 730 h | **£450** | Dominates everything else by an order of magnitude. This single line is the cost model. |
| **Boot disk** (200 GB pd-balanced) | £0.09/GB-month | **£18** | Persists while the instance exists, including while suspended. |
| **Cloud NAT gateway** | ~£0.037/h + ~£0.037/GB processed | **£27** + egress | The hourly charge is per NAT gateway, not per VM, so it is shared across environments in the same region if they share a router. |
| **LB forwarding rule** | ~£0.02/h for the first five rules | **£15** | Charged per rule, per environment. HTTP-redirect and HTTPS rules count separately. |
| **LB data processing** | ~£0.007/GB | **£1** | A demo moves very little data. Negligible unless someone attaches a dataset. |
| **Cloud Armor policy** | ~£4/policy-month + ~£0.60 per million requests | **£4** | The request charge is noise at demo volumes; the per-policy charge is not, and it is per environment. |
| **Static external IP** (in use) | ~£0.003/h | **£2** | Free while attached to a forwarding rule in some tiers; budget for it. |
| **DNS managed zone** | ~£0.16/zone-month + query charges | **£0.20** | Shared across all environments — a platform singleton, not per demo. |
| **Uptime checks** | first 1M check-executions free | **£0** | One check per demo at 300 s is ~8.6k executions/month. |
| **Alert policies / notification channels** | no charge for email channels | **£0** | |
| **Per-environment total, continuous** | | **≈ £520/month** | |

### The number that matters

**A demo left running is ~£520/month. The same demo run 8 h/day on weekdays is
~£110/month.** Everything else on this page is rounding error next to that
ratio, and the VM line is ~87% of the total.

---

## 2. Platform singletons — once, not per environment

| Driver | ~£/month | Notes |
|---|---|---|
| **Terraform state bucket** | **< £0.50** | State files are kilobytes. Versioning multiplies object count, not meaningful cost. |
| **Audit log bucket** (standard, 400-day retention) | **£1 – £10** | Scales with admin-activity volume. A handful of GB accumulated over a year is the realistic case. Data-access logging is the variable that can change this by an order of magnitude if a chatty service is added to `data_access_services`. |
| **Logging ingest** | **£0 – £15** | The first 50 GiB/project/month is free; admin activity, system event and policy-denied logs are free to ingest regardless. **Data-access logs are not free** and are the line to watch. |
| **DNS managed zone** | **£0.20** | |
| **Billing budget** | **£0** | |
| **Platform total** | **≈ £2 – £25/month** | Effectively free next to one VM. |

---

## 3. The CI lane

The `ci-N` environments use the same module set, so the same per-environment
figures apply — but the usage pattern is completely different.

| Pattern | ~£/month |
|---|---|
| CI VM suspended between runs, resumed for ~2 h/day | **£40 – £60** |
| CI VM left running | **£520** |
| Boot disk while suspended | **£18** — charged whether the VM runs or not |

A suspended VM stops the compute charge and keeps the disk charge. **The disk
floor is ~£18/month per environment that exists at all**, and it is the reason
"suspend everything" saves ~90% but not 100%.

---

## 4. Levers, in order of effect

1. **Do not leave demos running.** ~£520 → ~£110 for weekday-hours use. Nothing
   else on this list is within an order of magnitude of this lever.
2. **Right-size the VM.** `n2-standard-16` is chosen for the kind cluster the
   demo runs. `n2-standard-8` roughly halves the dominant line. Measure before
   assuming 16 vCPU is needed.
3. **Destroy environments you are finished with.** `make gcp-tf-destroy
   ENV=demo-N CONFIRM=demo-N` removes the disk charge too, which suspending does
   not.
4. **Share the NAT gateway.** One Cloud Router and NAT per region rather than per
   environment saves ~£27/month per additional environment.
5. **Use Spot VMs for CI.** 60–80% off the compute line, at the price of
   preemption. Appropriate for `ci-N`, not for a demo someone is about to show a
   customer.
6. **Committed use discounts.** ~37% (1 year) / ~55% (3 year) on the VM line.
   Only worth it once the estate is steady-state; a CUD on a demo platform whose
   shape is still changing is a bet, not a saving.
7. **Keep `data_access_services` tight.** Admin-activity logs are free to ingest;
   data-access logs are not. Adding a chatty service to that list is the one
   observability change that can move the bill.
8. **Lower `log_retention_days`.** Storage is the smallest lever here — 400 days
   of audit logs is a few pounds. Do not trade an audit trail for pennies.

---

## 5. Budget wiring

`modules/observability` creates a `google_billing_budget` with thresholds at
**50%, 80% and 100%** of `budget_amount_units` (default **500 GBP/month** — one
continuously-running demo plus headroom).

Three thresholds, not one, because a single alarm at 100% only ever arrives too
late to act on. 50% is "the month is going faster than planned", 80% is
"intervene now", 100% is "this is already over".

The budget is gated behind `billing_account_id != ""` so the module plans for an
engineer with project access but no billing-account access — the common case.
When it is disabled the module degrades to "no budget", never to "a budget
nobody is told about": every alert policy is validated to name at least one
notification channel, and a plan with alerts enabled and no channel **fails**.

---

## 6. What is not modelled here

- **Egress to the internet.** Demo traffic is small, but a customer downloading
  artefacts from the demo is not modelled. GCP egress to the internet from
  `europe-west2` is roughly £0.09/GB for the first 10 TB.
- **Sustained-use discounts**, which apply automatically to N2 instances and
  make the continuous-running figure somewhat pessimistic. That is the safe
  direction to be wrong in.
- **Support plans, container registry storage, and any Cloud Build usage**, none
  of which this platform creates.
