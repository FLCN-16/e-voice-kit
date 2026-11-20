# ==========================================
# Build Stage
# ==========================================
FROM hexpm/elixir:1.16.2-erlang-26.2.3-alpine-3.19.1 AS build

RUN apk add --no-cache bash build-base git rust cargo pkgconf openssl-dev libsrtp-dev

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV=prod

# Install dependencies
COPY mix.exs mix.lock* ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

# Copy application code and compile
COPY config config
COPY lib lib
RUN mix compile

# Build the release
RUN mix release

# ==========================================
# Runtime Stage
# ==========================================
FROM alpine:3.19.1 AS app

RUN apk add --no-cache libstdc++ ncurses-libs openssl libsrtp

WORKDIR /app

ENV MIX_ENV=prod
ENV PORT=4000

COPY --from=build /app/_build/prod/rel/e_voice_kit ./

EXPOSE 4000

CMD ["bin/e_voice_kit", "start"]
