# =============================================================================
# Stage 1 — Dependencies
# Debian-based Elixir matches the runtime (debian:bookworm-slim / glibc).
# Multi-arch image so --platform linux/arm64 in buildx resolves the arm64
# variant — ERTS in the release is compiled for the same libc as the runtime.
# =============================================================================
FROM elixir:1.20.0-otp-29 AS deps

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency manifests first — Docker layer cache means deps only
# reinstall when mix.exs or mix.lock changes, not on every code change
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config/config.exs config/prod.exs ./config/
RUN mix deps.compile

# =============================================================================
# Stage 2 — Compile Application
# Must happen BEFORE assets.deploy so Mix.Project.build_path() is populated
# esbuild resolves phoenix-colocated via NODE_PATH pointing to _build/
# =============================================================================
FROM deps AS builder

COPY config/runtime.exs ./config/
COPY lib ./lib
COPY priv ./priv

RUN mix compile

# =============================================================================
# Stage 3 — Assets
# Tailwind v4 + esbuild via standalone binaries
# phoenix-colocated resolves from _build/ via NODE_PATH in config/config.exs
# =============================================================================
FROM builder AS assets

COPY assets ./assets

RUN mix tailwind.install --if-missing && \
    mix esbuild.install --if-missing

RUN mix assets.deploy

# =============================================================================
# Stage 4 — Release
# Build self-contained Elixir release binary
# =============================================================================
FROM assets AS release

RUN mix release

# =============================================================================
# Stage 5 — Production Runtime
# Ubuntu 24.04 LTS ships with glibc 2.39 — satisfies the glibc 2.38 minimum
# that ERTS 17 (OTP 29) binaries are compiled against. Debian bookworm-slim
# only has glibc 2.36 and causes "GLIBC_2.38 not found" at startup.
# Final image contains only the compiled release binary — no source code,
# no mix, no hex, no build tools.
# =============================================================================
FROM ubuntu:24.04 AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 \
    libncurses6 \
    locales \
    ca-certificates \
    bash \
    curl \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Create non-root user — never run as root in production
RUN groupadd -g 1000 appgroup && \
    useradd -u 1000 -g appgroup -s /bin/bash -m appuser

WORKDIR /app

# Copy only the compiled release from release stage
# No source code, no mix, no hex, no build tools in final image
COPY --from=release --chown=appuser:appgroup \
    /app/_build/prod/rel/mangocms ./

USER appuser

EXPOSE 4000

# Health check — used by docker compose and smoke test in Jenkins
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -sf http://localhost:4000/health || exit 1

CMD ["sh", "-c", "PHX_SERVER=true ./bin/mangocms start"]
