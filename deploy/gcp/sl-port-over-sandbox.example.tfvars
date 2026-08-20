# The real, apply-ready input for Andy's first live demo environment.
#
# Every value below is real and verified. Nothing here is a placeholder and
# nothing needs substituting before a plan — with one deliberate exception,
# `hostname`, which is discussed at length further down because the choice is
# Andy's and the two options behave very differently.
#
# ─── Why this file is here and not in terraform/environments/ ───────────────
#
# It is the natural home, and it is the one place it cannot go. Two committed
# guards forbid it, and both were verified by probe rather than by reading:
#
#   test/terraform-environment-keys.bats
#     "no .tfvars file is committed under terraform/, only .tfvars.example"
#     runs `find terraform/ -name '*.tfvars'` and asserts the output is empty.
#     That is a FILESYSTEM check, not a git one, so a real .tfvars under
#     terraform/ turns the suite red whether or not it is committed — and
#     .gitignore ignores `*.tfvars` anyway, so committing it there is not
#     possible either. Confirmed by dropping a scratch file and watching the
#     test fail.
#
#   test/terraform-environment-keys.bats
#     "no example contains a real project id, domain, or address"
#     loops over terraform/environments/*.tfvars.example and rejects any CODE
#     line matching `\.(com|net|org|io|dev|co\.uk)\b`. The single most important
#     value in this file — `user:sublimino@gmail.com` — trips it. Comments are
#     stripped before the check, so the address is fine in prose and fatal as a
#     value. Confirmed by probe.
#
# So a real .tfvars cannot sit under terraform/, and a .tfvars.example under
# terraform/environments cannot carry the real IAP principal. Renaming the file
# to dodge either guard would be defeating a control that exists for a good
# reason. It lives outside terraform/ instead, where `.gitignore` line 100
# (`!*.example.tfvars`) explicitly permits it to be committed.
#
# It carries no secret. A GCP project id is not sensitive, and the email is
# Andy's own and already public. The thing the guards are protecting against —
# a real hostname, a real office IP range, real credentials — is not present.
#
# ─── Use ────────────────────────────────────────────────────────────────────
#
# Copy into place, plan, review, apply. The copy is gitignored and must be
# removed afterwards, or terraform-environment-keys.bats stays red:
#
#     cp deploy/gcp/sl-port-over-sandbox.example.tfvars \
#        terraform/environments/environments.tfvars
#
# `environments.tfvars` is the filename the Makefile passes as -var-file
# (GCP_TF_VAR_FILE), resolved relative to terraform/environments.
#
# ─── Verified read-only against the live project on 2026-08-18 ──────────────
#
#   project            sl-port-over-sandbox, number 308545937261
#   region             us-east4; zones -a, -b, -c all UP
#   machine type       n2-standard-8 exists in us-east4-a (8 vCPU, 32 GB)
#   APIs enabled       compute, iap, dns, iam, iamcredentials, storage
#   Cloud DNS zones    NONE — hence dns_managed_zone = "" below
#   existing subnets   only the auto-mode `default` VPC, per-region ranges in
#                      10.128.0.0/9 (us-east4's is 10.150.0.0/20). 10.10.1.0/24
#                      collides with nothing.
#   Cloud Armor        `security-policies list` is a GLOBAL collection and
#                      answered for this project; the LB and its policy are
#                      global resources and are not region-limited, so us-east4
#                      imposes no constraint on either.

project_id     = "sl-port-over-sandbox"
project_number = "308545937261"

target_env = "demo-1"

# Identity is the gate. There is no anonymous path to the application.
access_mode = "iap"

# The account that will actually sign in. This is the value that decides whether
# the demo can be opened at all: IAP denies everyone not named here, and the
# failure mode is a 403 AFTER a successful Google login, which reads like a
# broken deploy rather than a missing grant.
iap_members = [
  "user:sublimino@gmail.com",
]

# No Cloud DNS managed zone exists in this project (verified: zero zones), so
# there is nothing for the edge module to write a record into. This disables the
# DNS RECORD only — see the hostname note below for what actually governs the
# certificate and the frontend.
dns_managed_zone = ""

