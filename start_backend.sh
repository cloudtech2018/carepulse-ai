#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

PORT="${1:-8765}"
MAC_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"

echo "Starting CarePulse backend on port ${PORT}..."
if [[ -n "${MAC_IP}" ]]; then
  echo "Use this on iPhone Safari: http://${MAC_IP}:${PORT}/health"
  echo "Use this in the app Backend URL: http://${MAC_IP}:${PORT}"
else
  echo "Could not read the Wi-Fi IP automatically."
  echo "Use System Settings > Wi-Fi > Details to find the Mac IP address."
fi

python3 backend/server.py --host 0.0.0.0 --port "${PORT}"
