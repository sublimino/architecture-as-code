#!/usr/bin/env bats
#
# terraform-worktree-bootstrap.bats — the untracked state a linked worktree does
# not inherit, and the guard that refuses before it costs an apply.
#
# WHAT THIS SUITE IS ABOUT
#
# `git worktree add` carries tracked content only. Everything that lets this repo
# reach a real estate is gitignored: deploy/gcp/deploy-sa, the tfvars, the
# per-environment hand-offs, .keys/. A fresh worktree has none of it, and the
# resulting failures name the wrong subsystem — most expensively deploy-sa, whose
# absence lets `gcp-tf-up` complete a full successful apply and then fail in
# gcp-tf-handoff with a message pointing at terraform outputs.
#
# Every test here drives the script through injected REPO_ROOT / SOURCE_CHECKOUT
# so it operates on fixture trees. Nothing in this suite touches the real
# deploy/gcp/ or .keys/ of the checkout it runs in — a suite that provisioned the
# tree it was testing would be indistinguishable from one that passed.
#
# The name matters: the gate discovers suites with `wildcard test/terraform-*.bats`
# (see GCP_TF_BATS in the Makefile), so `terraform-` is what makes this run at all.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export MAKEFILE="${REPO_ROOT}/Makefile"
  export SCRIPT="${REPO_ROOT}/scripts/gcp-tf/worktree-bootstrap.sh"
}

# A fixture "source checkout": the untracked state, as an operator's main
# checkout carries it. Values are obviously fake — a real project id in a test
# fixture is how one ends up in a tracked file.
# NOTE the extra directory level on both fixtures. The AFM check resolves
# <root>/../kubesec-afm, so a source and a destination that are SIBLINGS resolve
# it to the same path and the worktree-specific case can never be constructed —
# the test would pass or fail for a reason unrelated to what it claims to test.
make_source() {
  local d="${BATS_TEST_TMPDIR}/s/source"
  mkdir -p "${d}/deploy/gcp" "${d}/.keys"
  printf 'deployer@acme-real-project-42.iam.gserviceaccount.com\n' >"${d}/deploy/gcp/deploy-sa"
  printf 'project_id = "acme-real-project-42"\n' >"${d}/deploy/gcp/bootstrap.tfvars"
  printf 'project_id = "acme-real-project-42"\n' >"${d}/deploy/gcp/platform.tfvars"
  printf 'project_id = "acme-real-project-42"\n' >"${d}/deploy/gcp/sl-port-over-sandbox.tfvars"
  printf '{"resources":[]}\n' >"${d}/deploy/gcp/preserve-baseline.json"
  printf '{"schema":"signalloom.gcp.handoff/v1","env":"demo-1"}\n' >"${d}/deploy/gcp/demo-1.handoff.json"
  printf 'not-a-real-key\n' >"${d}/.keys/cosign.key"
  chmod 600 "${d}/.keys/cosign.key"
  printf '%s' "$d"
}

# A fixture "worktree": tracked content only, which is exactly what
# `git worktree add` produces.
make_dest() {
  local d="${BATS_TEST_TMPDIR}/d/dest"
  mkdir -p "${d}/deploy/gcp"
  printf '# tracked example\n' >"${d}/deploy/gcp/sl-port-over-sandbox.example.tfvars"
  printf '%s' "$d"
}

run_tool() {
  local src="$1" dst="$2"; shift 2
  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" "$SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# check — refuses, and names the real cause rather than a plausible wrong one
# ---------------------------------------------------------------------------

@test "check refuses when the worktree carries none of the untracked state" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run_tool "$src" "$dst" check
  [ "$status" -ne 0 ]
}

@test "check names deploy/gcp/deploy-sa, the file whose absence costs a full apply" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run_tool "$src" "$dst" check
  [ "$status" -ne 0 ]
  [[ "${output}" == *"deploy/gcp/deploy-sa"* ]]
}

@test "check states the consequence, so the reader is not left to guess" {
  # Naming a missing file is not enough on its own. The failure this guard
  # replaces was legible — it just described the wrong subsystem. A guard that
  # says only "file absent" invites "so what?" and gets ignored.
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run_tool "$src" "$dst" check
  [[ "${output}" == *"Consequence:"* ]]
}

