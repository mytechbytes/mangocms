# =============================================================================
# Stage 1 — Dependencies
# Elixir 1.20.0 / OTP 29 / Alpine (latest as of June 2026)
# Using same base image in ALL stages — guarantees identical OpenSSL version
# across build and runtime — prevents crypto.so symbol mismatch
# =============================================================================
FROM elixir:1.20.0-otp-29-alpine AS deps

RUN apk add --no-cache \
    build-base \
    git \
    curl

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency files first — layer cache means deps only
# reinstall when mix.exs or mix.lock changes
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config/config.exs config/prod.exs ./config/
RUN mix deps.compile

# =============================================================================
# Stage 2 — Compile Application
# Must happen BEFORE assets.deploy so Mix.Project.build_path() is populated
# esbuild NODE_PATH needs _build/ to resolve phoenix-colocated/mangocms
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
# =============================================================================
FROM assets AS release

RUN mix release

# =============================================================================
# Stage 5 — Production Runtime
# SAME base image as build stages — identical OpenSSL — no crypto.so mismatch
# Strip out mix/hex/build tools — keep only the compiled release binary
# =============================================================================
FROM elixir:1.20.0-otp-29-alpine AS runtime

# Remove build tools — not needed at runtime
RUN apk del --no-cache \
    build-base 2>/dev/null || true

# Add only what runtime needs
RUN apk add --no-cache \
    bash \
    openssl \
    ca-certificates \
    ncurses-libs

# Create non-root user
RUN addgroup -g 1000 appgroup && \
    adduser -u 1000 -G appgroup -s /bin/sh -D appuser

WORKDIR /app

# Copy only the compiled release — no source, no mix, no hex
COPY --from=release --chown=appuser:appgroup \
    /app/_build/prod/rel/mangocms ./

USER appuser

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:4000/health || exit 1

CMD ["sh", "-c", "PHX_SERVER=true ./bin/mangocms start"]
