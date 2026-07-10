#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ROOT_DIR}/repos.yaml"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/dev-env.sh" >/dev/null

parse_manifest_name_dest() {
  if [ ! -f "${MANIFEST}" ]; then
    echo "error: missing ${MANIFEST}" >&2
    return 1
  fi

  awk '
    /^[[:space:]]*-[[:space:]]+name:[[:space:]]*/ {
      if (have_name || have_dest) {
        if (!(have_name && have_dest)) {
          print "error: incomplete repo entry in repos.yaml (name/dest required)" > "/dev/stderr";
          exit 2;
        }
        print name "|" dest;
      }
      name=$0; sub(/^[^:]*:[[:space:]]*/, "", name); gsub(/^["\x27]|["\x27]$/, "", name);
      dest="";
      have_name=1; have_dest=0;
      next;
    }
    /^[[:space:]]*dest:[[:space:]]*/ {
      dest=$0; sub(/^[^:]*:[[:space:]]*/, "", dest); gsub(/^["\x27]|["\x27]$/, "", dest);
      have_dest=1;
      next;
    }
    END {
      if (have_name || have_dest) {
        if (!(have_name && have_dest)) {
          print "error: incomplete repo entry in repos.yaml (name/dest required)" > "/dev/stderr";
          exit 2;
        }
        print name "|" dest;
      }
    }
  ' "${MANIFEST}"
}

repo_dest_from_manifest() {
  local target_name="$1"
  local line name dest

  while IFS='|' read -r name dest; do
    [ -n "${name}" ] || continue
    if [ "${name}" = "${target_name}" ]; then
      echo "${dest}"
      return 0
    fi
  done < <(parse_manifest_name_dest)

  return 1
}

append_args_from_file() {
  local file="$1"

  [ -f "${file}" ] || return 0

  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%%#*}"
    line="${line#${line%%[![:space:]]*}}"
    line="${line%${line##*[![:space:]]}}"
    [ -n "${line}" ] || continue
    printf '%s\n' "${line}"
  done < "${file}"
}

install_gnuradio4_test_headers() {
  local build_dir="$1"
  local prefix_dir="$2"
  local ut_include_dir="${build_dir}/_deps/ut-src/include"
  local ut_header="${ut_include_dir}/boost/ut.hpp"
  local dest_dir="${prefix_dir}/include/boost"

  if [ ! -f "${ut_header}" ]; then
    echo "warn: gnuradio4 built without vendored boost-ut header at ${ut_header}" >&2
    return 0
  fi

  mkdir -p "${dest_dir}"
  install -m 0644 "${ut_header}" "${dest_dir}/ut.hpp"

  if [ -f "${ut_include_dir}/boost/ut.cppm" ]; then
    install -m 0644 "${ut_include_dir}/boost/ut.cppm" "${dest_dir}/ut.cppm"
  fi
}

