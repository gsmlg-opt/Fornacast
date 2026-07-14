ARG ELIXIR_IMAGE=elixir:1.20.1-otp-29
ARG DEBIAN_IMAGE=debian:bookworm-slim
ARG RUST_VERSION=1.96.0

FROM ${ELIXIR_IMAGE} AS build

ARG FORNACAST_DATABASE_ADAPTER=turso
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
COPY package.json bun.lock bunfig.toml ./
COPY config config
COPY apps/fornacast_web/package.json apps/fornacast_web/package.json
COPY apps apps

# WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#76
RUN mix deps.get --only prod && \
    mix deps.compile && \
    mix bun.install --if-missing && \
    ./_build/bun install --frozen-lockfile && \
    mix assets.deploy && \
    mix compile && \
    mix release fornacast

FROM ${DEBIAN_IMAGE} AS app

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      libstdc++6 \
      ncurses-base \
      openssl && \
    useradd --create-home --home-dir /app --shell /usr/sbin/nologin fornacast && \
    mkdir -p /data && \
    chown -R fornacast:fornacast /data /app && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build --chown=fornacast:fornacast /app/_build/prod/rel/fornacast ./

ENV HOME=/app \
    PORT=4000 \
    FORNACAST_DATABASE_ADAPTER=turso \
    FORNACAST_DATABASE_PATH=/data/fornacast.db \
    FORNACAST_CONFIG_DATABASE_PATH=/data/fornacast_config.db \
    FORNACAST_REPO_STORAGE_ROOT=/data/repos \
    FORNACAST_SSH_SYSTEM_DIR=/data/ssh

USER fornacast

EXPOSE 4000 2222

CMD ["/app/bin/fornacast", "start"]
