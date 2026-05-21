#!/usr/bin/env bash
set -euo pipefail

# Edit this list to control which production image stacks are built.
PROFILES=(
  ubuntu-24.04-gcc-14
  ubuntu-24.04-gcc-15
  ubuntu-24.04-clang-20
)

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: build-production-profiles.sh [build-images.sh options]

Build gr4-dev production images for each profile listed at the top of this
script. All options are passed through to build-images.sh.

By default, each build uses IMAGE_TAG=<profile> so profile variants do not
overwrite each other. Set IMAGE_TAG explicitly to override that behavior.

Examples:
  images/build-production-profiles.sh
  images/build-production-profiles.sh --push
  images/build-production-profiles.sh --push --platforms linux/amd64,linux/arm64
  OWNER=altiolabs images/build-production-profiles.sh --push
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

for profile in "${PROFILES[@]}"; do
  echo "Building production images for ${profile}..."

  if [[ -n "${IMAGE_TAG:-}" ]]; then
    "${SCRIPT_DIR}/build-images.sh" --profile "${profile}" "$@"
  else
    IMAGE_TAG="${profile}" "${SCRIPT_DIR}/build-images.sh" --profile "${profile}" "$@"
  fi
done
