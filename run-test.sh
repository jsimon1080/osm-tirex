#!/bin/bash

set -euo pipefail

set -x

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sleep infinity &
    child=$!
    wait "$child"

    exit 0

echo "invalid command"
exit 1
