#!/usr/bin/env bash
# Start oCIS on a macOS runner from its official darwin-arm64 release binary
# (progress.md Task 6.2, AC-2 end-to-end tier). Hosted macOS runners have no
# container runtime, so the same oCIS version pinned for Docker is downloaded as
# a native binary here. Version comes from test/fixtures/versions.env (AC-7).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../versions.env"

: "${OCIS_VERSION:?OCIS_VERSION must be set in versions.env}"

WORK_DIR="${OCIS_WORK_DIR:-${TMPDIR:-/tmp}/ocis-macos}"
mkdir -p "${WORK_DIR}"
BIN="${WORK_DIR}/ocis"

if [[ ! -x "${BIN}" ]]; then
  URL="https://github.com/owncloud/ocis/releases/download/v${OCIS_VERSION}/ocis-${OCIS_VERSION}-darwin-arm64"
  echo "Downloading oCIS ${OCIS_VERSION} for darwin-arm64 …"
  curl -fSL "${URL}" -o "${BIN}"
  chmod +x "${BIN}"
fi

export OCIS_URL="https://localhost:9200"
export OCIS_INSECURE="true"
export OCIS_LOG_LEVEL="error"
export PROXY_TLS="true"
export IDM_ADMIN_PASSWORD="${IDM_ADMIN_PASSWORD:-admin}"
export IDM_CREATE_DEMO_USERS="false"
export OCIS_BASE_DATA_PATH="${WORK_DIR}/data"
export OCIS_CONFIG_DIR="${WORK_DIR}/config"

"${BIN}" init --insecure true || true
exec "${BIN}" server
