#!/bin/bash
set -euo pipefail

# The Apple CLT Python is a build tool only; it is never copied to the app.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 022
exec /usr/bin/python3 -I -B "$(dirname "$0")/build-app.py" "$@"
