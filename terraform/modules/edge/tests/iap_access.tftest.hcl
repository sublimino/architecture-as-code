# ---------------------------------------------------------------------------
# Identity-Aware Proxy -- the control that makes the edge non-public.
#
# Asserted on the EVALUATED plan. A grep can confirm the file contains the
# string "iap"; it cannot tell you that the iap block survived the dynamic
# for_each, that enabled came out true, or that a principal was actually
# granted httpsResourceAccessor on THIS backend service.
#
# Every negative run here is paired with a positive proving the same
# configuration plans cleanly once the offending input is corrected. A run that
# fails for an unrelated reason -- a typo, a missing variable -- is otherwise
# indistinguishable from a validation rule firing correctly (CONTRACT §7a).
#
# mock_provider means no credentials, no network, no real project.
# command = plan only -- apply against a mock still writes state.
# ---------------------------------------------------------------------------

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id             = "CHANGEME-project"
  environment_key        = "demo-1"
  name_prefix            = "sl-demo-1"
  labels                 = { environment = "demo-1", kind = "demo" }
  hostname               = "demo-1.example.invalid"
  dns_managed_zone       = "signalloom-demo"
  backend_instance_group = "projects/CHANGEME-project/zones/europe-west2-a/instanceGroups/sl-demo-1-ig"
  app_port               = 8080
  allowed_ipv4           = ["192.0.2.0/24"]
  allowed_ipv6           = []
  iap_members            = ["user:someone@example.invalid"]
}

# ---------------------------------------------------------------------------
# The default posture
# ---------------------------------------------------------------------------

run "default_access_mode_is_iap" {
  command = plan

  # The single most important assertion in this file. The safe posture must be
  # what you get by NOT thinking about it. This run never mentions access_mode,
  # so it reads whatever the variable's default actually is.
  assert {
    condition     = var.access_mode == "iap"
    error_message = "The default access_mode is not \"iap\". A module that defaults to the weaker posture is how the weaker posture ends up in production: every caller who does not think about the question gets a public edge."
  }

  assert {
    condition     = length(google_compute_backend_service.app.iap) == 1
    error_message = "No iap block was planned on the backend service under the default access_mode. Without it the load balancer is a public HTTPS endpoint whose only control is an IP allowlist."
  }

  assert {
    condition     = google_compute_backend_service.app.iap[0].enabled == true
    error_message = "The evaluated iap block exists but enabled is not true. A present-but-disabled IAP block is the most reassuring possible way to be public."
  }
}

run "iap_mode_grants_https_resource_accessor_to_named_principals" {
  command = plan

  assert {
    condition     = length(google_iap_web_backend_service_iam_member.accessors) == length(var.iap_members)
    error_message = "The number of planned IAP IAM members does not equal the number of iap_members supplied. IAP enabled with nobody granted access is a locked door with no key; the demo would authenticate every visitor and then refuse all of them."
  }

  assert {
    condition = alltrue([
      for m in google_iap_web_backend_service_iam_member.accessors :
      m.role == "roles/iap.httpsResourceAccessor"
    ])
    error_message = "An IAP IAM member was granted a role other than roles/iap.httpsResourceAccessor. Any other role does not admit a principal through the IAP web boundary."
  }

  # Bind the grant to THIS backend service. A grant on someone else's backend
  # is a perfectly valid resource that authorises nobody here.
  assert {
    condition = alltrue([
      for m in google_iap_web_backend_service_iam_member.accessors :
      m.web_backend_service == google_compute_backend_service.app.name
    ])
    error_message = "An IAP IAM member is attached to a backend service other than this module's. The grant would exist and authorise nothing on this edge."
  }

  assert {
    condition = alltrue([
      for m in google_iap_web_backend_service_iam_member.accessors :
      can(regex("^(user|group|serviceAccount|domain|principal|principalSet):", m.member))
    ])
    error_message = "An evaluated IAP member is not a prefixed IAM principal, so the grant would not resolve to anyone."
  }
}

