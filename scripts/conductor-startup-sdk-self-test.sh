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
awk '/^gtm_sdk_write_credential_helper\(\)/ { copy = 1 } /^gtm_sdk_dependency_repair\(\)/ { copy = 1; in_repair = 1 } copy { print } in_repair && /^}$/ { exit }' "${STARTUP_SCRIPT}" >"${function_file}"
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
  # shellcheck disable=SC2030  # PATH is scoped to this subshell on purpose
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

# Git-source lock (gtm-sdk resolved from GitHub, no submodule): the sync must
# run with the token reachable only through a command-scoped credential
# helper plus an identity insteadOf rule, never a URL, argument or log line.
git_fixture="${WORK}/git-source-fixture"
git_bin="${WORK}/git-source-bin"
git_auth="${WORK}/git-source-auth"
git_env="${WORK}/git-source-env"
mkdir -p "${git_fixture}" "${git_bin}"
printf '[project]\nname = "sdk-git-self-test"\ndependencies = ["gtm-sdk"]\n' >"${git_fixture}/pyproject.toml"
printf 'source = { git = "https://github.com/elviskahoro/gtm-sdk.git?branch=main#5ba99a147724fbea4bf9e4ea7899b4c8b023f88a" }\n' >"${git_fixture}/uv.lock"
cat >"${git_bin}/uv" <<'FAKE_GIT_UV'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${GTM_SDK_GITHUB_TOKEN:-}" ]] || exit 92
printf '%s\n' "$@" >"${SDK_TEST_UV_ARGS}"
helper=""
rule=""
reset=0
for ((i = 0; i < ${GIT_CONFIG_COUNT:?}; i++)); do
  key_var="GIT_CONFIG_KEY_${i}"
  val_var="GIT_CONFIG_VALUE_${i}"
  if [[ "${!key_var}" == credential.helper ]]; then
    if [[ -z "${!val_var}" ]]; then reset=1; else helper="${!val_var}"; fi
  fi
  [[ "${!key_var}" == url.https://github.com/elviskahoro/gtm-sdk.insteadOf ]] && rule="${!val_var}"
done
[[ "${reset}" == 1 && -x "${helper}" ]] || exit 91
[[ "${rule}" == https://github.com/elviskahoro/gtm-sdk ]] || exit 94
printf 'protocol=https\nhost=github.com\npath=elviskahoro/gtm-sdk.git\n\n' | "${helper}" get >"${SDK_TEST_AUTH_OUTPUT}"
FAKE_GIT_UV
chmod 700 "${git_bin}/uv"
if ! (
  cd "${git_fixture}"
  # shellcheck disable=SC2031  # PATH here is the parent value on purpose
  PATH="${git_bin}:${PATH}" SDK_TEST_UV_ARGS="${git_env}" SDK_TEST_AUTH_OUTPUT="${git_auth}" GTM_SDK_GITHUB_TOKEN="${mock_token}" gtm_sdk_dependency_repair
) >"${WORK}/git-source-output" 2>&1; then
  echo "SDK self-test failed: git-source sync did not succeed" >&2
  exit 1
fi
if ! grep -Fqx "password=${mock_token}" "${git_auth}"; then
  echo "SDK self-test failed: git-source sync did not hand Git the mock credential" >&2
  exit 1
fi
if [[ "$(<"${git_env}")" != "${expected_uv_args}" ]]; then
  echo "SDK self-test failed: git-source uv sync arguments differ" >&2
  exit 1
fi
if grep -Fq "${mock_token}" "${WORK}/git-source-output"; then
  echo "SDK self-test failed: mock credential appeared in git-source output" >&2
  exit 1
fi
if ! grep -Fq 'PASS | gtm-sdk-deps' "${WORK}/git-source-output"; then
  echo "SDK self-test failed: git-source sync did not record PASS" >&2
  exit 1
fi
# shellcheck disable=SC2016  # the single-quoted program is evaluated by the inner bash
if (cd "${git_fixture}" && env -u GTM_SDK_GITHUB_TOKEN bash -c 'source "$1"; record() { :; }; log() { :; }; gtm_sdk_dependency_repair' _ "${function_file}") >/dev/null 2>&1; then
  echo "SDK self-test failed: git-source sync must fail without GTM_SDK_GITHUB_TOKEN" >&2
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