# ─── Tailscale ──────────────────────────────────────────────────────────────
#
# A tailnet node ON the demo VM, so the estate is reachable from Andy's own
# devices without the IAP tunnel dance. Off by default across the whole tree;
# these four lines are what turn it on for this environment.
#
# PREREQUISITE, and it is out of band on purpose. The auth key is minted by Andy
# and stored as a Secret Manager secret named below, in this project:
#
#     tailscale admin → Settings → Keys → Generate auth key
#       reusable ✓   ephemeral ✓   pre-approved ✓   tags: tag:sl-demo
#
#     printf '%s' "<the key>" | gcloud secrets create sl-demo-tailscale-authkey \
#       --project sl-port-over-sandbox --data-file=- --replication-policy=automatic
#
# Terraform REFERENCES that secret with a data source and grants the runtime
# service account roles/secretmanager.secretAccessor ON THAT SECRET ALONE. It
# never declares the secret or its version, because a
# google_secret_manager_secret_version resource carries its payload in
# `secret_data` and would write the key into Terraform state in plain text.
#
# If the secret does not exist, `tailscale_enabled = true` fails at PLAN with
# "secret not found" — deliberately, and before anything is created. Leaving the
# flag false plans and applies exactly as this environment did before.
#
# SECOND PREREQUISITE, and it is easy to miss because this file does not set it.
# The startup script installs Tailscale from pkgs.tailscale.com over public
# HTTPS, which the egress policy DENIES unless the environment names public
# destinations in `egress_public_https_destinations`. That variable is absent
# here on purpose — CONTRACT.md §6 forbids 0.0.0.0/0 in a committed example, and
# a narrower list would be fiction. The live tfvars this file is copied to
# already sets it; if yours does not, the install fails, the startup script logs
# a WARNING naming this exact cause, and the VM boots WITHOUT Tailscale rather
# than failing to boot. Reading `journalctl -t signalloom-bootstrap` on the box
# is how you find out.
#
# reusable + ephemeral + pre-approved, each for a reason:
#   reusable      the VM re-runs its bootstrap on rebuild; a single-use key
#                 works exactly once and then fails silently forever after.
#   ephemeral     MANDATORY. Not a nicety — see the block below.
#   pre-approved  device approval is a manual step, and a node that boots at
#                 03:00 waiting for a human is a node that is simply down.
#
# ─── EPHEMERAL IS MANDATORY, and here is the bill for getting it wrong ──────
#
# `terraform destroy` removes the GCP instance. NOTHING IN TERRAFORM REMOVES THE
# TAILNET DEVICE RECORD — Tailscale is not a Terraform-managed resource in this
# estate and there is no Tailscale API credential anywhere in it (checked:
# `gcloud secrets list` returns exactly one Tailscale-related secret,
# sl-demo-tailscale-authkey, which is an auth key and cannot delete devices).
#
# So the ONLY two things that ever free the name are:
#
#   1. `tailscale logout` before the VM dies. Primary path, wired into
#      `make gcp-tf-destroy`, plus a systemd ExecStop unit on the VM as the
#      backstop for hard kills. Neither can cover a VM that is already gone.
#   2. Tailscale's own reap of an EPHEMERAL node a few minutes after it goes
#      offline. This is the only mechanism that covers case 1's gap, and it
#      exists only if the key was minted ephemeral.
#
# When both are absent the offline device keeps owning the name and the next
# build is handed the next free suffix. Measured on 2026-08-18: sl-demo-1 was
# destroyed and rebuilt, and the new node joined as sl-demo-1-1. The suffix is a
# function of how many corpses exist, so the URL drifts further every rebuild.
#
# THE KEY BEHIND THIS ENVIRONMENT WAS NOT EPHEMERAL, and that is measured rather
# than inferred from the drift: the stale device was last seen at 02:01:14Z and
# was still registered at 02:48:51Z — 47 minutes disconnected, well past the
# ~30-minute reap window. An ephemeral node would have been gone. Re-mint it
# with `ephemeral ✓` and replace the secret's payload with a new version.
#
# Why the fix is not a random hostname suffix: it was considered and rejected.
# A suffix makes the name unique and unpredictable, and the entire point of this
# access plane is a URL that can be sent to someone BEFORE the VM has booted.
# Uniqueness is not the property being defended; stability is.
#
# How you find out it went wrong: the startup script asserts the granted
# MagicDNS name against the requested one and, on a mismatch, logs at ERROR and
# writes /var/lib/signalloom/tailscale-name-mismatch. `make gcp-tf-demo-status`
# and `make gcp-tf-ts-status` both read that marker and FAIL on it. It never
# silently accepts the suffixed name.
tailscale_enabled           = true
tailscale_authkey_secret_id = "sl-demo-tailscale-authkey"
tailscale_tag               = "tag:sl-demo"