run "iap_mode_uses_the_iap_managed_oauth_client_by_default" {
  command = plan

  # The provider schema at google ~> 6.8 marks oauth2_client_id and
  # oauth2_client_secret optional, so the IAP-managed client is available.
  # Selecting it keeps a client secret out of tfvars and out of state.
  assert {
    condition     = google_compute_backend_service.app.iap[0].oauth2_client_id == null
    error_message = "oauth2_client_id evaluated to a non-null value while none was supplied. The empty default must select the IAP-managed OAuth client rather than sending an empty string, which the API would reject."
  }

  assert {
    condition     = google_compute_backend_service.app.iap[0].oauth2_client_secret == null
    error_message = "oauth2_client_secret evaluated to a non-null value while none was supplied."
  }
}

run "an_explicit_oauth_client_is_wired_through_when_supplied" {
  command = plan

  variables {
    iap_oauth2_client_id     = "123456789-example.apps.googleusercontent.invalid"
    iap_oauth2_client_secret = "NOT-A-REAL-SECRET-test-fixture-only"
  }

  # Paired positive for the both-or-neither validation below: the externally
  # managed client form must still work, or that rule proves only that the
  # feature is broken.
  assert {
    condition     = google_compute_backend_service.app.iap[0].oauth2_client_id == "123456789-example.apps.googleusercontent.invalid"
    error_message = "An explicitly supplied oauth2_client_id did not reach the evaluated iap block, so the externally-managed client form is not actually wired."
  }
}

# ---------------------------------------------------------------------------
# Cloud Armor posture under IAP
# ---------------------------------------------------------------------------

run "default_deny_survives_in_iap_mode" {
  command = plan

  # one() returns null for an empty list, so this fails both when the rule was
  # flipped to allow AND when it was deleted outright.
  assert {
    condition = one([
      for r in google_compute_security_policy.edge.rule : r.action
      if r.priority == 2147483647
    ]) == "deny(403)"
    error_message = "The Cloud Armor default rule is not deny(403) in iap mode. The default deny is retained in every access mode; enabling IAP narrows who gets through, it does not license removing the floor underneath."
  }

  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r
      if can(regex("(sqli|xss)-", try(r.match[0].expr[0].expression, ""))) && r.action == "deny(403)"
    ]) == 2
    error_message = "The preconfigured WAF denies did not survive iap mode. An authenticated user is still not trusted to send SQL injection or XSS."
  }

  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r
      if r.action == "rate_based_ban"
    ]) > 0
    error_message = "No rate limit is enforced in iap mode. The IAP sign-in boundary is exactly what needs shielding from volumetric and credential-stuffing traffic, because Cloud Armor is evaluated before IAP on a global external ALB."
  }
}

run "iap_mode_admits_no_arbitrary_client_cidr" {
  command = plan

  # In iap mode authorisation is IAP's job, so the allowlist must not be
  # consulted for it. Cloud Armor admits sources to the SIGN-IN boundary only.
  # This asserts the allowlist is genuinely ignored: an operator who leaves a
  # stale allowlist in tfvars must not thereby be granting anything.
  variables {
    allowed_ipv4 = ["203.0.113.0/24"]
    allowed_ipv6 = ["2001:db8:dead::/48"]
  }

  assert {
    condition = alltrue([
      for r in google_compute_security_policy.edge.rule :
      !contains(try(r.match[0].config[0].src_ip_ranges, []), "203.0.113.0/24")
      && !contains(try(r.match[0].config[0].src_ip_ranges, []), "2001:db8:dead::/48")
      if r.action == "allow" || r.action == "rate_based_ban"
    ])
    error_message = "An allow rule in iap mode admits a CIDR taken from the allowlist. In iap mode the allowlist must not be consulted for authorisation at all, or a stale tfvars entry silently becomes a grant."
  }

  # Existence guard. The assertion above is trivially satisfied by a policy with
  # no allow rules whatsoever, which would be an edge nobody can reach.
  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r
      if r.action == "allow"
    ]) == 1
    error_message = "Expected exactly one allow rule in iap mode. Zero would mean the assertion above is measuring an empty set and the edge is unreachable by anyone; more than one means the allowlist leaked back into the allow band."
  }
}

