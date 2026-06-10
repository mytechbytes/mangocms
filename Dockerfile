# =============================================================================
# Stage 1 — Dependencies
# Fetch and compile all Elixir dependencies
# =============================================================================
FROM elixir:1.17-otp-27-alpine AS deps

# Install build tools
RUN apk add --no-cache \
    build-base \
    git \
    curl

# Set build environment
ENV MIX_ENV=prod

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency files first — layer cache means deps only
# reinstall when mix.exs or mix.lock changes
COPY mix.exs mix.lock ./

# Fetch dependencies
RUN mix deps.get --only prod

# Copy config files needed for dependency compilation
COPY config/config.exs config/prod.exs ./config/

# Compile dependencies only
RUN mix deps.compile

# =============================================================================
# Stage 2 — Assets
# Build Tailwind v4 + esbuild via Mix standalone binaries
# No npm or Node.js needed — Phoenix 1.8 default setup
# =============================================================================
FROM deps AS assets

# Copy application source
COPY lib ./lib
COPY priv ./priv
COPY assets ./assets

# Download standalone Tailwind and esbuild binaries
# These are managed by Mix deps, not npm
RUN mix tailwind.install --if-missing && \
    mix esbuild.install --if-missing

# Compile and digest assets
RUN mix assets.deploy

# =============================================================================
# Stage 3 — Release Build
# Compile application and build Elixir release
# =============================================================================
FROM assets AS builder

# Copy runtime config
COPY config/runtime.exs ./config/

# Compile the application
RUN mix compile

# Build the production release
# Creates a self-contained binary under _build/prod/rel/mangocms
RUN mix release

# =============================================================================
# Stage 4 — Production Runtime
# Minimal Alpine image — no build tools, no source code
# =============================================================================
FROM alpine:3.20 AS runtime

# Install only what the released binary needs at runtime
RUN apk add --no-cache \
    libstdc++ \
    libgcc \
    ncurses-libs \
    openssl \
    ca-certificates \
    bash

# Create non-root user for security
RUN addgroup -g 1000 appgroup && \
    adduser -u 1000 -G appgroup -s /bin/sh -D appuser

WORKDIR /app

# Copy only the compiled release from builder stage
# No source code, no mix, no hex, no build tools in final image
COPY --from=builder --chown=appuser:appgroup \
    /app/_build/prod/rel/mangocms ./

# Switch to non-root user
USER appuser

# Phoenix default port
EXPOSE 4000

# Health check — verify the HTTP endpoint is responding
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:4000/health || exit 1

# Start the release
# PHX_SERVER=true enables the HTTP endpoint in releases
CMD ["sh", "-c", "PHX_SERVER=true ./bin/mangocms start"]
