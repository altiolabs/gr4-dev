#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
PRODUCT_DOCKERFILE="${PRODUCT_DOCKERFILE:-${SCRIPT_DIR}/Dockerfile}"
CONTROL_PLANE_DIR="${CONTROL_PLANE_DIR:-${WORKSPACE_DIR}/src/gr4-control-plane}"
REPOS_FILE="${REPOS_FILE:-${WORKSPACE_DIR}/repos.yaml}"

usage() {
  cat <<'EOF'
Usage: build-images.sh [options]

Build gr4-dev product images. Local builds are the default.

Options:
  --profile PROFILE       Builder profile, for example ubuntu-24.04-gcc-14
  --images LIST           Comma-separated products: gnuradio4-sdk,control-plane,studio
  --only LIST             Alias for --images
  --platforms LIST        Docker platform list, for example linux/amd64,linux/arm64
  --push                  Push images with docker buildx
  --local                 Build local images with docker build
  --no-cache              Pass --no-cache to product image builds
  --rebuild-studio-blocks Bust the Studio blocks build stage cache
  --source-mode MODE      Use local or git source for product repos
  --gnuradio4-source SRC  Compatibility alias for --source-mode
  --gnuradio4-ref REF     Git ref used when GNU Radio 4 source is git
  --gr4-incubator-ref REF Git ref used when gr4-incubator source is git
  --control-plane-ref REF Git ref used when gr4-control-plane source is git
  --studio-ref REF        Git ref used when gr4-studio source is git
  --dry-run               Print the derived build configuration and exit
  --print-config          Alias for --dry-run
  -h, --help              Show this help

Common environment overrides:
  PROFILE, IMAGE_NAMESPACE, BUILDER_NAMESPACE, BUILDER_IMAGE, PUSH_IMAGES,
  IMAGES, PLATFORMS, IMAGE_TAG, RUNTIME_BASE_IMAGE, SOURCE_MODE,
  REPOS_FILE, GNURADIO4_REPO, GNURADIO4_REF, GR4_USE_LIBCXX,
  GHCR_TOKEN, GITHUB_TOKEN
EOF
}

