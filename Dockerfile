ARG ELIXIR_IMAGE=elixir:1.20.1-otp-29
ARG DEBIAN_IMAGE=debian:trixie-slim
ARG RUST_VERSION=1.96.0

FROM ${ELIXIR_IMAGE} AS build

ARG FORNACAST_DATABASE_ADAPTER=postgres
ARG RUST_VERSION
ENV MIX_ENV=prod \
    FORNACAST_DATABASE_ADAPTER=${FORNACAST_DATABASE_ADAPTER} \
    LANG=C.UTF-8 \
    CARGO_HOME=/root/.cargo \
    RUSTUP_HOME=/root/.rustup
ENV PATH="${CARGO_HOME}/bin:${PATH}"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      git \
      libssl-dev \
      pkg-config && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
      sh -s -- -y --profile minimal --default-toolchain ${RUST_VERSION} && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY package.json package-lock.json ./
COPY config config
COPY apps/fornacast_web/package.json apps/fornacast_web/package.json
COPY apps apps

RUN mix deps.get --only prod && \
    mix deps.compile && \
    mix npm.ci && \
    mix assets.deploy && \
    mix compile && \
    mix release fornacast

FROM ${DEBIAN_IMAGE} AS app

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      coreutils \
      curl \
      git \
      libstdc++6 \
      libsctp1 \
      ncurses-base \
      openssl && \
    useradd --create-home --home-dir /app --shell /usr/sbin/nologin fornacast && \
    mkdir -p /data && \
    chown -R fornacast:fornacast /data /app && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build --chown=fornacast:fornacast /app/_build/prod/rel/fornacast ./
COPY --chown=fornacast:fornacast \
  scripts/release_asset_storage_smoke.sh \
  /app/bin/release_asset_storage_smoke

ENV LANG=C.UTF-8 \
    SHELL=/bin/sh \
    HOME=/app \
    PORT=4890 \
    FORNACAST_API_BIND_IP=0.0.0.0 \
    FORNACAST_API_PORT=4891 \
    FORNACAST_DATABASE_ADAPTER=postgres \
    FORNACAST_CONFIG_DATABASE_PATH=/data/fornacast_config.db \
    FORNACAST_LEGACY_TURSO_DATABASE_PATH=/data/fornacast.db \
    FORNACAST_REPO_STORAGE_ROOT=/data/repos \
    FORNACAST_RELEASE_ASSET_STORAGE_ROOT=/data/release-assets \
    FORNACAST_RELEASE_ASSET_MAX_BYTES=2147483648 \
    FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS=86400 \
    FORNACAST_SSH_SYSTEM_DIR=/data/ssh \
    ELIXIR_ERL_OPTIONS="-kernel inet_dist_use_interface {127,0,0,1}" \
    ERL_EPMD_ADDRESS=127.0.0.1 \
    RELEASE_DISTRIBUTION=name \
    RELEASE_NODE=fornacast@127.0.0.1

USER fornacast

EXPOSE 4890 4891 2222

CMD ["/app/bin/fornacast", "start"]