run "iap_and_allowlist_mode_narrows_cloud_armor_and_still_enables_iap" {
  command = plan

  variables {
    access_mode  = "iap_and_allowlist"
    allowed_ipv4 = ["192.0.2.0/24"]
    allowed_ipv6 = []
  }

  assert {
    condition     = google_compute_backend_service.app.iap[0].enabled == true
    error_message = "IAP is not enabled in iap_and_allowlist mode, so the defence-in-depth posture is really just the allowlist."
  }

  assert {
    condition = alltrue([
      for r in google_compute_security_policy.edge.rule :
      !contains(try(r.match[0].config[0].src_ip_ranges, []), "*")
      if r.action == "allow" || r.action == "rate_based_ban"
    ])
    error_message = "An allow rule matches \"*\" in iap_and_allowlist mode. In that mode Cloud Armor is supposed to narrow which networks can even reach the sign-in page, and a wildcard removes the second layer entirely."
  }

  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r
      if contains(try(r.match[0].config[0].src_ip_ranges, []), "192.0.2.0/24") && r.action == "allow"
    ]) == 1
    error_message = "The configured allowlist CIDR does not appear in exactly one allow rule in iap_and_allowlist mode, so the allowlist layer is not actually applied."
  }
}

run "allowlist_mode_disables_iap_entirely" {
  command = plan

  variables {
    access_mode = "allowlist"
    iap_members = []
  }

  # The retained public-demo posture. Proving IAP is genuinely absent matters as
  # much as proving it is present: a half-configured iap block that planned but
  # did not enable would be the worst of both worlds.
  assert {
    condition     = length(google_compute_backend_service.app.iap) == 0
    error_message = "An iap block was planned in allowlist mode. The mode must be a real choice, not an always-on block with a flag inside it."
  }

  assert {
    condition     = length(google_iap_web_backend_service_iam_member.accessors) == 0
    error_message = "IAP IAM members were planned in allowlist mode, granting access through a boundary that does not exist."
  }

  assert {
    condition = alltrue([
      for r in google_compute_security_policy.edge.rule :
      !contains(try(r.match[0].config[0].src_ip_ranges, []), "*")
      if r.action == "allow" || r.action == "rate_based_ban"
    ])
    error_message = "An allow rule matches \"*\" in allowlist mode with no IAP behind it. That is the exact configuration the resource precondition exists to make unrepresentable."
  }
}

# ---------------------------------------------------------------------------
# Negative runs -- each paired with a positive above or immediately below
# ---------------------------------------------------------------------------

run "rejects_an_empty_iap_members_under_iap_mode" {
  command = plan

  variables {
    access_mode = "iap"
    iap_members = []
  }

  # IAP with no authorised principal is a locked door with no key, and the
  # failure mode is a demo nobody can open -- discovered live, in front of the
  # audience, with a Google sign-in page that refuses every account.
  expect_failures = [var.iap_members]
}

run "rejects_an_empty_iap_members_under_iap_and_allowlist_mode" {
  command = plan

  variables {
    access_mode = "iap_and_allowlist"
    iap_members = []
  }

  expect_failures = [var.iap_members]
}

run "accepts_a_populated_iap_members_under_iap_mode" {
  command = plan

  variables {
    access_mode = "iap"
    iap_members = ["user:someone@example.invalid"]
  }

  # The paired positive. Without it, the two runs above would pass just as
  # happily if the variable rejected EVERY input, and the suite would be
  # certifying a module that can never be configured at all.
  assert {
    condition     = length(google_iap_web_backend_service_iam_member.accessors) == 1
    error_message = "A populated iap_members must plan exactly one IAM member. If this fails, the empty-list rejections above prove nothing about the emptiness rule."
  }
}

run "rejects_allUsers_in_iap_members" {
  command = plan

  variables {
    iap_members = ["allUsers"]
  }

  expect_failures = [var.iap_members]
}