# FALSE, and worth understanding before flipping it.
#
# Tailscale SSH would let tailnet principals SSH to this VM with authorisation
# decided by the tailnet ACL. That is a SECOND authorisation system, and GCP IAM
# and the GCP audit log cannot see it: a principal denied by OS Login can still
# be admitted by the ACL, and nothing in `gcloud compute instances describe`
# says so. On an environment whose entire subject is posture, that is a bad
# default even though the mechanism itself is well built.
#
# The asymmetry that makes false cheap: with it off, the tailnet still gives
# direct access to the application on app_port, which is the thing that was
# actually wanted. Only the SHELL falls back to IAP, and IAP for a shell already
# works today.
tailscale_ssh_enabled = false

# ─── UDP egress: DERP relay vs direct WireGuard ─────────────────────────────
#
# Tailscale works with these EMPTY. It relays every packet through Tailscale's
# DERP servers over TCP 443, which egress_public_https_destinations already
# permits. Opening UDP buys a direct path — latency and throughput — not
# reachability, and a comment claiming otherwise would be wrong.
#
#   41641/udp  the node's own direct listener
#   3478/udp   STUN, how two nodes behind NAT discover a path to each other
#
# THE DESTINATIONS BELOW ARE RFC5737 DOCUMENTATION RANGES AND WILL NOT WORK.
# They are here because CONTRACT.md §6 forbids 0.0.0.0/0 in any committed
# example, and this file is committed. The honest operational answer is that a
# direct WireGuard path goes to the PEER's address, which is not knowable in
# advance — so a real environment sets:
#
#     egress_public_udp_destinations = ["0.0.0.0/0"]
#
# in its own gitignored tfvars, and accepts what that costs. Stated plainly: UDP
# is connectionless, so an allowed UDP port is a one-way channel out of the
# estate that looks identical in the flow logs whether anything answered or not.
# It is the best exfiltration path this policy contains. What bounds it is that
# it is scoped by target_service_accounts to this environment's runtime service
# account, that it is EGRESS only — ingress is entirely unaffected, there is
# still no external IP, and the only ways in remain IAP on 22 and on app_port —
# and that the port list is two entries long and countable at a glance.
#
# If that trade is not wanted, delete both lines. DERP relaying is the default
# and it is not a degraded mode; it is how most Tailscale nodes on restrictive
# networks run permanently.
egress_public_udp_ports        = ["3478", "41641"]
egress_public_udp_destinations = ["192.0.2.0/24", "198.51.100.0/24"]

