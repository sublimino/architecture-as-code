FROM python:3.12-slim

ARG KUBECTL_VERSION=v1.33.2
ARG KUBECTL_SHA256_AMD64=33d0cdec6967817468f0a4a90f537dfef394dcf815d91966ca651cc118393eea
ARG KUBECTL_SHA256_ARM64=54dc02c8365596eaa2b576fae4e3ac521db9130e26912385e1e431d156f8344d
ARG TARGETARCH

# This image serves BOTH demos: demo_runner.install_demo_runner_api mounts the
# supercred router and the signalfusion router, so one root answers for both.
# They are separate variables because demo_runner.DemoConfig gives each demo
# type its own, and each resolves independently — an unset one is a 503 for
# that demo alone, which is exactly how Signal Fusion failed while SuperCred
# worked.
ENV SUPERCRED_DEMO_CWD=/repo \
    SIGNALFUSION_DEMO_CWD=/repo \
    PYTHONPATH=/repo/d2-signalloom/apps/fe-signalloom/src \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl wget \
    && rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
      amd64) kubectl_sha256="${KUBECTL_SHA256_AMD64}" ;; \
      arm64) kubectl_sha256="${KUBECTL_SHA256_ARM64}" ;; \
      *) echo "Unsupported TARGETARCH for kubectl: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && echo "${kubectl_sha256}  /tmp/kubectl" | sha256sum --check \
    && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && rm -f /tmp/kubectl

COPY d2-signalloom/apps/fe-signalloom/src/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
    && rm -f /tmp/requirements.txt

# Keep the container cwd at the repo root so the demo script can apply the
# repo-relative manifests unchanged; PYTHONPATH and uvicorn's --app-dir point
# imports at src/ without moving that cwd away from /repo.
WORKDIR /repo

COPY scripts/supercred-demo.sh /repo/scripts/supercred-demo.sh
COPY scripts/supercred-images.sh /repo/scripts/supercred-images.sh
COPY scripts/supercred-state.sh /repo/scripts/supercred-state.sh
# The evidence probe the dashboard's Credential Lifecycle card runs via
# GET /api/demo/supercred/evidence. This image COPYs scripts individually rather
# than the whole scripts/ tree, so a script that is not named here simply is not
# in the pod — the endpoint would 503 with evidence_script_unavailable on every
# request while working perfectly from a developer's terminal.
COPY scripts/supercred-evidence.sh /repo/scripts/supercred-evidence.sh
# The Signal Fusion three-act demo, served at /api/demo/signalfusion by the
# same process. Its absence from this image — not the unset environment
# variable the error named — is why all three acts returned 503
# demo_root_unresolved on the live lane. It needs nothing from the repo but
# scripts/lib/wait.sh below; it applies no manifests.
COPY scripts/signalfusion-demo.sh /repo/scripts/signalfusion-demo.sh
COPY scripts/lib /repo/scripts/lib
COPY d2-signalloom/apps/cardvault/base /repo/d2-signalloom/apps/cardvault/base
COPY d2-signalloom/apps/policy-engine/base /repo/d2-signalloom/apps/policy-engine/base
COPY d2-signalloom/apps/fe-signalloom/base/agents-cardvault-sa.yaml /repo/d2-signalloom/apps/fe-signalloom/base/agents-cardvault-sa.yaml
COPY d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml /repo/d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml
COPY d2-signalloom/apps/fe-signalloom/base/agents-cardvault-job.yaml /repo/d2-signalloom/apps/fe-signalloom/base/agents-cardvault-job.yaml
COPY d2-signalloom/infra/inf-bao/configs/base/networkpolicy.yaml /repo/d2-signalloom/infra/inf-bao/configs/base/networkpolicy.yaml
COPY d2-signalloom/apps/fe-signalloom/src /repo/d2-signalloom/apps/fe-signalloom/src
COPY scripts/supercred-crictl-shim.sh /usr/local/bin/docker

RUN chmod 0755 /repo/scripts/supercred-demo.sh /repo/scripts/supercred-images.sh /repo/scripts/supercred-state.sh /repo/scripts/signalfusion-demo.sh /usr/local/bin/docker \
    && chmod -R a+rX /repo \
    && groupadd --system appgroup \
    && useradd --system --gid appgroup appuser \
    && chown -R appuser:appgroup /repo

# The build identity, written where scripts/check-deployed-staleness.sh reads it
# back out of the RUNNING container. Declared here rather than at the top of the
# file so that a changed fingerprint invalidates only this final layer instead
# of every COPY and pip install above it.
#
# Written while still root — appuser could not create a file in /etc — and left
# world-readable so the readback works whichever user the pod ends up running as.
ARG SOURCE_ID
ARG GIT_REF
RUN test -n "$SOURCE_ID" \
    && printf 'workload=supercred-demo-runner\nsource_id=%s\ngit_ref=%s\n' \
         "$SOURCE_ID" "${GIT_REF:-unknown}" > /etc/osramp-build-id \
    && chmod 0644 /etc/osramp-build-id

USER appuser
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget --no-verbose --tries=1 --spider http://localhost:8000/health || exit 1
CMD ["uvicorn", "--app-dir", "/repo/d2-signalloom/apps/fe-signalloom/src", "demo_runner_main:app", "--host", "0.0.0.0", "--port", "8000"]