run "rejects_allAuthenticatedUsers_in_iap_members" {
  command = plan

  # The single most dangerous input this module accepts. The word
  # "authenticated" reads as a restriction; in IAP it means any Google account
  # on earth, which is functionally public access wearing the vocabulary of
  # access control.
  variables {
    iap_members = ["allAuthenticatedUsers"]
  }

  expect_failures = [var.iap_members]
}

run "rejects_allAuthenticatedUsers_hidden_among_valid_principals" {
  command = plan

  # The realistic spelling of this mistake: not a lone bad value, but one
  # appended to a list that already looks correct in review.
  variables {
    iap_members = ["user:someone@example.invalid", "allAuthenticatedUsers"]
  }

  expect_failures = [var.iap_members]
}

run "rejects_a_wildcard_principalset" {
  command = plan

  # This run exists to make the dangerous-value guard INDEPENDENTLY falsifiable,
  # and it was added after a mutation check found it was not. The prefix rule
  # also rejects allUsers and allAuthenticatedUsers -- neither carries a "type:"
  # prefix -- so deleting the dedicated guard entirely left the suite green.
  # The most dangerous line in the module had no test that could see it vanish.
  #
  # A wildcard principalSet is prefix-valid, so only the dedicated guard can
  # reject it. Deleting that guard now turns this run red.
  variables {
    iap_members = ["principalSet://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/demo-pool/*"]
  }

  expect_failures = [var.iap_members]
}

run "accepts_a_specific_principalset_without_a_wildcard" {
  command = plan

  # Paired positive: the wildcard is what is rejected, not the principalSet
  # form itself.
  variables {
    iap_members = ["principalSet://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/demo-pool/subject/someone"]
  }

  assert {
    condition     = length(google_iap_web_backend_service_iam_member.accessors) == 1
    error_message = "A specific, non-wildcard principalSet must plan as an IAM member. If this fails, the wildcard rejection above proves only that principalSet members are broken."
  }
}

run "accepts_named_principals_of_every_supported_type" {
  command = plan

  # Paired positive for all three rejections above. A validation that rejected
  # every member would make each of them pass while making the module unusable.
  variables {
    iap_members = [
      "user:someone@example.invalid",
      "group:demo-viewers@example.invalid",
      "serviceAccount:probe@CHANGEME-project.iam.gserviceaccount.invalid",
      "domain:example.invalid",
    ]
  }

  assert {
    condition     = length(google_iap_web_backend_service_iam_member.accessors) == 4
    error_message = "Four legitimately-named principals must all plan as IAM members. If this fails, the allUsers and allAuthenticatedUsers rejections prove nothing beyond the variable rejecting things."
  }
}

run "rejects_a_bare_email_address_as_a_member" {
  command = plan

  # Not dangerous, but silently useless: an unprefixed email is not a valid IAM
  # member and would grant access to nobody, which presents as "IAP is broken".
  variables {
    iap_members = ["someone@example.invalid"]
  }

  expect_failures = [var.iap_members]
}

run "rejects_an_unknown_access_mode" {
  command = plan

  variables {
    access_mode = "public"
  }

  expect_failures = [var.access_mode]
}

run "accepts_every_documented_access_mode" {
  command = plan

  # Paired positive for the run above.
  variables {
    access_mode = "iap_and_allowlist"
  }

  assert {
    condition     = contains(["iap", "allowlist", "iap_and_allowlist"], var.access_mode)
    error_message = "A documented access_mode was rejected, so the unknown-mode rejection above proves nothing."
  }
}

run "rejects_an_oauth_client_id_without_its_secret" {
  command = plan

  variables {
    iap_oauth2_client_id = "123456789-example.apps.googleusercontent.invalid"
  }

  # Half a client pair is not degraded, it is broken: the provider would send an
  # id with no secret and IAP would reject every sign-in.
  expect_failures = [var.iap_oauth2_client_secret]
}

run "rejects_an_oauth_secret_without_its_client_id" {
  command = plan

  variables {
    iap_oauth2_client_secret = "NOT-A-REAL-SECRET-test-fixture-only"
  }

  expect_failures = [var.iap_oauth2_client_secret]
}
