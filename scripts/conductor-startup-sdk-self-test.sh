#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STARTUP_SCRIPT="${ROOT}/scripts/conductor-startup-script-cloud.sh"
WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

command -v git >/dev/null || { echo "SDK self-test failed: git is required" >&2; exit 1; }
real_git="$(command -p -v git)"
function_file="${WORK}/gtm-sdk-dependency-function.sh"
awk '/^gtm_sdk_dependency_repair\(\)/ { copy = 1 } copy { print } copy && /^}$/ { exit }' "${STARTUP_SCRIPT}" >"${function_file}"
# shellcheck disable=SC1090  # the tested function is extracted into this temporary file
source "${function_file}"

record() { printf '%s | %s | %s\n' "$1" "$2" "$3"; }
log() { printf '[startup] %s\n' "$*"; }

fixture="${WORK}/fixture"
fake_bin="${WORK}/bin"
auth_output="${WORK}/auth-output"
uv_args="${WORK}/uv-args"
function_output="${WORK}/function-output"
mock_token="mock-sdk-token"
mkdir -p "${fixture}" "${fake_bin}"
git -C "${fixture}" init -q
printf '[submodule "gtm-sdk"]\n path = gtm-sdk\n url = git@github.com:elviskahoro/gtm-sdk.git\n' >"${fixture}/.gitmodules"
git -C "${fixture}" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,gtm-sdk
printf '[project]\nname = "sdk-self-test"\ndependencies = ["gtm-cli @ editable+gtm-sdk/cli"]\n' >"${fixture}/pyproject.toml"
printf 'source = "editable+gtm-sdk/cli"\n' >"${fixture}/uv.lock"

cat >"${fake_bin}/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail
real_git="${SDK_TEST_REAL_GIT:?}"
is_update=0
helper=""
for arg in "$@"; do
  [[ -z "${GTM_SDK_GITHUB_TOKEN:-}" || "${arg}" != *"${GTM_SDK_GITHUB_TOKEN}"* ]] || exit 93
  [[ "${arg}" == update ]] && is_update=1
  case "${arg}" in
  credential.helper=*) helper="${arg#credential.helper=}" ;;
  esac
done
if [[ "${is_update}" == 1 ]]; then
  [[ -x "${helper}" ]] || exit 91
  printf 'protocol=https\nhost=github.com\npath=elviskahoro/gtm-sdk.git\n\n' | "${helper}" get >"${SDK_TEST_AUTH_OUTPUT}"
  mkdir -p gtm-sdk/cli
  printf '[project]\nname = "gtm-cli"\nversion = "0.2.0"\n' >gtm-sdk/cli/pyproject.toml
  exit 0
fi
exec "${real_git}" "$@"
FAKE_GIT
cat >"${fake_bin}/uv" <<'FAKE_UV'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${GTM_SDK_GITHUB_TOKEN:-}" ]] || exit 92
printf '%s\n' "$@" >"${SDK_TEST_UV_ARGS}"
FAKE_UV
chmod 700 "${fake_bin}/git" "${fake_bin}/uv"

if ! (
  cd "${fixture}"
  PATH="${fake_bin}:${PATH}"
  export PATH
  export SDK_TEST_REAL_GIT="${real_git}"
  export SDK_TEST_AUTH_OUTPUT="${auth_output}"
  export SDK_TEST_UV_ARGS="${uv_args}"
  export GTM_SDK_GITHUB_TOKEN="${mock_token}"
  gtm_sdk_dependency_repair
) >"${function_output}" 2>&1; then
  echo "SDK self-test failed: mocked checkout or uv sync did not succeed" >&2
  exit 1
fi

if ! grep -Fqx "password=${mock_token}" "${auth_output}"; then
  echo "SDK self-test failed: Git did not receive the mock credential" >&2
  exit 1
fi
if ! grep -Fqx 'username=x-access-token' "${auth_output}"; then
  echo "SDK self-test failed: Git credential username was not set" >&2
  exit 1
fi
expected_uv_args="$(printf 'sync\n--dev\n--frozen\n--python\n3.13')"
if [[ "$(<"${uv_args}")" != "${expected_uv_args}" ]]; then
  echo "SDK self-test failed: uv sync arguments differ from the required retry" >&2
  exit 1
fi
if ! printf 'protocol=https\nhost=github.com\npath=other/repo.git\n\n' | GTM_SDK_GITHUB_TOKEN="${mock_token}" "${WORK}/gtm-sdk-credential-helper" get >"${WORK}/wrong-repo-output"; then
  echo "SDK self-test failed: credential helper rejected a non-target lookup" >&2
  exit 1
fi
if [[ -s "${WORK}/wrong-repo-output" ]]; then
  echo "SDK self-test failed: credential helper returned a credential for another repository" >&2
  exit 1
fi
if grep -Fq "${mock_token}" "${function_output}" "${fixture}/.gitmodules"; then
  echo "SDK self-test failed: mock credential appeared in logs or Git configuration" >&2
  exit 1
fi

unrelated="${WORK}/unrelated-repository"
mkdir -p "${unrelated}"
printf '[project]\nname = "unrelated"\n' >"${unrelated}/pyproject.toml"
printf 'version = 1\n' >"${unrelated}/uv.lock"
if ! (cd "${unrelated}" && gtm_sdk_dependency_repair) >"${WORK}/unrelated-output" 2>&1; then
  echo "SDK self-test failed: unrelated repositories should skip the recovery stage" >&2
  exit 1
fi
if ! grep -Fq 'SKIP | gtm-sdk-deps | no locked gtm-sdk/cli dependency' "${WORK}/unrelated-output"; then
  echo "SDK self-test failed: unrelated repository did not skip the SDK recovery stage" >&2
  exit 1
fi
echo "SDK dependency recovery self-test passed"
