#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ROOT_DIR}/repos.yaml"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/dev-env.sh" >/dev/null

GR4_BUILD_MEM_PROFILE="${GR4_BUILD_MEM_PROFILE:-0}"
GR4_MEM_PROFILE_BUILD_SUFFIX="${GR4_MEM_PROFILE_BUILD_SUFFIX:--mem-profile}"
GR4_MEM_PROFILE_WRAPPER="${ROOT_DIR}/scripts/build-mem-profile-wrapper.sh"
GR4_MEM_PROFILE_LOG="${GR4_MEM_PROFILE_LOG:-${ROOT_DIR}/var/logs/build-memory/build-$(date -u '+%Y%m%dT%H%M%SZ').tsv}"
GR4_MEM_PROFILE_SUMMARY_PRINTED=0

mem_profile_enabled() {
  case "${GR4_BUILD_MEM_PROFILE}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

init_mem_profile_log() {
  mem_profile_enabled || return 0

  if [ ! -x "${GR4_MEM_PROFILE_WRAPPER}" ]; then
    echo "error: memory profiling wrapper is not executable: ${GR4_MEM_PROFILE_WRAPPER}" >&2
    return 1
  fi

  mkdir -p "$(dirname "${GR4_MEM_PROFILE_LOG}")"
  printf 'timestamp\trepo\tkind\tmax_rss_kb\telapsed_seconds\texit_status\toutput\tprimary_input\tcommand\n' > "${GR4_MEM_PROFILE_LOG}"
  export GR4_MEM_PROFILE_LOG

  echo "==> build memory profiling enabled"
  echo "==> memory profile log: ${GR4_MEM_PROFILE_LOG}"
}

print_mem_profile_summary() {
  mem_profile_enabled || return 0
  [ -f "${GR4_MEM_PROFILE_LOG}" ] || return 0
  [ "${GR4_MEM_PROFILE_SUMMARY_PRINTED}" = "0" ] || return 0
  GR4_MEM_PROFILE_SUMMARY_PRINTED=1

  echo "==> top build memory users (max RSS)"
  awk -F '\t' '
    NR > 1 && $4 ~ /^[0-9]+$/ {
      mib = $4 / 1024;
      label = $7;
      if (label == "") {
        label = $8;
      }
      if (label == "") {
        label = $9;
      }
      printf "%12.1f MiB\t%s\t%s\t%s\n", mib, $2, $3, label;
    }
  ' "${GR4_MEM_PROFILE_LOG}" | sort -nr | head -n "${GR4_MEM_PROFILE_TOP:-20}"
}

print_mem_profile_summary_on_exit() {
  local status="$?"
  print_mem_profile_summary
  exit "${status}"
}

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

is_studio_repo() {
  local name="$1"

  [ "${name}" = "gr4-studio" ] || [ "${name}" = "gnuradio4-studio" ]
}

build_cmake_repo() {
  local name="$1"
  local source_dir="$2"
  local repo_dir="$3"
  local default_bdir="${GR4_BUILD_PATH}/${name}"
  local bdir="${default_bdir}"
  local -a cmake_args
  local c_flags=""
  local cxx_flags=""

  if mem_profile_enabled; then
    bdir="${default_bdir}${GR4_MEM_PROFILE_BUILD_SUFFIX}"
  fi

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
  done < <(append_args_from_file "${default_bdir}/cmake.args")

  if [ "${bdir}" != "${default_bdir}" ]; then
    while IFS= read -r arg; do
      cmake_args+=("${arg}")
    done < <(append_args_from_file "${bdir}/cmake.args")
  fi

  if mem_profile_enabled; then
    cmake_args+=("-DUSE_CCACHE=OFF")
    cmake_args+=("-DCMAKE_C_COMPILER_LAUNCHER=${GR4_MEM_PROFILE_WRAPPER}")
    cmake_args+=("-DCMAKE_CXX_COMPILER_LAUNCHER=${GR4_MEM_PROFILE_WRAPPER}")
    cmake_args+=("-DCMAKE_C_LINKER_LAUNCHER=${GR4_MEM_PROFILE_WRAPPER}")
    cmake_args+=("-DCMAKE_CXX_LINKER_LAUNCHER=${GR4_MEM_PROFILE_WRAPPER}")
  fi

  mkdir -p "${bdir}"

  echo "==> building ${name} (cmake)"
  cmake -S "${source_dir}" -B "${bdir}" "${cmake_args[@]}"
  GR4_MEM_PROFILE_REPO="${name}" cmake --build "${bdir}" -j
  cmake --install "${bdir}"

  if [ "${name}" = "gnuradio4" ]; then
    install_gnuradio4_test_headers "${bdir}" "${GR4_PREFIX_PATH}"
  fi

  if is_studio_repo "${name}"; then
    echo "==> installing ${name} desktop app"
    (cd "${repo_dir}" && npm install && npm run build)
  fi
}

build_node_repo() {
  local name="$1"
  local repo_dir="$2"

  echo "==> building ${name} (node)"
  (cd "${repo_dir}" && npm install && npm run build)

  if is_studio_repo "${name}"; then
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

init_mem_profile_log
if mem_profile_enabled; then
  trap print_mem_profile_summary_on_exit EXIT
fi

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

print_mem_profile_summary

echo "build-all complete"
