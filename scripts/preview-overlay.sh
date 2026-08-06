#!/bin/bash

set -euo pipefail

command -v ctrlspeak-overlay >/dev/null 2>&1 || {
  echo "ctrlspeak-overlay is not installed. Run ./install.sh first." >&2
  exit 1
}

ctrlspeak-overlay preview
