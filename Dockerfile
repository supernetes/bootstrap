# Base environment
FROM alpine:3 as base

RUN apk --no-cache upgrade && \
    apk --no-cache add bash bash-completion cosign curl g++ git helm jq k9s kubectl kustomize less linux-headers make moreutils nano nano-syntax openssl pipx python3-dev yq

# Build environment for tooling
FROM base as build

RUN mkdir /build /out
WORKDIR /build

# Talos
FROM build as talos

RUN curl -fL https://talos.dev/install | sh && cp /usr/local/bin/talosctl /out/

# Flux
FROM build as flux

RUN curl -fL https://fluxcd.io/install.sh | bash && cp /usr/local/bin/flux /out/

# Cilium
FROM build as cilium

RUN CILIUM_CLI_VERSION=$(curl -fL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt) && \
    CLI_ARCH=amd64 && if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi && \
    curl -fL --remote-name-all https://github.com/cilium/cilium-cli/releases/download/"${CILIUM_CLI_VERSION}"/cilium-linux-"${CLI_ARCH}".tar.gz{,.sha256sum} && \
    sha256sum -c cilium-linux-"${CLI_ARCH}".tar.gz.sha256sum && \
    tar xzvf cilium-linux-"${CLI_ARCH}".tar.gz -C /out/ && \
    rm -r /build

# Hubble CLI
FROM build as hubble

RUN HUBBLE_VERSION=$(curl -fL https://raw.githubusercontent.com/cilium/hubble/master/stable.txt) && \
    HUBBLE_ARCH=amd64 && if [ "$(uname -m)" = "aarch64" ]; then HUBBLE_ARCH=arm64; fi && \
    curl -L --fail --remote-name-all https://github.com/cilium/hubble/releases/download/"${HUBBLE_VERSION}"/hubble-linux-"${HUBBLE_ARCH}".tar.gz{,.sha256sum} && \
    sha256sum -c hubble-linux-"${HUBBLE_ARCH}".tar.gz.sha256sum && \
    tar xzvf hubble-linux-"${HUBBLE_ARCH}".tar.gz -C /out/ && \
    rm -r /build

# SOPS
FROM build as sops

RUN set -x && \
    SOPS_CLI_VERSION=$(curl -fL https://api.github.com/repos/getsops/sops/releases/latest | jq -r ".tag_name") && \
    CLI_ARCH=amd64 && if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi && \
    curl -fL --remote-name-all https://github.com/getsops/sops/releases/download/"${SOPS_CLI_VERSION}"/sops-"${SOPS_CLI_VERSION}".{linux."${CLI_ARCH}",checksums.txt,checksums.pem,checksums.sig} && \
    cosign verify-blob sops-"${SOPS_CLI_VERSION}".checksums.txt \
      --certificate sops-"${SOPS_CLI_VERSION}".checksums.pem \
      --signature sops-"${SOPS_CLI_VERSION}".checksums.sig \
      --certificate-identity-regexp=https://github.com/getsops \
      --certificate-oidc-issuer=https://token.actions.githubusercontent.com && \
    grep sops-"${SOPS_CLI_VERSION}".linux."${CLI_ARCH}" sops-"${SOPS_CLI_VERSION}".checksums.txt > sops-"${SOPS_CLI_VERSION}".checksums.filtered.txt && \
    sha256sum -c sops-"${SOPS_CLI_VERSION}".checksums.filtered.txt && \
    mv sops-"${SOPS_CLI_VERSION}".linux."${CLI_ARCH}" /out/sops && chmod +x /out/sops && \
    rm -r /build

# Krew
FROM build as krew

RUN CLI_ARCH=amd64 && if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi && KREW=krew-linux_"${CLI_ARCH}" && \
    curl -fL --remote-name-all https://github.com/kubernetes-sigs/krew/releases/latest/download/"${KREW}".tar.gz{,.sha256} && \
    echo "$(cat "${KREW}".tar.gz.sha256) ${KREW}.tar.gz" > "${KREW}".tar.gz.sha256sum && \
    sha256sum -c "${KREW}".tar.gz.sha256sum && \
    tar xzvf "${KREW}".tar.gz && \
    ./"${KREW}" install krew && \
    mv ~/.krew /out/ && \
    rm -r /build

# Management container image
FROM base

# Installation
WORKDIR /usr/local/bin
COPY --from=talos /out/ .
COPY --from=flux /out/ .
COPY --from=cilium /out/ .
COPY --from=hubble /out/ .
COPY --from=sops /out/ .

WORKDIR /root
COPY --from=krew /out/ .

# Configuration
ENV EDITOR=nano
ENV HISTCONTROL=ignoreboth
RUN update-ca-certificates && \
    talosctl completion bash >> ~/.bashrc && \
    cilium completion bash >> ~/.bashrc && \
    hubble completion bash >> ~/.bashrc && \
    flux completion bash >> ~/.bashrc && \
    sed -ri 's|^# (set afterends)$|\1|' /etc/nanorc && \
    sed -ri 's|^# (include "/usr/share/nano/\*\.nanorc")$|\1|' /etc/nanorc && \
    register-python-argcomplete pipx >> ~/.bashrc && pipx ensurepath && \
    pipx install python-openstackclient && ~/.local/bin/openstack complete >> ~/.bashrc && \
    echo "pipx install -e /bootstrap &> /dev/null &" >> ~/.bashrc && \
    echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc
#    PATH="$HOME/.krew/bin:$PATH" kubectl krew install ...

# Sleep forever, use `exec` to enter the container
ENTRYPOINT ["/bin/sh", "-c", "trap 'exit 0' INT TERM; sleep infinity & wait"]