@test "check does NOT send the reader to terraform outputs — the wrong cause it exists to pre-empt" {
  # This is the whole point of the guard. The failure it replaces reads
  # "the terraform outputs do not carry every value the hand-off contract
  # requires ... deploy_sa" and offers two causes, both wrong on this path.
  # If this guard's own text ever grows the same suggestion, it has become the
  # thing it was written to prevent.
  #
  # The assertion is about REMEDIATION, not vocabulary. An earlier draft of this
  # test forbade the string "terraform output" anywhere in the message, and it
  # went red against text that names the wrong cause precisely in order to
  # dismiss it ("...then gcp-tf-handoff blames terraform outputs"). That is the
  # single most useful sentence here — the reader arrives holding the terraform
  # hypothesis, and naming it is how you dislodge it. So: forbid the ACTIONS
  # that send someone to terraform, not the noun.
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run_tool "$src" "$dst" check
  [[ "${output}" != *"outputs.tf"* ]]
  [[ "${output}" != *"Add the block"* ]]
  [[ "${output}" != *"make gcp-tf-up"* ]]
  # And it says positively what the cause is NOT, because the reader arrives
  # here with the terraform hypothesis already in mind.
  [[ "${output}" == *"NOT a terraform problem"* ]]
}

@test "check names the target that fixes it" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run_tool "$src" "$dst" check
  [[ "${output}" == *"make gcp-tf-worktree-bootstrap"* ]]
}

@test "check passes once the state is present" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run_tool "$src" "$dst" provision
  [ "$status" -eq 0 ]
  run_tool "$src" "$dst" check
  [ "$status" -eq 0 ]
}

@test "check requires the named environment's hand-off only when ENV is given" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run_tool "$src" "$dst" provision
  [ "$status" -eq 0 ]

  # demo-1 was provisioned; demo-2 never existed in the source.
  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" ENV=demo-1 "$SCRIPT" check
  [ "$status" -eq 0 ]

  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" ENV=demo-2 "$SCRIPT" check
  [ "$status" -ne 0 ]
  [[ "${output}" == *"demo-2.handoff.json"* ]]
}

# ---------------------------------------------------------------------------
# provision — idempotent, and never half-applied
# ---------------------------------------------------------------------------

@test "provision copies every required item" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run_tool "$src" "$dst" provision
  [ "$status" -eq 0 ]
  [ -f "${dst}/deploy/gcp/deploy-sa" ]
  [ -f "${dst}/deploy/gcp/bootstrap.tfvars" ]
  [ -f "${dst}/deploy/gcp/platform.tfvars" ]
  [ -f "${dst}/deploy/gcp/sl-port-over-sandbox.tfvars" ]
  [ -f "${dst}/deploy/gcp/preserve-baseline.json" ]
  [ -f "${dst}/deploy/gcp/demo-1.handoff.json" ]
  [ -f "${dst}/.keys/cosign.key" ]
}

@test "provision preserves mode, so a private key does not arrive world-readable" {
  # Worth asserting as an invariant, but note what it does NOT prove: plain `cp`
  # onto a fresh destination already yields (source mode & ~umask), which for an
  # 0600 key under any normal umask is still 0600. So this test does not
  # demonstrate that `-p` is load-bearing — the mutation proof records that
  # explicitly rather than letting a reader assume otherwise. The assertion that
  # DOES pin `-p` is the mtime one below.
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run_tool "$src" "$dst" provision
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "${dst}/.keys/cosign.key")" = "600" ]
}

@test "provision preserves mtime, which the newer-than comparison depends on" {
  # `-p` earns its place here, not on mode. Every staleness decision this tool
  # makes is `[ "$dst" -nt "$src" ]`. Without mtime preservation every copied
  # file is stamped `now` and is therefore NEWER than the source it came from —
  # so the first time a source file legitimately changes, provision reports the
  # destination as locally-modified and refuses, for a difference it created
  # itself on the previous run.
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run_tool "$src" "$dst" provision
  [ "$status" -eq 0 ]
  local a b
  a="$(stat -c '%Y' "${src}/deploy/gcp/deploy-sa")"
  b="$(stat -c '%Y' "${dst}/deploy/gcp/deploy-sa")"
  [ "$a" = "$b" ]

  # And the consequence, stated as behaviour: a freshly provisioned file is not
  # considered newer than its source.
  [ ! "${dst}/deploy/gcp/deploy-sa" -nt "${src}/deploy/gcp/deploy-sa" ]
}