build_cmake_repo() {
  local name="$1"
  local source_dir="$2"
  local repo_dir="$3"
  local bdir="${GR4_BUILD_PATH}/${name}"
  local -a cmake_args
  local c_flags=""
  local cxx_flags=""

  cmake_args=("-DCMAKE_INSTALL_PREFIX=${GR4_PREFIX_PATH}")

  if [ -n "${CPPFLAGS:-}" ] || [ -n "${CFLAGS:-}" ]; then
    c_flags="${CPPFLAGS:-}${CPPFLAGS:+ }${CFLAGS:-}"
    cmake_args+=("-DCMAKE_C_FLAGS=${c_flags}")
  fi
  if [ -n "${CPPFLAGS:-}" ] || [ -n "${CXXFLAGS:-}" ]; then
    cxx_flags="${CPPFLAGS:-}${CPPFLAGS:+ }${CXXFLAGS:-}"
    cmake_args+=("-DCMAKE_CXX_FLAGS=${cxx_flags}")
  fi
  if [ -n "${LDFLAGS:-}" ]; then
    cmake_args+=("-DCMAKE_EXE_LINKER_FLAGS=${LDFLAGS}")
    cmake_args+=("-DCMAKE_SHARED_LINKER_FLAGS=${LDFLAGS}")
    cmake_args+=("-DCMAKE_MODULE_LINKER_FLAGS=${LDFLAGS}")
  fi

  while IFS= read -r arg; do
    cmake_args+=("${arg}")
  done < <(append_args_from_file "${ROOT_DIR}/config/all.cmake.args")

  while IFS= read -r arg; do
    cmake_args+=("${arg}")
  done < <(append_args_from_file "${ROOT_DIR}/config/${name}.cmake.args")

  while IFS= read -r arg; do
    cmake_args+=("${arg}")
  done < <(append_args_from_file "${bdir}/cmake.args")

  mkdir -p "${bdir}"

  # Cap build parallelism when GR4_BUILD_JOBS is set; otherwise use the
  # build tool's default (all cores). Heavy C++23 TUs (e.g. exprtk) use
  # 2-3 GB each, so a low cap avoids OOM on constrained/WSL machines.
  local -a build_jobs=()
  if [ -n "${GR4_BUILD_JOBS:-}" ]; then
    build_jobs=(-j "${GR4_BUILD_JOBS}")
  else
    build_jobs=(-j)
  fi

  echo "==> building ${name} (cmake)"
  cmake -S "${source_dir}" -B "${bdir}" "${cmake_args[@]}"
  cmake --build "${bdir}" "${build_jobs[@]}"
  cmake --install "${bdir}"

  if [ "${name}" = "gnuradio4" ]; then
    install_gnuradio4_test_headers "${bdir}" "${GR4_PREFIX_PATH}"
  fi

  if [ "${name}" = "gnuradio4-studio" ]; then
    echo "==> installing ${name} desktop app"
    (cd "${repo_dir}" && npm install && npm run build)
  fi
}

build_node_repo() {
  local name="$1"
  local repo_dir="$2"

  echo "==> building ${name} (node)"
  (cd "${repo_dir}" && npm install && npm run build)

  if [ "${name}" = "gnuradio4-studio" ]; then
    if [ -z "${GR4_PREFIX_PATH:-}" ]; then
      echo "skip: ${name} install step needs GR4_PREFIX_PATH" >&2
      return 0
    fi

    echo "==> installing ${name} to ${GR4_PREFIX_PATH}"
    (cd "${repo_dir}" && npm run desktop:install -- --prefix "${GR4_PREFIX_PATH}")
  fi
}

build_repo() {
  local name="$1"
  local repo_dir="$2"
  local source_dir="${repo_dir}"
  local source_cfg="${ROOT_DIR}/config/${name}.cmake.source"
  local source_rel=""

  if [ ! -d "${repo_dir}" ]; then
    echo "skip: ${name} repo not found at ${repo_dir}"
    return
  fi

  if [ -f "${source_cfg}" ]; then
    source_rel="$(sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "${source_cfg}" | head -n 1)"
    if [ -n "${source_rel}" ]; then
      source_dir="${repo_dir}/${source_rel}"
    fi
  fi

  if [ -f "${source_dir}/CMakeLists.txt" ]; then
    build_cmake_repo "${name}" "${source_dir}" "${repo_dir}"
  elif [ -f "${repo_dir}/package.json" ]; then
    build_node_repo "${name}" "${repo_dir}"
  else
    echo "skip: no recognized build system for ${name}"
  fi
}

if [ "$#" -gt 0 ]; then
  for repo in "$@"; do
    if repo_dest="$(repo_dest_from_manifest "${repo}")"; then
      build_repo "${repo}" "${ROOT_DIR}/${repo_dest}"
    else
      # Fallback for ad-hoc local repos not listed in repos.yaml.
      build_repo "${repo}" "${GR4_SRC_PATH}/${repo}"
    fi
  done
else
  while IFS='|' read -r repo repo_dest; do
    [ -n "${repo}" ] || continue
    build_repo "${repo}" "${ROOT_DIR}/${repo_dest}"
  done < <(parse_manifest_name_dest)
fi

echo "build-all complete"
