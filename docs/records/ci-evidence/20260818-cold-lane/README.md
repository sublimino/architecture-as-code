# Cold-lane evidence, 2026-08-18

`f365a4f-summary.json` is the only surviving record that the image-identity
blocker was cleared. It is kept here because the CI report directory rotates
exactly ONE generation: a run writes `ci-reports-2/` and moves the previous set
to `ci-reports-2.prev/`. Two more cold runs in that checkout and this record is
gone.

That matters more than it looks. Before the diffID fix, both GCP lanes ABORTED
at `phase=build-images` with `total_stages: 0` — the guard compared
`docker image inspect .Id` (a manifest digest under the containerd image store)
against `crictl`'s IMAGE ID (a config digest), which can never match on the CI
VMs. This run is the proof it was fixed:

    commit f365a4f   outcome FAIL   total_stages 27   passed 21   failed 6

FAIL, not PASS — the 6 residual failures were attributed at the time to the
concurrent terraform work, a fixture gap since closed in db74cc4, and a
pre-existing VM-only guard-falsification issue. The load-bearing fact is
`total_stages: 27`, not the verdict: the pipeline reached and completed the
suite where it previously could not start.

It is also the ONLY CI run in which `live-data.spec.ts` has ever executed, and
it is where that spec found the `/rbac-explorer -> /api/rbac/clusters` 503.

`f365a4f-report.yaml.gz` is the full OpenReports artifact for the same run.
