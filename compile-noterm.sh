#!/bin/bash
# compile.sh without the progress bar in the last terminal line (for logs, docker,
# CI). Kept for existing calls; same as "./compile.sh --noterm".
cd "$(dirname "$0")" && exec ./compile.sh --noterm "$@"
