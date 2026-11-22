#!/bin/bash
set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 022
exec /usr/bin/python3 -I -B "$(dirname "$0")/build-runtime.py" "$@"