@test "provision is idempotent: a second run writes nothing and still exits 0" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run_tool "$src" "$dst" provision
  [ "$status" -eq 0 ]
  local before; before="$(stat -c '%Y %s' "${dst}/deploy/gcp/deploy-sa")"

  run_tool "$src" "$dst" provision
  [ "$status" -eq 0 ]
  [[ "${output}" == *"nothing to do"* ]]
  [ "$(stat -c '%Y %s' "${dst}/deploy/gcp/deploy-sa")" = "${before}" ]
}

@test "provision refuses to clobber a destination that is NEWER than the source" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run_tool "$src" "$dst" provision
  [ "$status" -eq 0 ]

  # The operator regenerated a hand-off in the worktree. It is now the freshest
  # copy, and overwriting it silently would discard the newer artefact.
  printf '{"schema":"signalloom.gcp.handoff/v1","env":"demo-1","note":"regenerated here"}\n' \
    >"${dst}/deploy/gcp/demo-1.handoff.json"
  touch -d '+1 hour' "${dst}/deploy/gcp/demo-1.handoff.json"

  run_tool "$src" "$dst" provision
  [ "$status" -ne 0 ]
  [[ "${output}" == *"NEWER"* ]]
  # And it said so rather than just declining.
  [[ "${output}" == *"demo-1.handoff.json"* ]]
  grep -q 'regenerated here' "${dst}/deploy/gcp/demo-1.handoff.json"
}

@test "FORCE=1 overwrites a newer destination, because refusing forever is not a policy" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run_tool "$src" "$dst" provision
  printf '{"note":"regenerated here"}\n' >"${dst}/deploy/gcp/demo-1.handoff.json"
  touch -d '+1 hour' "${dst}/deploy/gcp/demo-1.handoff.json"

  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" FORCE=1 "$SCRIPT" provision
  [ "$status" -eq 0 ]
  run grep -c 'regenerated here' "${dst}/deploy/gcp/demo-1.handoff.json"
  [ "$status" -ne 0 ]
}

@test "a blocked item stops the WHOLE provision — no half-provisioned tree" {
  # The failure mode this command exists to prevent is a tree that has some of
  # the state and not the rest, because that produces exactly the misdirected
  # errors the guard is for. So a single blocked item must stop everything,
  # not be skipped past.
  local src dst; src="$(make_source)"; dst="$(make_dest)"

  # One item present and newer; everything else absent.
  printf 'locally newer\n' >"${dst}/deploy/gcp/platform.tfvars"
  touch -d '+1 hour' "${dst}/deploy/gcp/platform.tfvars"

  run_tool "$src" "$dst" provision
  [ "$status" -ne 0 ]
  [[ "${output}" == *"Nothing has been written"* ]]

  # The proof: the unrelated, uncontested items were NOT copied.
  [ ! -f "${dst}/deploy/gcp/deploy-sa" ]
  [ ! -f "${dst}/deploy/gcp/bootstrap.tfvars" ]
  [ ! -d "${dst}/.keys" ]
}

@test "provision refuses when a required item is absent from the source checkout too" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  rm -f "${src}/deploy/gcp/deploy-sa"
  run_tool "$src" "$dst" provision
  [ "$status" -ne 0 ]
  [[ "${output}" == *"deploy-sa"* ]]
  [ ! -f "${dst}/deploy/gcp/bootstrap.tfvars" ]
}

@test "provision refuses when source and destination are the same directory" {
  local src; src="$(make_source)"
  run env REPO_ROOT="$src" SOURCE_CHECKOUT="$src" "$SCRIPT" provision
  [ "$status" -ne 0 ]
  [[ "${output}" == *"same directory"* ]]
}

# ---------------------------------------------------------------------------
# copy vs symlink — the decision that keeps a worktree run out of the source
# ---------------------------------------------------------------------------