DRY_RUN="${DRY_RUN:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { echo "--profile requires a value." >&2; exit 2; }
      PROFILE="$2"
      shift 2
      ;;
    --images|--only)
      [[ $# -ge 2 ]] || { echo "$1 requires a value." >&2; exit 2; }
      IMAGES="$2"
      shift 2
      ;;
    --platforms)
      [[ $# -ge 2 ]] || { echo "--platforms requires a value." >&2; exit 2; }
      PLATFORMS="$2"
      shift 2
      ;;
    --push)
      PUSH_IMAGES=1
      shift
      ;;
    --local)
      PUSH_IMAGES=0
      shift
      ;;
    --no-cache)
      NO_CACHE=1
      shift
      ;;
    --rebuild-studio-blocks)
      REBUILD_STUDIO_BLOCKS=1
      shift
      ;;
    --source-mode)
      [[ $# -ge 2 ]] || { echo "--source-mode requires a value." >&2; exit 2; }
      SOURCE_MODE="$2"
      shift 2
      ;;
    --gnuradio4-source)
      [[ $# -ge 2 ]] || { echo "--gnuradio4-source requires a value." >&2; exit 2; }
      SOURCE_MODE="$2"
      shift 2
      ;;
    --gnuradio4-ref)
      [[ $# -ge 2 ]] || { echo "--gnuradio4-ref requires a value." >&2; exit 2; }
      GNURADIO4_REF="$2"
      shift 2
      ;;
    --gr4-incubator-ref)
      [[ $# -ge 2 ]] || { echo "--gr4-incubator-ref requires a value." >&2; exit 2; }
      GR4_INCUBATOR_REF="$2"
      shift 2
      ;;
    --control-plane-ref)
      [[ $# -ge 2 ]] || { echo "--control-plane-ref requires a value." >&2; exit 2; }
      CONTROL_PLANE_REF="$2"
      shift 2
      ;;
    --studio-ref)
      [[ $# -ge 2 ]] || { echo "--studio-ref requires a value." >&2; exit 2; }
      STUDIO_REF="$2"
      shift 2
      ;;
    --dry-run|--print-config)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

OWNER_DEFAULT="${GITHUB_REPOSITORY_OWNER:-${USER:-local}}"
OWNER="${OWNER:-${OWNER_DEFAULT}}"
OWNER="$(printf '%s' "${OWNER}" | tr '[:upper:]' '[:lower:]')"

GHCR_TOKEN="${GHCR_TOKEN:-${GITHUB_TOKEN:-}}"
GHCR_USER="${GHCR_USER:-$OWNER}"
PUSH_IMAGES="${PUSH_IMAGES:-0}"

if [[ -n "${PROFILE:-}" ]]; then
  IFS='-' read -r profile_family profile_release profile_remainder <<<"${PROFILE}"
  if [[ -z "${profile_family}" || -z "${profile_release}" || -z "${profile_remainder}" ]]; then
    echo "PROFILE must look like <distro>-<release>-<profile>, for example ubuntu-24.04-gcc-14." >&2
    exit 1
  fi
  BUILDER_DISTRO="${BUILDER_DISTRO:-${profile_family}-${profile_release}}"
  BUILDER_PROFILE="${BUILDER_PROFILE:-${profile_remainder}}"
else
  BUILDER_DISTRO="${BUILDER_DISTRO:-ubuntu-24.04}"
  BUILDER_PROFILE="${BUILDER_PROFILE:-clang-20}"
fi

PROFILE="${BUILDER_DISTRO}-${BUILDER_PROFILE}"
if [[ -z "${GR4_USE_LIBCXX:-}" ]]; then
  case "${BUILDER_PROFILE}" in
    clang*) GR4_USE_LIBCXX=ON ;;
    *) GR4_USE_LIBCXX=OFF ;;
  esac
fi

if [[ -z "${IMAGE_NAMESPACE:-}" ]]; then
  if [[ "${PUSH_IMAGES}" == "1" ]]; then
    IMAGE_NAMESPACE="ghcr.io/${OWNER}/gr4-dev"
  else
    IMAGE_NAMESPACE="gr4-dev"
  fi
fi

if [[ -z "${BUILDER_NAMESPACE:-}" ]]; then
  if [[ -n "${BUILDER_TAG_PREFIX:-}" ]]; then
    BUILDER_NAMESPACE="${BUILDER_TAG_PREFIX}"
  elif [[ -n "${BASE_TAG_PREFIX:-}" ]]; then
    BUILDER_NAMESPACE="${BASE_TAG_PREFIX}"
  elif [[ "${PUSH_IMAGES}" == "1" ]]; then
    BUILDER_NAMESPACE="${IMAGE_NAMESPACE}"
  else
    BUILDER_NAMESPACE="gr4-dev"
  fi
fi
BUILDER_TAG_PREFIX="${BUILDER_NAMESPACE}"
BUILDER_IMAGE="${BUILDER_IMAGE:-${BUILDER_NAMESPACE}/${PROFILE}:latest}"

RUNTIME_BASE_IMAGE="${RUNTIME_BASE_IMAGE:-}"
if [[ -z "${RUNTIME_BASE_IMAGE}" ]]; then
  case "${BUILDER_DISTRO}" in
    ubuntu-*) RUNTIME_BASE_IMAGE="ubuntu:${BUILDER_DISTRO#ubuntu-}" ;;
    debian-*) RUNTIME_BASE_IMAGE="debian:${BUILDER_DISTRO#debian-}" ;;
    fedora-*) RUNTIME_BASE_IMAGE="fedora:${BUILDER_DISTRO#fedora-}" ;;
    *)
      echo "Cannot infer RUNTIME_BASE_IMAGE from BUILDER_DISTRO=${BUILDER_DISTRO}; set RUNTIME_BASE_IMAGE explicitly." >&2
      exit 1
      ;;
  esac
