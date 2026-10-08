# syntax=docker/dockerfile:1
#
# Build from the repository root (the server depends on ../BattleshipKit):
#
#   docker build -f Server/Dockerfile -t battleships-server .
#   docker run -p 8080:8080 -v battleships-data:/app/data battleships-server

# ================================
# Build image
# ================================
FROM swift:6.3-noble AS build

RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y libjemalloc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Resolve dependencies first so Docker can cache them between code changes.
COPY BattleshipKit/Package.swift ./BattleshipKit/
COPY Server/Package.swift Server/Package.resolved ./Server/
RUN cd Server && swift package resolve \
        $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

COPY BattleshipKit ./BattleshipKit
COPY Server ./Server

RUN cd Server && swift build -c release \
        --product BattleshipServer \
        --static-swift-stdlib \
        -Xlinker -ljemalloc

WORKDIR /staging
RUN cp "$(swift build --package-path /build/Server -c release --show-bin-path)/BattleshipServer" ./ \
    && cp "/usr/libexec/swift/linux/swift-backtrace-static" ./ \
    && find -L "$(swift build --package-path /build/Server -c release --show-bin-path)/" -regex '.*\.resources$' -exec cp -Ra {} ./ \;

# ================================
# Run image
# ================================
FROM ubuntu:noble

RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y libjemalloc2 ca-certificates tzdata libcurl4 \
    && rm -r /var/lib/apt/lists/*

RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor
WORKDIR /app
COPY --from=build --chown=vapor:vapor /staging /app
RUN mkdir -p /app/data && chown vapor:vapor /app/data

ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static
# SQLite lives on a volume by default. Set DATABASE_URL to use Postgres instead.
ENV SQLITE_PATH=/app/data/battleships.sqlite
VOLUME /app/data

USER vapor:vapor
EXPOSE 8080

ENTRYPOINT ["./BattleshipServer"]
# The port comes from $PORT (default 8080), which is what most hosting platforms set.
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0"]
