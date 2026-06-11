# =============================================================================
# MangoCMS CI Runner Image
#
# Purpose : Run mix test, credo, dialyzer inside Jenkins pipeline
# Based on: elixir:1.20.0-otp-29-alpine (matches production Dockerfile)
# Built by: developer manually — only rebuild when Elixir/OTP version changes
# Used by : Jenkins pipeline stages (Quality Checks, Tests & Coverage)
# NOT used: in production — this image never runs on Instance 2
# =============================================================================
FROM elixir:1.20.0-otp-29-alpine

# Install system dependencies required for CI
# git        — required for Git-sourced Mix deps (heroicons etc)
# build-base — required for native extension compilation
# curl       — required for downloading binaries
# bash       — required for Jenkins pipeline shell scripts
RUN apk add --no-cache \
    git \
    build-base \
    curl \
    bash \
    python3

# Pre-install hex and rebar — skips this step on every pipeline run
# Baked into image so pipeline doesn't reinstall on every build
RUN mix local.hex --force && \
    mix local.rebar --force

WORKDIR /app