@test "LINK=1 symlinks the read-only inputs" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" LINK=1 "$SCRIPT" provision
  [ "$status" -eq 0 ]
  [ -L "${dst}/deploy/gcp/deploy-sa" ]
  [ -L "${dst}/deploy/gcp/bootstrap.tfvars" ]
}

@test "LINK=1 NEVER symlinks a hand-off: gcp-tf-handoff would write the source checkout" {
  # gcp-tf-handoff writes its target with a truncating `>`. Through a symlink
  # that follows the link and overwrites the SOURCE checkout's hand-off,
  # silently repointing the main checkout's lane at this worktree's estate.
  # The flag is honoured for the input class and refused for this one rather
  # than applied uniformly, because a uniform flag here corrupts state.
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" LINK=1 "$SCRIPT" provision
  [ "$status" -eq 0 ]
  [ ! -L "${dst}/deploy/gcp/demo-1.handoff.json" ]
  [ -f "${dst}/deploy/gcp/demo-1.handoff.json" ]
}

@test "LINK=1 NEVER symlinks the preserve baseline: --capture rewrites it in place" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" LINK=1 "$SCRIPT" provision
  [ "$status" -eq 0 ]
  [ ! -L "${dst}/deploy/gcp/preserve-baseline.json" ]
}

@test "writing through a provisioned hand-off does not reach the source checkout" {
  # The behavioural version of the two tests above: simulate what
  # gcp-tf-handoff actually does — `> <file>` — and prove the source is intact.
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" LINK=1 "$SCRIPT" provision
  [ "$status" -eq 0 ]
  printf '{"env":"rewritten-by-the-worktree"}\n' >"${dst}/deploy/gcp/demo-1.handoff.json"
  run grep -c 'rewritten-by-the-worktree' "${src}/deploy/gcp/demo-1.handoff.json"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# KUBESEC_AFM_ROOT — same class of bug, different stage, so a different severity
# ---------------------------------------------------------------------------

@test "an unresolvable KUBESEC_AFM_ROOT is reported but does not fail check" {
  # It gates the AFM image build, not terraform. Failing `check` on it would
  # make gcp-tf-up refuse for a reason with no bearing on the apply — which is
  # how a guard gets a reputation for crying wolf and then gets bypassed.
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  mkdir -p "$(dirname "$src")/kubesec-afm"
  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" KUBESEC_AFM_ROOT= "$SCRIPT" provision
  [ "$status" -eq 0 ]
  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" KUBESEC_AFM_ROOT= "$SCRIPT" check
  [ "$status" -eq 0 ]
  [[ "${output}" == *"KUBESEC_AFM_ROOT"* ]]
  [[ "${output}" == *"WARNING"* ]]
}

@test "REQUIRE_AFM=1 promotes it to a refusal, for callers that do need AFM" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  mkdir -p "$(dirname "$src")/kubesec-afm"
  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" KUBESEC_AFM_ROOT= "$SCRIPT" provision
  [ "$status" -eq 0 ]
  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" KUBESEC_AFM_ROOT= REQUIRE_AFM=1 "$SCRIPT" check
  [ "$status" -ne 0 ]
  [[ "${output}" == *"KUBESEC_AFM_ROOT"* ]]
}

@test "the AFM report prints the export line, since it cannot be fixed by copying" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  mkdir -p "$(dirname "$src")/kubesec-afm"
  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" KUBESEC_AFM_ROOT= "$SCRIPT" check
  [[ "${output}" == *"export KUBESEC_AFM_ROOT="* ]]
}

@test "a set KUBESEC_AFM_ROOT is not second-guessed" {
  local src dst; src="$(make_source)"; dst="$(make_dest)"
  run env REPO_ROOT="$dst" SOURCE_CHECKOUT="$src" KUBESEC_AFM_ROOT=/anywhere "$SCRIPT" check
  [[ "${output}" != *"KUBESEC_AFM_ROOT"* ]]
}

# ---------------------------------------------------------------------------
# gate — the Makefile's entry point, and its deliberate no-op
# ---------------------------------------------------------------------------

