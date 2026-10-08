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
COPY --chmod=755 Server/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN mkdir -p /app/data && chown vapor:vapor /app/data

ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static
# SQLite lives on a volume by default. Set DATABASE_URL to use Postgres instead.
ENV SQLITE_PATH=/app/data/battleships.sqlite
VOLUME /app/data
EXPOSE 8080

# The container starts as root only so the entrypoint can give a root-owned volume (as Fly.io and
# Railway mount them) to the `vapor` user; the server itself always runs as `vapor`.
ENTRYPOINT ["docker-entrypoint", "./BattleshipServer"]
# The port comes from $PORT (default 8080), which is what most hosting platforms set.
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0"]

# /health checks the database too. Bash's /dev/tcp does the request, so the image needs no curl.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PORT:-8080} && printf 'GET /health HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n' >&3 && head -n 1 <&3 | grep -q ' 200 '"]
