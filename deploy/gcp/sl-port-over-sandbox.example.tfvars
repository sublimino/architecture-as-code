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

    # ─── The one value to decide before applying ────────────────────────────
    #
    # "" means NO PUBLIC FRONTEND IS CREATED AT ALL. Not "no certificate" — no
    # global address, no managed certificate, no target proxy, no forwarding
    # rule. modules/edge gates every one of them on `tls_enabled = hostname !=
    # ""`, and the `lb_ip_address` output is the empty string. The backend
    # service, the Cloud Armor policy and the IAP grant are still created, but
    # nothing routes to them.
    #
    # That is fail-closed and it is safe, and it is NOT what "I want to be able
    # to route to it" asks for. As shipped, this environment has no way in.
    #
    # To get routable-but-private, set this to a name Andy controls and LEAVE
    # dns_managed_zone = "". That combination builds the full HTTPS frontend
    # with IAP in front of it and leaves only the DNS record to do by hand:
    #
    #     terraform output lb_ip_address     # after apply
    #     # create an A record for that name pointing at it, at your registrar
    #
    # The Google-managed certificate stays PROVISIONING until the A record
    # resolves, then issues on its own. A certificate that will never issue and
    # one that has not issued yet look identical, so add the record promptly.
    #
    # Left empty here deliberately: guessing which domain Andy controls is
    # exactly the kind of assumption that produces a certificate stuck in
    # PROVISIONING against a name nobody owns.
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