@test "gate is a NO-OP outside a linked worktree, so a main checkout is unaffected" {
  # A main checkout with no deploy-sa is a legitimate, supported state: the
  # Makefile warns and runs as the current gcloud identity. Refusing there
  # would be a behaviour change to a path that was never broken.
  local main="${BATS_TEST_TMPDIR}/mainrepo"
  mkdir -p "${main}/deploy/gcp"
  git -C "${main}" init -q
  # commit.gpgsign is on globally on some machines. Signing here launches
  # pinentry against a tty bats does not own, and the commit then blocks until
  # gpg times out — a multi-minute hang that reports as a git failure.
  git -C "${main}" -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    commit -q --allow-empty -m init

  run env REPO_ROOT="${main}" SOURCE_CHECKOUT="${main}" "$SCRIPT" gate
  [ "$status" -eq 0 ]
}

@test "gate refuses in a real linked worktree that is missing the state" {
  # The positive control for the test above. Without it, `gate` returning 0
  # everywhere would satisfy that test and prove nothing.
  local main="${BATS_TEST_TMPDIR}/gmain" wt="${BATS_TEST_TMPDIR}/gwt"
  mkdir -p "${main}/deploy/gcp"
  git -C "${main}" init -q
  # commit.gpgsign is on globally on some machines. Signing here launches
  # pinentry against a tty bats does not own, and the commit then blocks until
  # gpg times out — a multi-minute hang that reports as a git failure.
  git -C "${main}" -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    commit -q --allow-empty -m init
  git -C "${main}" worktree add -q -b probe "${wt}" 2>/dev/null

  run env REPO_ROOT="${wt}" SOURCE_CHECKOUT="${main}" "$SCRIPT" gate
  [ "$status" -ne 0 ]
  [[ "${output}" == *"deploy-sa"* ]]
}