fi

repo_value() {
  local repo_name="$1"
  local field="$2"
  awk -v repo_name="${repo_name}" -v field="${field}" '
    $1 == "-" && $2 == "name:" {
      in_repo = ($3 == repo_name)
      next
    }
    in_repo && $1 == field ":" {
      print $2
      exit
    }
  ' "${REPOS_FILE}"
}

if [[ ! -f "${REPOS_FILE}" ]]; then
  echo "Repository manifest not found: ${REPOS_FILE}" >&2
  exit 1
fi

SOURCE_MODE="${SOURCE_MODE:-${GNURADIO4_SOURCE:-}}"
if [[ -z "${SOURCE_MODE}" ]]; then
  if [[ "${PUSH_IMAGES}" == "1" ]]; then
    SOURCE_MODE="git"
  else
    SOURCE_MODE="local"
  fi
fi
case "${SOURCE_MODE}" in
  local|git) ;;
  *)
    echo "SOURCE_MODE must be local or git." >&2
    exit 1
    ;;
esac
GNURADIO4_SOURCE="${SOURCE_MODE}"

GNURADIO4_REPO="${GNURADIO4_REPO:-$(repo_value gnuradio4 url)}"
GNURADIO4_REF="${GNURADIO4_REF:-$(repo_value gnuradio4 ref)}"
GR4_INCUBATOR_REPO="${GR4_INCUBATOR_REPO:-$(repo_value gr4-incubator url)}"
GR4_INCUBATOR_REF="${GR4_INCUBATOR_REF:-$(repo_value gr4-incubator ref)}"
CONTROL_PLANE_REPO="${CONTROL_PLANE_REPO:-$(repo_value gr4-control-plane url)}"
STUDIO_REPO="${STUDIO_REPO:-$(repo_value gr4-studio url)}"

if [[ "${SOURCE_MODE}" == "git" ]]; then
  CONTROL_PLANE_REF="${CONTROL_PLANE_REF:-$(repo_value gr4-control-plane ref)}"
  STUDIO_REF="${STUDIO_REF:-$(repo_value gr4-studio ref)}"
  GNURADIO4_VERSION="${GNURADIO4_VERSION:-${GNURADIO4_REF}}"
else
  CONTROL_PLANE_REF="${CONTROL_PLANE_REF:-$(git -C "${CONTROL_PLANE_DIR}" rev-parse HEAD)}"
  STUDIO_REF="${STUDIO_REF:-$(git -C "${WORKSPACE_DIR}/src/gr4-studio" rev-parse HEAD)}"
  GNURADIO4_VERSION="${GNURADIO4_VERSION:-$(git -C "${WORKSPACE_DIR}/src/gnuradio4" rev-parse --short HEAD)}"
fi

for required_source_dir in gnuradio4 gr4-incubator gr4-control-plane gr4-studio; do
  if [[ "${SOURCE_MODE}" == "local" && ! -d "${WORKSPACE_DIR}/src/${required_source_dir}" ]]; then
    echo "SOURCE_MODE=local requires ${WORKSPACE_DIR}/src/${required_source_dir}." >&2
    exit 1
  fi
done

for required_value in GNURADIO4_REPO GNURADIO4_REF GR4_INCUBATOR_REPO GR4_INCUBATOR_REF CONTROL_PLANE_REPO CONTROL_PLANE_REF STUDIO_REPO STUDIO_REF; do
  if [[ -z "${!required_value}" ]]; then
    echo "${required_value} is empty; check ${REPOS_FILE} or set it explicitly." >&2
    exit 1
  fi
done

GR_SPLIT_BLOCK_INSTANTIATIONS="${GR_SPLIT_BLOCK_INSTANTIATIONS:-OFF}"
if [[ "${SOURCE_MODE}" == "git" ]]; then
  CONTROL_PLANE_VERSION="${CONTROL_PLANE_VERSION:-${CONTROL_PLANE_REF}}"
  STUDIO_VERSION="${STUDIO_VERSION:-${STUDIO_REF}}"
