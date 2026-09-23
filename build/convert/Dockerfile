# Converter tool image: containerd accelerated-container-image "standalone userspace
# convertor" plus the overlaybd tool binaries it shells out to (/opt/overlaybd/bin), crane
# for cross-repository copies, and curl/jq for Workload Identity tokens. No kernel module
# is needed: the userspace convertor applies layers with overlaybd-apply (libext2fs).
FROM golang:1.26-bookworm AS build
ARG ACI_VERSION=v1.4.5
RUN git clone --depth 1 --branch "${ACI_VERSION}" https://github.com/containerd/accelerated-container-image.git /src
WORKDIR /src
RUN go build -o /out/convertor ./cmd/convertor

FROM debian:bookworm-slim
# The AgentENV fork's static tools: the same binaries the runtime uses to convert on the
# node, so the output format is what its reader expects.
ARG OBD_VERSION=v1.0.18-aenv.1
ARG CRANE_VERSION=v0.22.1
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl jq \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://github.com/kvcache-ai/overlaybd/releases/download/static-${OBD_VERSION}/overlaybd-tools-${OBD_VERSION}-linux-x86_64.tar.gz" \
      | tar -xz -C /tmp \
    && mkdir -p /opt/overlaybd/bin /etc/overlaybd \
    && mv /tmp/bin/* /opt/overlaybd/bin/ && mv /tmp/etc/overlaybd/overlaybd.json /etc/overlaybd/ \
    && rm -rf /tmp/bin /tmp/etc /tmp/licenses /tmp/build-manifest.json
RUN curl -fsSL "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" \
      | tar -xz -C /usr/local/bin crane
COPY --from=build /out/convertor /usr/local/bin/convertor
COPY convert-one.sh run-shard.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/convert-one.sh /usr/local/bin/run-shard.sh
ENTRYPOINT ["/usr/local/bin/run-shard.sh"]
