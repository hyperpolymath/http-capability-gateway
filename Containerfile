# SPDX-License-Identifier: PMPL-1.0-or-later
# Multi-stage Containerfile for http-capability-gateway

# Stage 1: Build
FROM docker.io/hexpm/elixir:1.19.4-erlang-28.2.2-alpine-3.22.1 AS builder

# Install build dependencies
RUN apk add --no-cache build-base git

# Set working directory
WORKDIR /app

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files
COPY mix.exs mix.lock ./

# Install dependencies
RUN mix deps.get --only prod

# Copy application code
COPY config ./config
COPY lib ./lib
COPY priv ./priv

# Compile application
ENV MIX_ENV=prod
RUN mix compile

# Build release
RUN mix release

# Stage 2: Runtime
FROM docker.io/alpine:3.22.1

# Install runtime dependencies
RUN apk add --no-cache \
    libstdc++ \
    ncurses-libs \
    openssl

# Create non-root user
RUN addgroup -S gateway && \
    adduser -S -G gateway -h /home/gateway gateway

# Set working directory
WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=gateway:gateway /app/_build/prod/rel/http_capability_gateway ./

# Switch to non-root user
USER gateway

# Expose port
EXPOSE 4000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:4000/health || exit 1

# Run the application
CMD ["bin/http_capability_gateway", "start"]
