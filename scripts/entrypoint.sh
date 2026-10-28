#!/bin/bash
# Entry point inside the builder container. Run ./build.sh on the host instead;
# it builds the container image and calls this with the right mounts.
#   server    x86-64 server ISO   -> output/ubuntu-<version>-autoinstall-amd64.iso
#   pi        Raspberry Pi image  -> output/ubuntu-<version>-autoconfig-arm64+raspi.img.xz
#   desktop   x86-64 desktop ISO  -> output/ubuntu-<version>-desktop-autoinstall-amd64.iso
#   all       all three (default)
set -euo pipefail
SCRIPTS="$(dirname "$(readlink -f "$0")")"

case "${1:-all}" in
  server)  "$SCRIPTS/build-iso.sh" server ;;
  desktop) "$SCRIPTS/build-iso.sh" desktop ;;
  pi)      "$SCRIPTS/build-pi.sh" ;;
  all)     "$SCRIPTS/build-iso.sh" server && "$SCRIPTS/build-pi.sh" && "$SCRIPTS/build-iso.sh" desktop ;;
  *)       echo "Usage: ./build.sh [server|pi|desktop|all]" >&2; exit 2 ;;
esac
