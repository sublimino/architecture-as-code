FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY go.mod go.sum processor.go ./
RUN go mod download && CGO_ENABLED=0 go build -o processor-service .


FROM node:trixie-slim

RUN DEBIAN_FRONTEND=noninteractive \
    apt update && apt install --assume-yes --no-install-recommends  \
        jq curl findutils coreutils bash  \
        bash-completion  \
        bsdextrautils  \
        ca-certificates  \
        nmap  \
        ncat  \
        net-tools  \
        openssh-client  \
        moreutils  \
        parallel  \
        procps  \
        wget  \
        bc git git-man less libcurl3t64-gnutls liberror-perl libexpat1 libngtcp2-16  \
        libngtcp2-crypto-gnutls8 libreadline8t64 patch readline-common  \
    && rm -rf /var/lib/apt/lists/*

RUN printf "\n  alias ll='ls -lasp'\n  alias lt='ll -t'\n  alias ..='cd ..'\n  alias ...='cd ..\..'\n  alias h='cat'\n  (grep PRETTY /etc/*rel* -h || true)\n  if [[ -d '${WORKDIR:-}' ]]; then cd '${WORKDIR}'; fi;\n  PS1=\$(echo 'XHVAXGg6XHcgWyQ/XVwkIAo=' | base64 -d)\n  "  \
    >> /root/.bashrc

# Install nats
RUN curl -sf https://binaries.nats.dev/nats-io/natscli/nats@v0.2.4 | PREFIX=/bin/ sh
# Install syft for SBOM generation
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin
# Install cosign (arch specific)
RUN DPKG_ARCH="$(dpkg --print-architecture)"  \
    && LATEST_VERSION="$(curl https://api.github.com/repos/sigstore/cosign/releases/latest | grep tag_name | cut -d : -f2 | tr -d "v\", ")"  \
    && curl -O -L "https://github.com/sigstore/cosign/releases/latest/download/cosign_${LATEST_VERSION}_${DPKG_ARCH}.deb"  \
    && dpkg -i "cosign_${LATEST_VERSION}_${DPKG_ARCH}.deb"  \
    && rm "cosign_${LATEST_VERSION}_${DPKG_ARCH}.deb"
# Install trivy
RUN curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
# Install witness
RUN curl -s https://raw.githubusercontent.com/in-toto/witness/main/install-witness.sh | bash

COPY --from=builder /app/processor-service /app/processor-service
COPY processor.sh /app/processor
COPY enhance_sbom_with_dependencies.sh /app/enhance_sbom_with_dependencies
RUN chmod +x /app/processor /app/enhance_sbom_with_dependencies /app/processor-service \
    && chown 65532:65532 /app/processor /app/processor-service \
    && mkdir -p /.npm /tmp/npm-cache \
    && chown -R 65532:65532 /.npm /tmp/npm-cache
USER 65532:65532
ENV NPM_CONFIG_CACHE=/tmp/npm-cache
ENTRYPOINT ["/app/processor-service"]