@test "a real linked worktree WITH the state passes the gate" {
  local main="${BATS_TEST_TMPDIR}/hmain" wt="${BATS_TEST_TMPDIR}/hwt"
  mkdir -p "${main}/deploy/gcp"
  git -C "${main}" init -q
  # commit.gpgsign is on globally on some machines. Signing here launches
  # pinentry against a tty bats does not own, and the commit then blocks until
  # gpg times out — a multi-minute hang that reports as a git failure.
  git -C "${main}" -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    commit -q --allow-empty -m init
  git -C "${main}" worktree add -q -b probe2 "${wt}" 2>/dev/null
  mkdir -p "${wt}/deploy/gcp"
  printf 'x@y.iam.gserviceaccount.com\n' >"${wt}/deploy/gcp/deploy-sa"
  printf 'project_id = "z"\n' >"${wt}/deploy/gcp/bootstrap.tfvars"

  run env REPO_ROOT="${wt}" SOURCE_CHECKOUT="${main}" KUBESEC_AFM_ROOT=/anywhere "$SCRIPT" gate
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Makefile wiring — a guard nothing calls is decoration
# ---------------------------------------------------------------------------

@test "gcp-tf-up invokes the worktree-state guard" {
  # The expensive case is gcp-tf-up, because that is the one that completes a
  # real apply before the misdirected failure. If the macro is defined and never
  # called, the whole thing is inert.
  run bash -c "sed -n '/^gcp-tf-up:/,/^\$/p' '${MAKEFILE}' | grep -c 'gcp_tf_require_worktree_state'"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "the guard runs BEFORE terraform, not after" {
  # Ordering is the entire value proposition. A guard that fires after the apply
  # is the failure it replaces.
  local body; body="$(sed -n '/^gcp-tf-up:/,/^$/p' "${MAKEFILE}")"
  local n_guard n_plan
  n_guard="$(printf '%s\n' "$body" | grep -n 'gcp_tf_require_worktree_state' | head -1 | cut -d: -f1)"
  n_plan="$(printf '%s\n' "$body" | grep -n 'gcp-tf-plan' | head -1 | cut -d: -f1)"
  [ -n "$n_guard" ]
  [ -n "$n_plan" ]
  [ "$n_guard" -lt "$n_plan" ]
}

@test "the guard macro is defined" {
  run grep -c '^define gcp_tf_require_worktree_state' "${MAKEFILE}"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "the guard does not fire when impersonation is already configured" {
  # Every existing gcp-tf-up test supplies either GCP_TF_IMPERSONATE or a real
  # deploy-sa file. The macro is conditioned on impersonation being EMPTY so it
  # targets the real trap and leaves those paths alone.
  local body; body="$(awk '/^define gcp_tf_require_worktree_state/,/^endef/' "${MAKEFILE}")"
  [[ "${body}" == *'GCP_TF_IMPERSONATE'* ]]
}

@test "gcp-tf-up REFUSES when the guard script is missing, rather than skipping it" {
  # Observed for real: an earlier draft wrapped the whole guard in
  # `[ -x $(GCP_TF_WORKTREE_SCRIPT) ]`, and in a worktree where the script was
  # not yet committed gcp-tf-up sailed past it into terraform. A guard whose
  # absence is indistinguishable from its success is not a guard.
  #
  # This runs against a nonexistent script path, so the refusal must come from
  # the guard itself. No terraform runs: the guard precedes it.
  #
  # GCP_TF_DEPLOY_SA_FILE is pointed at a nonexistent path deliberately. With a
  # real deploy-sa present, TF_DEPLOY_SA is non-empty and blanking
  # GCP_TF_IMPERSONATE trips the OLDER impersonation guard first — the test
  # would pass on the wrong refusal. Emptying both reproduces the actual
  # unprovisioned-worktree state, which is the one this guard owns.
  run make -C "${REPO_ROOT}" gcp-tf-up ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    GCP_TF_IMPERSONATE= "GCP_TF_DEPLOY_SA_FILE=${BATS_TEST_TMPDIR}/no-such-deploy-sa" \
    GCP_TF_WORKTREE_SCRIPT=/nonexistent/worktree-bootstrap.sh
  [ "$status" -ne 0 ]
  [[ "${output}" == *"worktree-state guard cannot run"* ]]
  [[ "${output}" == *"Refusing rather than skipping"* ]]
}

@test "the bootstrap and check targets exist and are self-documenting" {
  # `##` is what `make help` renders. A target absent from help is a target
  # nobody finds at the moment they need it, which for this one is while
  # staring at a misleading terraform error.
  run grep -c '^gcp-tf-worktree-bootstrap: ##' "${MAKEFILE}"
  [ "$output" -eq 1 ]
  run grep -c '^gcp-tf-worktree-check: ##' "${MAKEFILE}"
  [ "$output" -eq 1 ]
  run grep -c '^gcp-tf-worktree-status: ##' "${MAKEFILE}"
  [ "$output" -eq 1 ]
}

@test "the script is executable, or every target above is inert" {
  [ -x "${SCRIPT}" ]
}

@test "this suite is discovered by the Makefile's glob, not by a hand list" {
  # The registration trap this repo has hit repeatedly: a suite that matches no
  # glob and appears in no pipeline list runs NOWHERE, green by hand forever.
  run grep -c 'GCP_TF_BATS = \$(sort \$(wildcard test/terraform-\*.bats))' "${MAKEFILE}"
  [ "$output" -eq 1 ]
  # And this file's name really is matched by it.
  case "$(basename "${BATS_TEST_FILENAME}")" in
    terraform-*.bats) ;;
    *) echo "this suite's name is not matched by the gate's glob" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# The premise itself
# ---------------------------------------------------------------------------

@test "the untracked set this tool carries is really untracked" {
  # If any of these became tracked, `git worktree add` would bring it and the
  # tool should stop claiming to be needed for it. Asserting the property keeps
  # the manifest honest rather than merely historical.
  local f
  for f in deploy/gcp/deploy-sa deploy/gcp/bootstrap.tfvars .keys; do
    run git -C "${REPO_ROOT}" check-ignore -q "$f"
    [ "$status" -eq 0 ] || { echo "${f} is no longer gitignored" >&2; return 1; }
  done
}

@test "no item in the manifest is tracked in git" {
  # The paired assertion. check-ignore above proves the ignore rule exists;
  # this proves nothing slipped into the index anyway (a force-add would).
  run bash -c "git -C '${REPO_ROOT}' ls-files -- 'deploy/gcp/deploy-sa' 'deploy/gcp/*.tfvars' 'deploy/gcp/*.handoff.json' '.keys' | grep -v '\.example\.tfvars' || true"
  [ -z "$output" ]
}