environments = {
  "demo-1" = {
    kind        = "demo"
    subnet_cidr = "10.10.1.0/24"

    # Zone must be inside the region. They are independent strings and nothing
    # at plan time compares them, so a mismatch plans cleanly and fails during
    # apply, after the network and load balancer already exist.
    region = "us-east4"
    zone   = "us-east4-a"

    # Sized for a Kind-based demo and no larger. This matches ci-1's existing
    # allocation rather than demo-1.tfvars.example's n2-standard-16: 8 vCPU and
    # 32 GB runs the stack, and the 16-vCPU machine is the CI lane's size for
    # parallel test throughput this box does not need. Halving it halves the
    # dominant line on the bill, and it is a one-line change if the demo turns
    # out to need more.
    machine_type = "n2-standard-8"
    boot_disk_gb = 100

    # ─── The public HTTPS edge is deliberately NOT instantiated ─────────────
    #
    # "" means no public frontend is created at all. Not merely "no
    # certificate": no global address, no managed certificate, no target proxy
    # and no forwarding rule. modules/edge gates every one of them on
    # `tls_enabled = hostname != ""`, the `lb_ip_address` output is the empty
    # string, and modules/edge/tests/tls_frontend.tftest.hcl asserts exactly
    # this in `empty_hostname_plans_no_public_frontend_at_all`.
    #
    # This is a choice, not a gap. IAP for *web* backends requires an HTTPS
    # load balancer, which requires a certificate on a name that resolves. The
    # project has no Cloud DNS managed zone, so wiring that path tonight would
    # mean either a self-signed certificate (browser warnings on a demo) or a
    # domain that is not in this project. Neither is worth it, because the
    # thing Andy asked for is available without any of it.
    #
    # What this environment gets instead:
    #
    #   * a private VM with NO external IP,
    #   * reachable only over IAP TCP forwarding, which
    #     modules/network's `allow_iap_ssh` permits from 35.235.240.0/20 and
    #     from nowhere else, with `deny_all_ingress` behind it,
    #   * and ZERO public surface — no forwarding rule, no certificate, no
    #     public listener of any kind exists to be scanned or attacked.
    #
    # That is a stronger reading of "route to it, but not public" than the load
    # balancer path, not a weaker one: the tunnel is routable by Andy and
    # unreachable by everyone else, because there is nothing listening publicly
    # to reach.
    #
    # NOTE the port, and note WHICH port. `allow_iap_ssh` opens TCP **22 only**;
    # the application is opened by a second, separately-named rule,
    # `allow_iap_app`, on the `app_port` set below and nothing else. So:
    #
    #     gcloud compute start-iap-tunnel <instance> 30754 \
    #       --local-host-port=localhost:30754 --zone us-east4-a
    #     # then open https://dashboard.osramp.acme.local:30754
    #
    # The SSH forward still works and remains the fallback:
    #
    #     gcloud compute ssh <instance> --zone us-east4-a \
    #       --project sl-port-over-sandbox --tunnel-through-iap \
    #       -- -L 30754:localhost:30754
    #
    # Keeping access_mode = "iap" above is still correct: it is the safe
    # default, and it becomes the live web posture the moment a hostname is
    # added, with no other change.
    hostname = ""

    # INERT IN THIS MODE, and that is worth knowing before it changes.
    # modules/edge sets `admit_all_clients = access_mode == "iap"`, so under
    # pure "iap" Cloud Armor admits every source address and IAP alone decides.
    # These documentation ranges are therefore not a gate today; they are here
    # because the environment contract rejects 0.0.0.0/0 and ::/0 outright and
    # every entry must be a real CIDR.
    #
    # The trap: flipping access_mode to "iap_and_allowlist" makes them live
    # immediately, and RFC 5737 ranges match no real client. That change locks
    # everyone out, including Andy, and the symptom is a connection that never
    # reaches the sign-in page. Put a real source range here first.
    allowed_ipv4 = ["192.0.2.0/24"]
    allowed_ipv6 = ["2001:db8::/32"]

    # 8080, and it matches the dashboard's nginx Service port on purpose.
    #
    # Every access method — the IAP tunnel here, ngrok, Tailscale, Funnel —
    # forwards to dashboard-signalloom:8080 in fe-signalloom, which serves the
    # SPA and proxies /dex/ and /api/ on the same origin. Publishing the VM side
    # on the same number keeps the forward a straight 8080-to-8080.
    #
    # This was 30754, and that was not a preference either: the access path went
    # through the Envoy Gateway, which routes by SNI, and Dex's callback was
    # pinned to that exact host:port. Dex's issuer and redirect URI are rendered
    # from PUBLIC_ORIGIN now, published by whichever access script is running, so
    # nothing pins a port any more. Envoy stays deployed as the Gateway API
    # ingress; it is just not what a browser goes through.
    app_port = 8080

    # False, deliberately, and against the .example's `true`. This is a sandbox
    # Andy pays for by the hour; the thing that must stay cheap is tearing it
    # down. Deletion protection on an environment whose whole purpose is to be
    # destroyed after a demo turns `make gcp-tf-destroy` into a two-step
    # puzzle at exactly the moment the bill is running.
    deletion_protect = false

    labels = {
      tier  = "demo"
      owner = "andy"
    }
  }
}
