#!/bin/sh
# Hosting platforms (Fly.io, Railway, ...) mount volumes owned by root, which the unprivileged
# `vapor` user can't write to, so SQLite fails with "unable to open database file". Started as
# root, this hands the SQLite directory (and the database files in it, in case an earlier run
# created them as root) to `vapor`, then runs the server as `vapor`. Started as any other user
# (docker run --user, Kubernetes runAsUser), it just runs the server.
set -eu

if [ "$(id -u)" = "0" ]; then
    if [ -z "${DATABASE_URL:-}" ]; then
        database="${SQLITE_PATH:-/app/data/battleships.sqlite}"
        directory="$(dirname "$database")"
        # Never anything recursive, and never the root directory: only what SQLite needs to write.
        if [ "$directory" != "/" ]; then
            mkdir -p "$directory"
            chown vapor:vapor "$directory"
            for file in "$database" "$database-wal" "$database-shm" "$database-journal"; do
                if [ -e "$file" ]; then
                    chown vapor:vapor "$file"
                fi
            done
        fi
    fi
    exec setpriv --reuid=vapor --regid=vapor --init-groups "$@"
fi

exec "$@"
