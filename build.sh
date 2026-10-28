#!/bin/bash
# Build the images. Run from anywhere:
#   ./build.sh            all three images below
#   ./build.sh server     x86-64 server autoinstall ISO (Kubernetes node)
#   ./build.sh pi         Raspberry Pi image (Kubernetes node)
#   ./build.sh desktop    x86-64 desktop autoinstall ISO, for local VMs
#
# Settings come from config/. Any config/build.env setting can be overridden for
# one run from the environment, e.g.  K8S_VERSION=v1.36 ./build.sh server
#
# This script builds (or refreshes) the builder Docker image automatically; it's
# a quick no-op when nothing changed. Set BUILDER_IMAGE to use another image name.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
IMAGE="${BUILDER_IMAGE:-ubuntu-auto-iso-builder}"

# Settings passed through to the container when set in your environment.
PASSTHROUGH_VARS=(
  UBUNTU_VERSION ISO_BASE_URL PI_BASE_URL ADMIN_USER ADMIN_PASSWORD PASSWORD_HASH
  ISO_HOSTNAME_PREFIX PI_HOSTNAME_PREFIX DESKTOP_HOSTNAME_PREFIX LOCALE KEYBOARD_LAYOUT TIMEZONE
  SSH_ALLOW_PASSWORD K8S_VERSION ISO_REQUIRE_CONFIRMATION ISO_BOOT_TIMEOUT PI_KERNEL_ARGS SKIP_CHECKSUM
)

die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-all}" in
  server|pi|desktop|all) TARGET="${1:-all}" ;;
  -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown target '$1'. Usage: ./build.sh [server|pi|desktop|all]" ;;
esac

# 1. Docker must be installed and reachable.
command -v docker >/dev/null 2>&1 || die "Docker is not installed. See https://docs.docker.com/engine/install/"
if ! docker_err="$(docker info 2>&1 >/dev/null)"; then
  if grep -qi "permission denied" <<< "$docker_err"; then
    die "Your user can't talk to Docker. Add yourself to the docker group (sudo usermod -aG docker \$USER, then log out and back in), or run: sudo ./build.sh"
  fi
  die "Docker isn't running or can't be reached:
$docker_err"
fi

# 2. Build or refresh the builder image. Docker's cache makes this near-instant
#    when the Dockerfile and scripts/ haven't changed. .dockerignore keeps
#    downloads/ and output/ out of the build context.
echo "## Preparing builder image '$IMAGE' (the first run takes a few minutes)..."
build_log="$(mktemp)"
trap 'rm -f "$build_log"' EXIT
if ! docker build -t "$IMAGE" "$PROJECT_DIR" > "$build_log" 2>&1; then
  cat "$build_log" >&2
  die "Building the builder image failed (see above)."
fi
rm -f "$build_log"

# 3. Run the build as you (not root), so downloads/ and output/ belong to you.
#    Under sudo, use the invoking user's IDs.
uid="${SUDO_UID:-$(id -u)}"
gid="${SUDO_GID:-$(id -g)}"

run_args=(--rm -v "$PROJECT_DIR:/data" --user "$uid:$gid")
[ -t 0 ] && [ -t 1 ] && run_args+=(-it)
for name in "${PASSTHROUGH_VARS[@]}"; do
  [ -n "${!name+x}" ] && run_args+=(-e "$name")
done

exec docker run "${run_args[@]}" "$IMAGE" "$TARGET"
