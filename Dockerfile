# Halvo node — sing-box + cloudflared + Nezha agent, all binaries baked in at build time.
# Target plan: FreeCore 0.25 vCPU / 256MB RAM. Final image is plain Alpine + busybox
# plus three static Go binaries; no Node/Python/runtime downloads at container start.

ARG SING_BOX_VERSION=1.14.4
ARG CLOUDFLARED_VERSION=2026.10.7
ARG NEZHA_VERSION=v2.4.0

# ---------- builder: download the three official binaries ----------
FROM alpine:3.21 AS builder
ARG SING_BOX_VERSION
ARG CLOUDFLARED_VERSION
ARG NEZHA_VERSION
RUN apk add --no-cache curl unzip tar ca-certificates
WORKDIR /dl
RUN set -eu; \
    case "$(uname -m)" in \
      x86_64)  A=amd64 ;; \
      aarch64) A=arm64 ;; \
      *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;; \
    esac; \
    echo "arch: $A"; \
    curl -fsSL -o sing-box.tar.gz \
      "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${A}.tar.gz"; \
    tar -xzf sing-box.tar.gz; \
    mv "sing-box-${SING_BOX_VERSION}-linux-${A}/sing-box" /dl/sing-box; \
    curl -fsSL -o cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${A}"; \
    curl -fsSL -o nezha-agent.zip \
      "https://github.com/nezhahq/agent/releases/download/${NEZHA_VERSION}/nezha-agent_linux_${A}.zip"; \
    unzip -o nezha-agent.zip -d /dl/nezha; \
    mv /dl/nezha/nezha-agent /dl/nezha-agent; \
    chmod +x /dl/sing-box /dl/cloudflared /dl/nezha-agent; \
    /dl/sing-box version; /dl/cloudflared --version; ls -la /dl

# ---------- final image ----------
FROM alpine:3.21
# ca-certificates: cloudflared/nezha need a root store for their TLS connections.
RUN apk add --no-cache ca-certificates && rm -rf /var/cache/apk/*
WORKDIR /app
COPY --from=builder /dl/sing-box /dl/cloudflared /dl/nezha-agent /usr/local/bin/
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh && mkdir -p /app/www /app/run
EXPOSE 3000
ENV PORT=3000
# entrypoint.sh stays as PID 1 supervisor shell; each child runs in its own restart loop.
CMD ["/bin/sh", "/app/entrypoint.sh"]