else
  CONTROL_PLANE_VERSION="${CONTROL_PLANE_VERSION:-$(git -C "${CONTROL_PLANE_DIR}" rev-parse --short HEAD)}"
  STUDIO_VERSION="${STUDIO_VERSION:-$(git -C "${WORKSPACE_DIR}/src/gr4-studio" rev-parse --short HEAD)}"
fi
PUBLISH_MULTIARCH="${PUBLISH_MULTIARCH:-0}"
if [[ -z "${PLATFORMS:-}" ]]; then
  if [[ "${PUSH_IMAGES}" == "1" && "${PUBLISH_MULTIARCH}" == "1" ]]; then
    PLATFORMS="${PUBLISH_PLATFORMS:-linux/amd64,linux/arm64}"
  else
    PLATFORMS="${PLATFORM:-linux/amd64}"
  fi
fi
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGES="${IMAGES:-}"
BUILD_GR4_SDK_IMAGE="${BUILD_GR4_SDK_IMAGE:-${BUILD_BASE_IMAGE:-1}}"
BUILD_CONTROL_PLANE_IMAGES="${BUILD_CONTROL_PLANE_IMAGES:-1}"
BUILD_STUDIO_IMAGE="${BUILD_STUDIO_IMAGE:-1}"
BUILDX_PUSH_BUILDER="${BUILDX_PUSH_BUILDER:-gr4-ci}"
NO_CACHE="${NO_CACHE:-0}"
REBUILD_STUDIO_BLOCKS="${REBUILD_STUDIO_BLOCKS:-0}"
STUDIO_BLOCKS_CACHE_BUST="${STUDIO_BLOCKS_CACHE_BUST:-}"
if [[ "${REBUILD_STUDIO_BLOCKS}" == "1" && -z "${STUDIO_BLOCKS_CACHE_BUST}" ]]; then
  STUDIO_BLOCKS_CACHE_BUST="$(date +%s)"
fi

BASE_IMAGE="${BASE_IMAGE:-${IMAGE_NAMESPACE}/gnuradio4-sdk}"
SDK_IMAGE="${SDK_IMAGE:-${IMAGE_NAMESPACE}/gr4-control-plane-sdk}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-${IMAGE_NAMESPACE}/gr4-control-plane-runtime}"
STUDIO_IMAGE="${STUDIO_IMAGE:-${IMAGE_NAMESPACE}/gr4-studio}"

if [[ -n "${IMAGES}" ]]; then
  BUILD_GR4_SDK_IMAGE=0
  BUILD_CONTROL_PLANE_IMAGES=0
  BUILD_STUDIO_IMAGE=0
  IFS=',' read -ra requested_images <<<"${IMAGES}"
  for requested_image in "${requested_images[@]}"; do
    requested_image="${requested_image//[[:space:]]/}"
    case "${requested_image}" in
      gnuradio4-sdk|gr4-sdk|base)
        BUILD_GR4_SDK_IMAGE=1
        ;;
      control-plane|control-plane-images|gr4-control-plane|sdk-runtime)
        BUILD_CONTROL_PLANE_IMAGES=1
        ;;
      studio|gr4-studio)
        BUILD_STUDIO_IMAGE=1
        ;;
      all)
        BUILD_GR4_SDK_IMAGE=1
        BUILD_CONTROL_PLANE_IMAGES=1
        BUILD_STUDIO_IMAGE=1
        ;;
      "")
        ;;
      *)
        echo "Unknown image selection '${requested_image}'. Use gnuradio4-sdk, control-plane, studio, or all." >&2
        exit 1
        ;;
    esac
  done
fi

build_output_args() {
  if [[ "${PUSH_IMAGES}" == "1" ]]; then
    printf '%s\n' "--push"
  fi
}

