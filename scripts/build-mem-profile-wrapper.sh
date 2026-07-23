#!/usr/bin/env bash
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "error: build memory profiler wrapper needs a command" >&2
  exit 2
fi

if [ ! -x /usr/bin/time ]; then
  echo "error: /usr/bin/time is required for build memory profiling" >&2
  exec "$@"
fi

log_file="${GR4_MEM_PROFILE_LOG:-}"
repo="${GR4_MEM_PROFILE_REPO:-unknown}"
kind="${GR4_MEM_PROFILE_KIND:-auto}"

if [ -z "${log_file}" ]; then
  exec "$@"
fi

mkdir -p "$(dirname "${log_file}")"

output=""
primary_input=""
prev=""
for arg in "$@"; do
  if [ "${prev}" = "-o" ]; then
    output="${arg}"
    prev=""
    continue
  fi

  if [ "${prev}" = "-c" ]; then
    primary_input="${arg}"
    prev=""
    continue
  fi

  case "${arg}" in
    -o)
      prev="-o"
      ;;
    -c)
      prev="-c"
      if [ "${kind}" = "auto" ]; then
        kind="compile"
      fi
      ;;
    -E)
      if [ "${kind}" = "auto" ]; then
        kind="preprocess"
      fi
      ;;
    -o*)
      if [ -z "${output}" ]; then
        output="${arg#-o}"
      fi
      ;;
    *.c|*.cc|*.cpp|*.cxx|*.C|*.m|*.mm)
      if [ -z "${primary_input}" ]; then
        primary_input="${arg}"
      fi
      ;;
    *.o|*.a|*.so|*.dylib|*.lib)
      if [ -z "${primary_input}" ]; then
        primary_input="${arg}"
      fi
      ;;
  esac
done

if [ "${kind}" = "auto" ]; then
  kind="link"
fi

cmd=""
printf -v cmd '%q ' "$@"
cmd="${cmd% }"

time_file="$(mktemp "${TMPDIR:-/tmp}/gr4-build-mem.XXXXXX")"
trap 'rm -f "${time_file}"' EXIT

set +e
/usr/bin/time -f '%M\t%e\t%x' -o "${time_file}" "$@"
status="$?"
set -e

if IFS=$'\t' read -r max_rss_kb elapsed_seconds time_status < "${time_file}"; then
  :
else
  max_rss_kb=""
  elapsed_seconds=""
  time_status="${status}"
fi

timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
line="${timestamp}"$'\t'"${repo}"$'\t'"${kind}"$'\t'"${max_rss_kb}"$'\t'"${elapsed_seconds}"$'\t'"${time_status:-${status}}"$'\t'"${output}"$'\t'"${primary_input}"$'\t'"${cmd}"

if command -v flock >/dev/null 2>&1; then
  {
    flock 9
    printf '%s\n' "${line}" >> "${log_file}"
  } 9>>"${log_file}.lock"
else
  printf '%s\n' "${line}" >> "${log_file}"
fi

exit "${status}"
