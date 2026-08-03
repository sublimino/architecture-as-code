FROM python:3.12-slim

ARG KUBECTL_VERSION=v1.33.2
ARG KUBECTL_SHA256_AMD64=33d0cdec6967817468f0a4a90f537dfef394dcf815d91966ca651cc118393eea
ARG KUBECTL_SHA256_ARM64=54dc02c8365596eaa2b576fae4e3ac521db9130e26912385e1e431d156f8344d
ARG TARGETARCH

ENV SUPERCRED_DEMO_CWD=/repo \
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
COPY scripts/lib /repo/scripts/lib
COPY d2-signalloom/apps/cardvault/base /repo/d2-signalloom/apps/cardvault/base
COPY d2-signalloom/apps/policy-engine/base /repo/d2-signalloom/apps/policy-engine/base
COPY d2-signalloom/apps/fe-signalloom/base/agents-cardvault-sa.yaml /repo/d2-signalloom/apps/fe-signalloom/base/agents-cardvault-sa.yaml
COPY d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml /repo/d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml
COPY d2-signalloom/apps/fe-signalloom/base/agents-cardvault-job.yaml /repo/d2-signalloom/apps/fe-signalloom/base/agents-cardvault-job.yaml
COPY d2-signalloom/infra/inf-bao/configs/base/networkpolicy.yaml /repo/d2-signalloom/infra/inf-bao/configs/base/networkpolicy.yaml
COPY d2-signalloom/apps/fe-signalloom/src /repo/d2-signalloom/apps/fe-signalloom/src
COPY scripts/supercred-crictl-shim.sh /usr/local/bin/docker

RUN chmod 0755 /repo/scripts/supercred-demo.sh /repo/scripts/supercred-images.sh /repo/scripts/supercred-state.sh /usr/local/bin/docker \
    && chmod -R a+rX /repo \
    && groupadd --system appgroup \
    && useradd --system --gid appgroup appuser \
    && chown -R appuser:appgroup /repo

USER appuser
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget --no-verbose --tries=1 --spider http://localhost:8000/health || exit 1
CMD ["uvicorn", "--app-dir", "/repo/d2-signalloom/apps/fe-signalloom/src", "demo_runner_main:app", "--host", "0.0.0.0", "--port", "8000"]