build_image() {
  local cache_args=()
  if [[ "${NO_CACHE}" == "1" ]]; then
    cache_args+=(--no-cache)
  fi

  if [[ "${PUSH_IMAGES}" == "1" ]]; then
    docker buildx build "${cache_args[@]}" "$@"
  else
    docker build "${cache_args[@]}" "$@"
  fi
}

registry_accessible_image() {
  local image="$1"
  local registry="${image%%/*}"

  [[ "${image}" == */* ]] || return 1
  [[ "${registry}" == *.* || "${registry}" == *:* || "${registry}" == "localhost" ]]
}

common_build_args() {
  local args=(
    --build-arg "GR4_DEV_BUILDER_IMAGE=${BUILDER_IMAGE}" \
    --build-arg "RUNTIME_BASE_IMAGE=${RUNTIME_BASE_IMAGE}" \
    --build-arg "GR4_USE_LIBCXX=${GR4_USE_LIBCXX}"
  )

  if [[ -n "${STUDIO_BLOCKS_CACHE_BUST}" ]]; then
    args+=(--build-arg "STUDIO_BLOCKS_CACHE_BUST=${STUDIO_BLOCKS_CACHE_BUST}")
  fi

  printf '%s\n' "${args[@]}"
}

source_build_args() {
  local args=(
    --build-arg "SOURCE_MODE=${SOURCE_MODE}" \
    --build-arg "GNURADIO4_SOURCE=${SOURCE_MODE}" \
    --build-arg "GNURADIO4_REPO=${GNURADIO4_REPO}" \
    --build-arg "GNURADIO4_REF=${GNURADIO4_REF}" \
    --build-arg "GR4_INCUBATOR_REPO=${GR4_INCUBATOR_REPO}" \
    --build-arg "GR4_INCUBATOR_REF=${GR4_INCUBATOR_REF}" \
    --build-arg "CONTROL_PLANE_REPO=${CONTROL_PLANE_REPO}" \
    --build-arg "CONTROL_PLANE_REF=${CONTROL_PLANE_REF}" \
    --build-arg "STUDIO_REPO=${STUDIO_REPO}" \
    --build-arg "STUDIO_REF=${STUDIO_REF}"
  )

  printf '%s\n' "${args[@]}"
}

build_base() {
  local platform="$1"
  local tag="$2"
  local tags=(-t "${BASE_IMAGE}:${tag}")
  local output_args
  local common_args
  local source_args
  mapfile -t output_args < <(build_output_args)
  mapfile -t common_args < <(common_build_args)
  mapfile -t source_args < <(source_build_args)

  if [[ "${PUSH_IMAGES}" != "1" && "${tag}" != "latest" ]]; then
    tags+=(-t "${BASE_IMAGE}:latest")
  fi

  build_image \
    --file "${PRODUCT_DOCKERFILE}" \
    --platform "${platform}" \
    --target gnuradio4-sdk \
    "${tags[@]}" \
    "${common_args[@]}" \
    "${source_args[@]}" \
    --build-arg GR_SPLIT_BLOCK_INSTANTIATIONS="${GR_SPLIT_BLOCK_INSTANTIATIONS}" \
    --build-arg OCI_SOURCE="${GNURADIO4_REPO}" \
    --build-arg OCI_URL="${GNURADIO4_REPO}" \
    --build-arg OCI_REVISION="${GNURADIO4_VERSION}" \
    --build-arg OCI_VERSION="${GNURADIO4_VERSION}" \
    "${output_args[@]}" \
    "${WORKSPACE_DIR}"
}

check_local_builder_image() {
  if [[ "${PUSH_IMAGES}" == "1" ]]; then
    return
  fi

  if ! docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
    echo "Builder image not found: ${BUILDER_IMAGE}" >&2
    echo "Build it first, for example:" >&2
    echo "  make -C ${SCRIPT_DIR} build-${PROFILE}" >&2
    exit 1
  fi

  if ! docker run --rm "${BUILDER_IMAGE}" sh -c \
      'test -e /usr/include/boost/asio.hpp && test -e /usr/include/boost/beast/core.hpp' \
      >/dev/null 2>&1; then
    echo "Builder image is missing required Boost headers: ${BUILDER_IMAGE}" >&2
    echo "Rebuild the builder image after the prerequisite update:" >&2
    echo "  make -C ${SCRIPT_DIR} build-${PROFILE}" >&2
    exit 1
  fi
}

print_config() {
  cat <<EOF
Profile: ${PROFILE}
Builder distro: ${BUILDER_DISTRO}
Builder profile: ${BUILDER_PROFILE}
Builder namespace: ${BUILDER_NAMESPACE}
Builder image: ${BUILDER_IMAGE}
Runtime base image: ${RUNTIME_BASE_IMAGE}
GR4 use libc++: ${GR4_USE_LIBCXX}
Push images: ${PUSH_IMAGES}
Product platforms: ${PLATFORMS}
Image namespace: ${IMAGE_NAMESPACE}
Image tag: ${IMAGE_TAG}
Build GNU Radio 4 SDK image: ${BUILD_GR4_SDK_IMAGE}
Build control-plane images: ${BUILD_CONTROL_PLANE_IMAGES}
Build Studio image: ${BUILD_STUDIO_IMAGE}
No cache: ${NO_CACHE}
Rebuild Studio blocks: ${REBUILD_STUDIO_BLOCKS}
Studio blocks cache bust: ${STUDIO_BLOCKS_CACHE_BUST:-}
Source mode: ${SOURCE_MODE}
Repos file: ${REPOS_FILE}
GNU Radio 4 repo: ${GNURADIO4_REPO}
GNU Radio 4 ref: ${GNURADIO4_REF}
GNU Radio 4 version: ${GNURADIO4_VERSION}
GR4 incubator repo: ${GR4_INCUBATOR_REPO}
GR4 incubator ref: ${GR4_INCUBATOR_REF}
Control-plane repo: ${CONTROL_PLANE_REPO}
Control-plane ref: ${CONTROL_PLANE_REF}
Studio repo: ${STUDIO_REPO}
Studio ref: ${STUDIO_REF}
GNU Radio 4 SDK image: ${BASE_IMAGE}:${IMAGE_TAG}
Control-plane SDK image: ${SDK_IMAGE}:${IMAGE_TAG}
Control-plane runtime image: ${RUNTIME_IMAGE}:${IMAGE_TAG}
Studio image: ${STUDIO_IMAGE}:${IMAGE_TAG}
EOF
}

if [[ "${DRY_RUN}" == "1" ]]; then
  print_config
  exit 0
fi

if [[ "${PUSH_IMAGES}" == "1" && -n "${GHCR_TOKEN}" ]]; then
  printf '%s' "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin
elif [[ "${PUSH_IMAGES}" == "1" ]]; then
  echo "PUSH_IMAGES=1 requires GHCR_TOKEN or GITHUB_TOKEN for ghcr.io login." >&2
  exit 1
else
  echo "No registry token configured; building images locally with docker build."
fi

NEEDS_CPP_BUILDER=0
if [[ "${BUILD_GR4_SDK_IMAGE}" == "1" || "${BUILD_CONTROL_PLANE_IMAGES}" == "1" ]]; then
  NEEDS_CPP_BUILDER=1
fi

if [[ "${PUSH_IMAGES}" == "1" && "${NEEDS_CPP_BUILDER}" == "1" ]] && ! registry_accessible_image "${BUILDER_IMAGE}"; then
  echo "Push builds need a registry-accessible BUILDER_IMAGE, but ${BUILDER_IMAGE} is local-only." >&2
  echo "Build and push the selected builder with make first, set BUILDER_IMAGE to a pushed image, or run with PUSH_IMAGES=0." >&2
  exit 1
fi

if [[ "${PUSH_IMAGES}" == "1" ]]; then
  docker buildx create --name "${BUILDX_PUSH_BUILDER}" --use >/dev/null 2>&1 || docker buildx use "${BUILDX_PUSH_BUILDER}"
  docker buildx inspect --bootstrap >/dev/null
fi

if [[ "${NEEDS_CPP_BUILDER}" == "1" ]]; then
  check_local_builder_image
fi

print_config

if [[ "${PUSH_IMAGES}" != "1" && "${PLATFORMS}" == *,* ]]; then
  echo "Local docker build supports one platform here; use --push for multi-arch product images." >&2
  exit 1
fi

if [[ "${BUILD_GR4_SDK_IMAGE}" == "1" ]]; then
  echo "Building GNU Radio 4 SDK image for ${PLATFORMS}..."
  build_base "${PLATFORMS}" "${IMAGE_TAG}"
fi

mapfile -t OUTPUT_ARGS < <(build_output_args)
mapfile -t COMMON_ARGS < <(common_build_args)
mapfile -t SOURCE_ARGS < <(source_build_args)

if [[ "${BUILD_CONTROL_PLANE_IMAGES}" == "1" ]]; then
  sdk_tags=(-t "${SDK_IMAGE}:${IMAGE_TAG}")
  runtime_tags=(-t "${RUNTIME_IMAGE}:${IMAGE_TAG}")
  if [[ "${PUSH_IMAGES}" != "1" && "${IMAGE_TAG}" != "latest" ]]; then
    sdk_tags+=(-t "${SDK_IMAGE}:latest")
    runtime_tags+=(-t "${RUNTIME_IMAGE}:latest")
  fi

  echo "Building control-plane SDK image..."
  build_image \
    --file "${PRODUCT_DOCKERFILE}" \
    --platform "${PLATFORMS}" \
    --target sdk \
    "${sdk_tags[@]}" \
    "${COMMON_ARGS[@]}" \
    "${SOURCE_ARGS[@]}" \
    --build-arg GNURADIO4_SDK_IMAGE="${BASE_IMAGE}:${IMAGE_TAG}" \
    --build-arg OCI_SOURCE="${CONTROL_PLANE_REPO}" \
    --build-arg OCI_URL="${CONTROL_PLANE_REPO}" \
    --build-arg OCI_REVISION="${CONTROL_PLANE_REF}" \
    --build-arg OCI_VERSION="${CONTROL_PLANE_VERSION}" \
    "${OUTPUT_ARGS[@]}" \
    "${WORKSPACE_DIR}"

  echo "Building control-plane runtime image..."
  build_image \
    --file "${PRODUCT_DOCKERFILE}" \
    --platform "${PLATFORMS}" \
    --target runtime \
    "${runtime_tags[@]}" \
    "${COMMON_ARGS[@]}" \
    "${SOURCE_ARGS[@]}" \
    --build-arg GNURADIO4_SDK_IMAGE="${BASE_IMAGE}:${IMAGE_TAG}" \
    --build-arg OCI_SOURCE="${CONTROL_PLANE_REPO}" \
    --build-arg OCI_URL="${CONTROL_PLANE_REPO}" \
    --build-arg OCI_REVISION="${CONTROL_PLANE_REF}" \
    --build-arg OCI_VERSION="${CONTROL_PLANE_VERSION}" \
    "${OUTPUT_ARGS[@]}" \
    "${WORKSPACE_DIR}"
fi

if [[ "${BUILD_STUDIO_IMAGE}" == "1" ]]; then
  studio_tags=(-t "${STUDIO_IMAGE}:${IMAGE_TAG}")
  if [[ "${PUSH_IMAGES}" != "1" && "${IMAGE_TAG}" != "latest" ]]; then
    studio_tags+=(-t "${STUDIO_IMAGE}:latest")
  fi

  echo "Building Studio image..."
  build_image \
    --file "${PRODUCT_DOCKERFILE}" \
    --platform "${PLATFORMS}" \
    --target studio \
    "${studio_tags[@]}" \
    "${SOURCE_ARGS[@]}" \
    "${OUTPUT_ARGS[@]}" \
    "${WORKSPACE_DIR}"
fi
