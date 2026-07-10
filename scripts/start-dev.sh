#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/dev-env.sh" >/dev/null

RUN_DIR="${ROOT_DIR}/var/run"
LOG_DIR="${ROOT_DIR}/var/logs"
PID_FILE="${RUN_DIR}/control-plane.pid"
LOG_FILE="${LOG_DIR}/control-plane.log"

mkdir -p "${RUN_DIR}" "${LOG_DIR}"

if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" >/dev/null 2>&1; then
  echo "control-plane already running with pid $(cat "${PID_FILE}")"
else
  rm -f "${PID_FILE}"

  CP_REPO="${GR4_SRC_PATH}/gnuradio4-control-plane"
  CP_BIN_WORKSPACE="${GR4_BUILD_PATH}/gnuradio4-control-plane/gr4cp_server"
  CP_BIN_REPO="${CP_REPO}/build/gr4cp_server"
  CP_BIN_INSTALL="${GR4_PREFIX_PATH}/bin/gr4cp_server"

  if [ -x "${CP_BIN_WORKSPACE}" ]; then
    (
      "${CP_BIN_WORKSPACE}" >>"${LOG_FILE}" 2>&1 &
      echo $! >"${PID_FILE}"
    )
    echo "started gnuradio4-control-plane server (workspace build) pid=$(cat "${PID_FILE}")"
  elif [ -x "${CP_BIN_REPO}" ]; then
    (
      "${CP_BIN_REPO}" >>"${LOG_FILE}" 2>&1 &
      echo $! >"${PID_FILE}"
    )
    echo "started gnuradio4-control-plane server (repo-local build) pid=$(cat "${PID_FILE}")"
  elif [ -x "${CP_BIN_INSTALL}" ]; then
    (
      "${CP_BIN_INSTALL}" >>"${LOG_FILE}" 2>&1 &
      echo $! >"${PID_FILE}"
    )
    echo "started gnuradio4-control-plane server (installed) pid=$(cat "${PID_FILE}")"
  elif [ -f "${CP_REPO}/package.json" ]; then
    (
      cd "${CP_REPO}"
      npm run dev >>"${LOG_FILE}" 2>&1 &
      echo $! >"${PID_FILE}"
    )
    echo "started gnuradio4-control-plane (npm run dev) pid=$(cat "${PID_FILE}")"
  else
    echo "could not determine how to start gnuradio4-control-plane"
    echo "check repo at ${CP_REPO}"
    exit 1
  fi
fi

echo "control-plane url: ${GR4_CONTROL_PLANE_URL}"
echo "logs: ${LOG_FILE}"
echo "studio: start separately with: (cd ${GR4_SRC_PATH}/gnuradio4-studio && npm run dev)"
