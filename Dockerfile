# =============================================================================
# Stage 1 — Dependencies
# =============================================================================
FROM elixir:1.17-otp-27-alpine AS deps

RUN apk add --no-cache \
    build-base \
    git \
    curl

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config/config.exs config/prod.exs ./config/
RUN mix deps.compile

# =============================================================================
# Stage 2 — Compile Application
# Must happen BEFORE assets.deploy so Mix.Project.build_path() is populated
# esbuild NODE_PATH needs compiled artifacts to resolve phoenix-colocated
# =============================================================================
FROM deps AS builder

# Copy runtime config
COPY config/runtime.exs ./config/

# Copy application source
COPY lib ./lib
COPY priv ./priv

# Compile application — populates _build/
# This makes Mix.Project.build_path() resolvable for esbuild
RUN mix compile

# =============================================================================
# Stage 3 — Assets
# Now esbuild can resolve phoenix-colocated/mangocms via NODE_PATH
# because _build/ is populated from Stage 2
# =============================================================================
FROM builder AS assets

COPY assets ./assets

RUN mix tailwind.install --if-missing && \
    mix esbuild.install --if-missing

# esbuild resolves phoenix-colocated via:
# NODE_PATH = ../deps + Mix.Project.build_path() (_build/prod)
RUN mix assets.deploy

# =============================================================================
# Stage 4 — Release
# =============================================================================
FROM assets AS release

RUN mix release

# =============================================================================
# Stage 5 — Production Runtime
# Minimal Alpine — compiled binary only
# =============================================================================
FROM alpine:3.20 AS runtime

RUN apk add --no-cache \
    libstdc++ \
    libgcc \
    ncurses-libs \
    openssl \
    ca-certificates \
    bash

RUN addgroup -g 1000 appgroup && \
    adduser -u 1000 -G appgroup -s /bin/sh -D appuser

WORKDIR /app

COPY --from=release --chown=appuser:appgroup \
    /app/_build/prod/rel/mangocms ./

USER appuser

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:4000/health || exit 1

CMD ["sh", "-c", "PHX_SERVER=true ./bin/mangocms start"]