#!/usr/bin/env bash
# shellcheck disable=SC2312  # $(...) in assignments and rows: stage failures surface through the stages' own || returns and the summary, not by killing the script mid-row
# The single Conductor workspace startup script: the sandbox CLIs agents
# call directly (rwx + auth, infisical, resend, railway, entire, uv) plus Python 3.13.
# Code-dev tooling (roborev, pytest, reflex, ruff, pyright, pyrefly, trunk)
# is NOT installed here; it runs as RWX tasks (issue #185, see
# skills/conductor-startup-script).
#
# Two consumers, one file:
#   1. This repo's own workspaces: .conductor/settings.toml runs it. On the
#      AL2023/Vercel sandbox class (dnf, passwordless sudo, user
#      vercel-sandbox) the default python3 is 3.9, hence the python stage.
#   2. Any other repo's workspaces: paste this file's contents into the
#      setup-script field in the Conductor GUI (stored as scripts.setup).
#      Conductor has no API for that field; fixes land in THIS file only and
#      the paste is a hand-refreshed snapshot. Also runs standalone:
#        bash scripts/conductor-startup-script-cloud.sh
#      Repo-agnostic by design: the optional SDK recovery only activates when
#      the locked project references gtm-sdk/cli; no consumer path is assumed.
#
# Also: gws (npm) + gtm-linear/gtm-attio (uv pip) after uv, plus gws credentials.
# Stages: rwx (pinned, checksum-verified) -> infisical -> resend -> railway -> entire
# (with git-remote-entire, which git needs on PATH for entire:// remotes) ->
# python3.13 installed ALONGSIDE 3.9 via dnf on AL2023 (SKIP elsewhere) ->
# uv (pinned, checksum-verified) -> gws/gtm CLIs -> optional gtm-sdk dependency
# recovery -> rwx auth (token validated BEFORE it is persisted, so a bad token
# never overwrites a good one).
#
# Pins: RWX_PIN/INFISICAL_PIN/RESEND_PIN/RAILWAY_PIN/ENTIRE_PIN/UV_PIN and every sha256
# are the single in-repo home of those constants; scripts/validate-pins.sh
# checks them (uv is also cross-checked against envs/prebuilt and
# envs/floxhub-provision). Bump: new pin + sha256s from the release's
# checksums (hand-hash tarballs where none is published).
#
# Paste-safety (Conductor serializes the GUI field into a TOML multiline
# string): NO triple-double-quote sequences and NO backslash
# line-continuations. No process substitution (sandboxes can lack /dev/fd);
# log to ~/.conductor-setup.log via plain append redirect; idempotent; one
# WORK dir cleaned by an EXIT trap.
#
# Failure posture: always fatal. Every stage records a PASS/WARN/FAIL/SKIP
# row; any FAIL fails the run at the very end, after all stages reported.
#
# Environment: RWX_ACCESS_TOKEN (set in Conductor's environment variables,
# never inline). Without it rwx installs but stays unauthenticated (WARN).
set -euo pipefail

# Save the original stdout/stderr as fd 3/4 BEFORE the log redirect: the
# summary and any final error are surfaced there as well, so a failing
# setup is visible wherever its output is presented, not only in the log
# file. Pure fd duplication — no process substitution (the /dev/fd rule).
exec 3>&1 4>&2
# APPEND, never truncate: this repo's .conductor/settings.toml already
# appends everything to this same file, and a standalone/pasted run must
# not wipe an earlier run's log either — each run's "=== setup started ==="
# header keeps the appended log readable run-by-run.
SETUP_LOG="$HOME/.conductor-setup.log"
touch "$SETUP_LOG"
exec >> "$SETUP_LOG" 2>&1
echo "=== setup started $(date -u +%FT%TZ) ==="

# ~/.local/bin is the no-sudo fallback install location; keep it on PATH for
# the rest of setup (later shells normally have it via the profile).
export PATH="${HOME}/.local/bin:${PATH}"

LOCAL_BIN="/usr/local/bin"
RESULTS=""
FAILED=0
# Tools that had to land in ~/.local/bin because /usr/local/bin was not
# writable and no passwordless sudo existed. They are NOT on the default
# PATH of later setup steps; the summary warns about them and callers must
# export ~/.local/bin (this repo's settings.toml does).
LOCAL_FALLBACK_TOOLS=""

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
# EXIT alone does the cleanup. The signal traps exist because a trap that
# only cleans up lets bash RESUME the script with WORK already deleted —
# later stages then fail confusingly — so they exit with the conventional
# codes instead, which re-triggers the EXIT trap (roborev review finding).
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

log() { echo "[startup] $*"; }

# Issue #113 diagnostic: record what setup actually sees at start, so the
# "is the repo cloned / env var set when Conductor runs setup?" question
# gets a real answer from a live run's log.
log "[diag] pwd=$(pwd) conductor_vars=$(env | grep '^CONDUCTOR_' | cut -d= -f1 | tr '\n' ' ')"

record() { # <status> <name> <detail> — one summary row + one log line
  RESULTS="${RESULTS}
 ${2} | ${1} | ${3}"
  log "[${1}] ${2} — ${3}"
}

# note_placement <path>: record tools whose install landed in the
# ~/.local/bin fallback (see LOCAL_FALLBACK_TOOLS above).
note_placement() {
  case "$1" in
  "${HOME}/.local/bin/"*)
    LOCAL_FALLBACK_TOOLS="${LOCAL_FALLBACK_TOOLS} $(basename "$1")"
    ;;
  esac
}

# install_bin <src> <name>: place a file as an executable under
# /usr/local/bin (the convention this repo's setup already uses for
# rwx/infisical) when root or passwordless sudo allows it,
# else under ~/.local/bin. Echoes the installed path on success (nothing on
# failure).
install_bin() {
  local src="$1" name="$2" dir
  if [[ "$(id -u)" == 0 || -w "${LOCAL_BIN}" ]]; then
    install -m 755 "${src}" "${LOCAL_BIN}/${name}" || return 1
    dir="${LOCAL_BIN}"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo install -m 755 "${src}" "${LOCAL_BIN}/${name}" || return 1
    dir="${LOCAL_BIN}"
  else
    mkdir -p "${HOME}/.local/bin" || return 1
    install -m 755 "${src}" "${HOME}/.local/bin/${name}" || return 1
    dir="${HOME}/.local/bin"
  fi
  printf '%s' "${dir}/${name}"
  echo
}

# checksum_verify <sha256> <file>: works with sha256sum (AL2023) and
# `shasum -a 256` (macOS), which accept the same "<hash>  <file>" stdin form.
checksum_verify() {
  local expected="$1" file="$2"
  local tool="sha256sum"
  if ! command -v sha256sum >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1; then
    tool="shasum -a 256"
  fi
  # shellcheck disable=SC2086  # intentional two-word command (shasum -a 256), not a path to quote
  if ! echo "${expected}  ${file}" | ${tool} -c - >/dev/null; then
    log "error: checksum mismatch for ${file} (expected ${expected})"
    return 1
  fi
}

# --- infisical ----------------------------------------------------------------
# Pinned release binary, fail-closed sha256 (issue #183: fresh cloud
# sandboxes had no `infisical`, so agents fell back to hand-written REST
# calls). Reuse-if-present keeps re-runs cheap and never shadows a host
# install. `infisical init` is deliberately never run. Bump runbook: new pin
# + sha256s from the release's checksums.txt (linux) and checksums-darwin.txt.
INFISICAL_PIN="0.45.10"

infisical_install() {
  if command -v infisical >/dev/null 2>&1; then
    record PASS infisical "reused $(command -v infisical) ($(infisical --version 2>&1 | head -1 || true))"
    return 0
  fi
  local asset sha256
  case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    asset="cli_${INFISICAL_PIN}_linux_amd64.tar.gz"
    sha256="93feaec51a5a6ff217f6b11aff3c865cb268c46911cc028d751250a032a9ba02"
    ;;
  Linux-aarch64)
    asset="cli_${INFISICAL_PIN}_linux_arm64.tar.gz"
    sha256="c5490f49ecf533c24613b521d714facee0ca345b597f005714af1f1a6997274d"
    ;;
  Darwin-arm64)
    asset="cli_${INFISICAL_PIN}_darwin_arm64.tar.gz"
    sha256="4992c8f717de61b980d3129e8db9d69fd884000c8858834a49d612efee157e2b"
    ;;
  *)
    log "error: no pinned infisical asset for $(uname -s)-$(uname -m)"
    return 1
    ;;
  esac
  local dir="${WORK}/infisical"
  mkdir -p "${dir}"
  if ! curl -fsSLo "${dir}/${asset}" "https://github.com/Infisical/cli/releases/download/v${INFISICAL_PIN}/${asset}"; then
    return 1
  fi
  if ! checksum_verify "${sha256}" "${dir}/${asset}"; then
    return 1
  fi
  if ! tar -xzf "${dir}/${asset}" -C "${dir}" infisical || [[ ! -x "${dir}/infisical" ]]; then
    log "error: infisical tarball did not yield an executable ./infisical"
    return 1
  fi
  local path
  path="$(install_bin "${dir}/infisical" infisical || true)"
  if [[ -z "${path}" ]]; then
    log "error: could not place the infisical binary in a bin directory"
    return 1
  fi
  note_placement "${path}"
  hash -r 2>/dev/null || true
  if ! command -v infisical >/dev/null 2>&1; then
    log "error: infisical installed at ${path} but not on PATH"
    return 1
  fi
  record PASS infisical "v${INFISICAL_PIN} (${path})"
}

# --- rwx --------------------------------------------------------------------
# Pinned static release binary (RWX is not in nixpkgs/Flox; their docs
# recommend pinning for scripted use). Reuse-if-present.
RWX_PIN="v3.36.1"

rwx_install() {
  if command -v rwx >/dev/null 2>&1; then
    record PASS rwx "reused $(command -v rwx) ($(rwx --version 2>&1 | head -1 || true))"
    return 0
  fi
  local os arch sha256 binary path
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m | sed s/arm64/aarch64/)"
  case "${os}-${arch}" in
  linux-x86_64) sha256="8a88c69fe325d0f56cb21b61768969b6d20b13a87ce751c1b6a5ac0b50b36b62" ;;
  linux-aarch64) sha256="52b6877cb955f7ae4e3f4e8ff93751074637dddaaae43217c6f6a22a28f7a114" ;;
  darwin-x86_64) sha256="928b08e613224584cc0635069ebe1a0c559c92effa7703cacd8222d6da53fe02" ;;
  darwin-aarch64) sha256="6e9c6d2981d896599a15291432984d7679c275614e366612968aa4910d9ce862" ;;
  *)
    log "error: no pinned rwx asset for ${os}-${arch}"
    return 1
    ;;
  esac
  binary="${WORK}/rwx"
  if ! curl -fsSLo "${binary}" "https://github.com/rwx-cloud/rwx/releases/download/${RWX_PIN}/rwx-${os}-${arch}"; then
    return 1
  fi
  if ! checksum_verify "${sha256}" "${binary}"; then
    return 1
  fi
  chmod 755 "${binary}"
  path="$(install_bin "${binary}" rwx || true)"
  if [[ -z "${path}" ]]; then
    log "error: could not place the rwx binary in a bin directory"
    return 1
  fi
  note_placement "${path}"
  hash -r 2>/dev/null || true
  if ! rwx --version >/dev/null 2>&1; then
    log "error: installed rwx binary failed its version check"
    return 1
  fi
  record PASS rwx "${RWX_PIN} (${path})"
}

# --- entire (Entire.io CLI) -------------------------------------------------
# Pinned release tarball, fail-closed per-platform sha256. The tarball ships
# two binaries plus README/LICENSE/completions: `entire` (the CLI itself) and
# `git-remote-entire` (git's handler for `entire://` remotes — needed for
# `entire repo clone` etc.). Per-tool pins section in the header (item below
# `RWX_PIN`) covers ENTIRE_PIN + the per-platform ENTIRE_SHA256_* constants;
# scripts/validate-pins.sh enforces both the x.y.z shape and the
# constant-set/drift surface for them.
#
# Download origin: install.entire.com is the canonical CDN the Entire CLI's
# own install.sh script uses first (it's the published mirror that survives
# GitHub outages — the README/install docs name it as primary; GitHub is the
# documented fallback). Both URLs publish byte-identical tarballs with the
# same sha256, so picking the CDN keeps the script pinned to the same artifact
# the CLI's official installer would pin to. Pins update the same way as
# rwx: new pin + hand-hashed per-platform sha256 (no checksum file
# is published alongside the release).
#
# Like the other tools in this script, this stage NEVER auto-runs
# `entire enable`: that operator action is what writes .entire/settings.json
# and installs agent hook files, and committing them is a per-repo decision
# (skills/conductor-startup-script documents the workflow). All this stage does is make the
# commands available so an operator can run `entire enable --agent <X>` (or
# read-only queries like `entire checkpoint list`, `entire trail list`,
# `entire review`) in any later shell.
ENTIRE_PIN="0.12.1"
# Per-platform sha256 of the entire_${platform}.tar.gz release artifact (the
# install.entire.com CDN and the GitHub release tarball are byte-identical,
# so either URL yields the same hash). Re-pin runbook in the header.
ENTIRE_SHA256_LINUX_AMD64="15645d3c41cd91e3e3dc42f91a92f02739f57c3f31233236f8f4d7c7e2029ffc"
ENTIRE_SHA256_LINUX_ARM64="371ad9a35665887bb8bff64b57cf358dfca649ceb75da545ba3f4d9ec5a4cac6"
ENTIRE_SHA256_DARWIN_AMD64="c7adf5a3e91320c81685eb3491f8a91d2551f36208ba6f82f6673a9c28ffd360"
ENTIRE_SHA256_DARWIN_ARM64="77f1a9174fd9b503f0503e776f2fa1e913cda1eba2a37772d3a6b97ad67edfb1"

entire_install() {
  # Reuse requires BOTH binaries: this stage's contract is entire plus its
  # git-remote-entire companion (entire:// remotes fail without it), so a
  # pre-existing entire without the companion must fall through to the
  # pinned install below instead of PASSing over a half install.
  if command -v entire >/dev/null 2>&1 && command -v git-remote-entire >/dev/null 2>&1; then
    record PASS entire "reused $(command -v entire) ($(entire version 2>&1 | head -1 || true))"
    return 0
  fi
  local platform asset sha256
  case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    platform="linux_amd64"
    sha256="${ENTIRE_SHA256_LINUX_AMD64:-}"
    ;;
  Linux-aarch64)
    platform="linux_arm64"
    sha256="${ENTIRE_SHA256_LINUX_ARM64:-}"
    ;;
  Darwin-x86_64)
    platform="darwin_amd64"
    sha256="${ENTIRE_SHA256_DARWIN_AMD64:-}"
    ;;
  Darwin-arm64)
    platform="darwin_arm64"
    sha256="${ENTIRE_SHA256_DARWIN_ARM64:-}"
    ;;
  *)
    log "error: no pinned entire asset for $(uname -s)-$(uname -m)"
    return 1
    ;;
  esac
  if [[ -z "${sha256}" ]]; then
    log "error: missing pinned entire sha256 for ${platform} (set ENTIRE_SHA256_${platform^^} in the pins block)"
    return 1
  fi
  asset="entire_${platform}.tar.gz"
  local url="https://install.entire.com/v${ENTIRE_PIN}/${asset}"
  local dir="${WORK}/entire"
  mkdir -p "${dir}"
  if ! curl -fsSLo "${dir}/${asset}" "${url}"; then
    return 1
  fi
  if ! checksum_verify "${sha256}" "${dir}/${asset}"; then
    return 1
  fi
  if ! tar -xzf "${dir}/${asset}" -C "${dir}" ||
    [[ ! -x "${dir}/entire" ]] || [[ ! -x "${dir}/git-remote-entire" ]]; then
    log "error: entire tarball did not yield executable ./entire and ./git-remote-entire"
    return 1
  fi
  local entire_path gre_path
  entire_path="$(install_bin "${dir}/entire" entire || true)"
  gre_path="$(install_bin "${dir}/git-remote-entire" git-remote-entire || true)"
  if [[ -z "${entire_path}" || -z "${gre_path}" ]]; then
    log "error: could not place entire / git-remote-entire in a bin directory (entire=${entire_path:-<none>}, git-remote-entire=${gre_path:-<none>})"
    return 1
  fi
  note_placement "${entire_path}"
  note_placement "${gre_path}"
  hash -r 2>/dev/null || true
  local resolved_entire resolved_gre
  resolved_entire="$(command -v entire 2>/dev/null || true)"
  resolved_gre="$(command -v git-remote-entire 2>/dev/null || true)"
  if [[ -z "${resolved_entire}" || -z "${resolved_gre}" ]]; then
    log "error: entire installed at ${entire_path} but not on PATH (or git-remote-entire missing from PATH)"
    return 1
  fi
  # Both deliverables are placed, but a pre-existing entire earlier on PATH
  # (an operator's manual install in ~/.local/bin — which setup prepends to
  # PATH — is exactly this stage's target machine, issue #91) keeps
  # resolving after the pinned install. Name that state instead of PASSing
  # a pinned-version row over a stale, shadowing binary.
  if [[ "${resolved_entire}" != "${entire_path}" || "${resolved_gre}" != "${gre_path}" ]]; then
    record WARN entire "v${ENTIRE_PIN} installed (entire: ${entire_path}, git-remote-entire: ${gre_path}) but PATH resolves entire to ${resolved_entire} and git-remote-entire to ${resolved_gre} — remove the stale binary or reorder PATH if the pinned entire must run"
    return 0
  fi
  record PASS entire "v${ENTIRE_PIN} (entire: ${entire_path}, git-remote-entire: ${gre_path})"
}

# --- uv ---------------------------------------------------------------------
# Pinned release binary, fail-closed sha256 (hand-hashed from the release
# tarballs; no checksum file is published). Kept in sync with envs/prebuilt
# and envs/floxhub-provision's uv.version (validate-pins.sh). Tools that used
# to live in a pytools venv (pytest, reflex, ruff, pyright, pyrefly) now run
# as RWX tasks (issue #185).
UV_PIN="0.11.26"

uv_install() {
  if command -v uv >/dev/null 2>&1; then
    if uv --version >/dev/null 2>&1; then
      record PASS uv "reused $(command -v uv) ($(uv --version 2>&1 | head -1 || true))"
      return 0
    fi
    record FAIL uv "uv present at $(command -v uv) but not functional (uv --version failed) — remove it and re-run setup"
    return 1
  fi
  # Asset names are uv-<arch>-<vendor>-<os>.tar.gz (uv's own naming, NOT
  # the os-arch triple rwx uses); each extracts into a directory of
  # the same name containing ./uv.
  local asset sha256 dir path
  case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    asset="uv-x86_64-unknown-linux-gnu.tar.gz"
    sha256="6426a73c3837e6e2483ee344cbc00f36394d179afcba6183cb77437e67db4af0"
    ;;
  Linux-aarch64)
    asset="uv-aarch64-unknown-linux-gnu.tar.gz"
    sha256="befa1a59c91e96eb601b0fd9a97c03dd666f17baba644b2b4db9c59a767e387e"
    ;;
  Darwin-x86_64)
    asset="uv-x86_64-apple-darwin.tar.gz"
    sha256="922b460202707dd5f4ccacbadbe7f6a546cc46e82a99bf50ca99a7977a78eddd"
    ;;
  Darwin-arm64)
    asset="uv-aarch64-apple-darwin.tar.gz"
    sha256="8f7fbf1708399b921857bce71e1d60f0d3ccf52a30caebc1c1a2f175dce13ab6"
    ;;
  *)
    record FAIL uv "no pinned uv ${UV_PIN} asset for $(uname -s)-$(uname -m)"
    return 1
    ;;
  esac
  dir="${WORK}/uv"
  mkdir -p "${dir}"
  if ! curl -fsSLo "${dir}/${asset}" "https://github.com/astral-sh/uv/releases/download/${UV_PIN}/${asset}"; then
    return 1
  fi
  if ! checksum_verify "${sha256}" "${dir}/${asset}"; then
    return 1
  fi
  if ! tar -xzf "${dir}/${asset}" -C "${dir}" || [[ ! -x "${dir}/${asset%.tar.gz}/uv" ]]; then
    log "error: uv tarball did not yield an executable ${asset%.tar.gz}/uv"
    return 1
  fi
  path="$(install_bin "${dir}/${asset%.tar.gz}/uv" uv || true)"
  if [[ -z "${path}" ]]; then
    log "error: could not place the uv binary in a bin directory"
    return 1
  fi
  note_placement "${path}"
  # uvx ships in the same tarball; agents reach for `uvx <tool>` (issues
  # #128/#129), so place it beside uv.
  if [[ -x "${dir}/${asset%.tar.gz}/uvx" ]]; then
    local uvx_path
    uvx_path="$(install_bin "${dir}/${asset%.tar.gz}/uvx" uvx || true)"
    [[ -n "${uvx_path}" ]] && note_placement "${uvx_path}"
  fi
  hash -r 2>/dev/null || true
  if ! uv --version >/dev/null 2>&1; then
    log "error: installed uv binary failed its version check"
    return 1
  fi
  record PASS uv "v${UV_PIN} (${path})"
}

# --- resend -----------------------------------------------------------------
# Pinned release binary, fail-closed sha256 from the release's checksums.txt.
# Reuse-if-present; never shadows a host install. Bump runbook: new pin +
# sha256s from https://github.com/resend/resend-cli/releases checksums.txt.
RESEND_PIN="2.29.0"

resend_install() {
  if command -v resend >/dev/null 2>&1; then
    record PASS resend "reused $(command -v resend) ($(resend --version 2>&1 | head -1 || true))"
    return 0
  fi
  local asset sha256
  case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    asset="resend-linux-x64.tar.gz"
    sha256="9db20ae279a8ed9200b7a24c39e0491b9c6d878abbf64212546af26fc7423f00"
    ;;
  Linux-aarch64)
    asset="resend-linux-arm64.tar.gz"
    sha256="e743b8e85630b0b189777197787617524c38ab1b8bb3e6be6a49b1d6784759c2"
    ;;
  Darwin-arm64)
    asset="resend-darwin-arm64.tar.gz"
    sha256="cce554fc78eb7bb183efe1d6f46b5658b0a4526f1924208be86a0008314fac59"
    ;;
  Darwin-x86_64)
    asset="resend-darwin-x64.tar.gz"
    sha256="824de5f5349b74171dd16e22ba3b01d74be7dee01be2c4b9d609bfe8adb00bd8"
    ;;
  *)
    log "error: no pinned resend asset for $(uname -s)-$(uname -m)"
    return 1
    ;;
  esac
  local dir="${WORK}/resend"
  mkdir -p "${dir}"
  if ! curl -fsSLo "${dir}/${asset}" "https://github.com/resend/resend-cli/releases/download/v${RESEND_PIN}/${asset}"; then
    return 1
  fi
  if ! checksum_verify "${sha256}" "${dir}/${asset}"; then
    return 1
  fi
  if ! tar -xzf "${dir}/${asset}" -C "${dir}" resend || [[ ! -x "${dir}/resend" ]]; then
    log "error: resend tarball did not yield an executable ./resend"
    return 1
  fi
  local path
  path="$(install_bin "${dir}/resend" resend || true)"
  if [[ -z "${path}" ]]; then
    log "error: could not place the resend binary in a bin directory"
    return 1
  fi
  note_placement "${path}"
  hash -r 2>/dev/null || true
  if ! command -v resend >/dev/null 2>&1; then
    log "error: resend installed at ${path} but not on PATH"
    return 1
  fi
  record PASS resend "v${RESEND_PIN} (${path})"
}

# --- railway ----------------------------------------------------------------
# Pinned release binary (static musl on Linux), fail-closed sha256 from the
# GitHub release asset digests. Reuse-if-present; never shadows a host install.
# Bump runbook: new pin + sha256s from
# `gh release view v<pin> -R railwayapp/cli --json assets`.
RAILWAY_PIN="5.75.0"

railway_install() {
  if command -v railway >/dev/null 2>&1; then
    record PASS railway "reused $(command -v railway) ($(railway --version 2>&1 | head -1 || true))"
    return 0
  fi
  local target sha256
  case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    target="x86_64-unknown-linux-musl"
    sha256="ba5d9fb5dce1c59789f4216e6b754becd75025ed740388452be55aae83720400"
    ;;
  Linux-aarch64)
    target="aarch64-unknown-linux-musl"
    sha256="963a51fe20772e3fd6006f820842865c7fb901f3a23841f462470913fe23e9b7"
    ;;
  Darwin-arm64)
    target="aarch64-apple-darwin"
    sha256="a56bf201b0963de226a2f93d6445dd75392c530c8dc020c803d737b32a7b9288"
    ;;
  Darwin-x86_64)
    target="x86_64-apple-darwin"
    sha256="701fd07f33eae1df9d22402c33f7a0adbd550fab74e04b3f4b2c999340673f77"
    ;;
  *)
    log "error: no pinned railway asset for $(uname -s)-$(uname -m)"
    return 1
    ;;
  esac
  local asset="railway-v${RAILWAY_PIN}-${target}.tar.gz"
  local dir="${WORK}/railway"
  mkdir -p "${dir}"
  if ! curl -fsSLo "${dir}/${asset}" "https://github.com/railwayapp/cli/releases/download/v${RAILWAY_PIN}/${asset}"; then
    return 1
  fi
  if ! checksum_verify "${sha256}" "${dir}/${asset}"; then
    return 1
  fi
  if ! tar -xzf "${dir}/${asset}" -C "${dir}" railway || [[ ! -x "${dir}/railway" ]]; then
    log "error: railway tarball did not yield an executable ./railway"
    return 1
  fi
  local path
  path="$(install_bin "${dir}/railway" railway || true)"
  if [[ -z "${path}" ]]; then
    log "error: could not place the railway binary in a bin directory"
    return 1
  fi
  note_placement "${path}"
  hash -r 2>/dev/null || true
  if ! command -v railway >/dev/null 2>&1; then
    log "error: railway installed at ${path} but not on PATH"
    return 1
  fi
  record PASS railway "v${RAILWAY_PIN} (${path})"
}

# --- python3.13 -------------------------------------------------------------
# Installed ALONGSIDE the AL2023 default 3.9, never as a replacement: dnf's
# shebang is the absolute #!/usr/bin/python3, so a /usr/local/bin/python3
# symlink shadows PATH lookups only (asserted by the container test suite).
python313_ok() { python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 13) else 1)' 2>/dev/null; }

python313_stage() {
  if python313_ok; then
    record PASS python3.13 "already $(python3 --version 2>&1 | head -1 || true) ($(command -v python3))"
    return 0
  fi
  if [[ "$(uname -s)" != "Linux" ]] || ! command -v dnf >/dev/null 2>&1; then
    record SKIP python3.13 "not the AL2023 target class (no dnf on $(uname -s)); cannot install here, continuing"
    return 0
  fi
  local sudo_cmd=""
  if [[ "$(id -u)" != 0 ]]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo_cmd="sudo"
    else
      record SKIP python3.13 "no root or passwordless sudo; cannot dnf-install here, continuing"
      return 0
    fi
  fi
  log "installing python3.13 (AL2023 default python3 is 3.9)"
  if ! ${sudo_cmd} dnf install -y python3.13; then
    log "error: dnf install python3.13 failed"
    return 1
  fi
  local pip_ok=0
  if ${sudo_cmd} dnf install -y python3.13-pip; then
    pip_ok=1
  elif ${sudo_cmd} /usr/bin/python3.13 -m ensurepip --upgrade >/dev/null 2>&1; then
    pip_ok=1
  fi
  if [[ ! -x /usr/bin/python3.13 ]]; then
    log "error: dnf reports success but /usr/bin/python3.13 is missing"
    return 1
  fi
  ${sudo_cmd} ln -sfn /usr/bin/python3.13 "${LOCAL_BIN}/python3"
  if [[ ${pip_ok} == 1 && -e /usr/bin/pip3.13 ]]; then
    ${sudo_cmd} ln -sfn /usr/bin/pip3.13 "${LOCAL_BIN}/pip3"
  fi
  hash -r 2>/dev/null || true
  if ! python313_ok; then
    log "error: python3 still not >=3.13 after install (resolved: $(command -v python3 || true), $(python3 --version 2>&1 | head -1 || true))"
    return 1
  fi
  local detail
  detail="$(python3 --version 2>&1 | head -1 || true) via $(command -v python3)"
  if [[ ${pip_ok} != 1 ]]; then
    detail="${detail} (pip unavailable: no python3.13-pip package and ensurepip failed)"
  fi
  record PASS python3.13 "${detail}"
}

# --- rwx authentication -----------------------------------------------------
# Validate FIRST via the env var (rwx reads RWX_ACCESS_TOKEN on its own),
# persist ONLY on success — a bad token must never overwrite a valid token
# left by a previous `rwx login`. The persisted file is byte-identical to
# what `rwx login` writes, so later shells work without the env var; it is
# created 600 from the start (umask inside a subshell) rather than chmod'd
# after the fact. A pre-existing token file is validated and reported
# instead of ignored; and the stage skips cleanly when rwx failed to
# install, rather than recording a misleading "token rejected" row.
rwx_auth() {
  if ! command -v rwx >/dev/null 2>&1; then
    record SKIP rwx-auth "rwx not installed — skipping auth (see the rwx install row above)"
    return 0
  fi
  # No plain token? Pick RWX_ACCESS_TOKEN_<OWNER> (or RWC_) for the repo owner
  # parsed from origin; the sandbox injects only the suffixed names.
  if [[ -z "${RWX_ACCESS_TOKEN:-}" ]]; then
    local owner_url owner owner_token
    owner_url="$(git remote get-url origin 2>/dev/null || true)"
    owner="$(printf '%s' "${owner_url}" | sed -E 's#.*[:/]([^/]+)/[^/]+$#\1#' | tr 'a-z-' 'A-Z_')"
    if [[ -n "${owner}" ]]; then
      owner_token="$(printenv "RWX_ACCESS_TOKEN_${owner}" || printenv "RWC_ACCESS_TOKEN_${owner}" || true)"
      if [[ -n "${owner_token}" ]]; then
        export RWX_ACCESS_TOKEN="${owner_token}"
      fi
    fi
  fi
  if [[ -n "${RWX_ACCESS_TOKEN:-}" ]]; then
    if rwx whoami; then
      mkdir -p "${HOME}/.config/rwx"
      # Atomic persist: write a temp file in the same directory, then mv -f
      # (rename) into place. A truncate-then-write redirect could destroy a
      # previously valid token when the write itself fails mid-way
      # (ENOSPC/EIO); a failed rename leaves the old file intact. The temp
      # file is created 600 via the umask subshell and mv carries those
      # perms to the final name; rm -f on the failure path so a broken
      # persist leaves nothing behind.
      local token_tmp="${HOME}/.config/rwx/accesstoken.tmp"
      if (umask 077; printf '%s' "${RWX_ACCESS_TOKEN}" > "${token_tmp}") &&
        mv -f "${token_tmp}" "${HOME}/.config/rwx/accesstoken"; then
        record PASS rwx-auth "token validated (rwx whoami) and persisted to ~/.config/rwx/accesstoken"
      else
        rm -f "${token_tmp}"
        record FAIL rwx-auth "token validated but persisting to ~/.config/rwx/accesstoken failed; any previously persisted token was left untouched"
        return 1
      fi
    else
      record FAIL rwx-auth "RWX_ACCESS_TOKEN rejected — rwx whoami failed (expired or wrong token?); any previously persisted token was left untouched"
      return 1
    fi
  elif [[ -s "${HOME}/.config/rwx/accesstoken" ]]; then
    if rwx whoami; then
      record PASS rwx-auth "no RWX_ACCESS_TOKEN, but the existing ~/.config/rwx/accesstoken validated (rwx whoami)"
    else
      record WARN rwx-auth "existing ~/.config/rwx/accesstoken rejected — run rwx login, or set RWX_ACCESS_TOKEN in Conductor environment variables"
    fi
  else
    record WARN rwx-auth "RWX_ACCESS_TOKEN not set — rwx installed but unauthenticated; set it in Conductor environment variables and re-run setup, or run rwx login in a workspace terminal"
  fi
  return 0
}

# --- gws + gtm CLIs ----------------------------------------------------------
# Mirrors the Warp/Oz setup script. gws (@googleworkspace/cli) comes from npm
# and reads ~/.config/gws/credentials.json, written from GWS_CREDENTIALS (never
# printed). gtm-linear/gtm-attio come from PyPI via uv into the system python.
# Both are floors, not exact pins, so unlike the tarball stages they are not
# checksum-verified. sudo only when not root and passwordless sudo exists.
GTM_LINEAR_MIN="0.3.0"
GTM_ATTIO_MIN="0.26.1"

priv_cmd() { # echoes "sudo" when needed, "" when root; returns 1 when neither works
  if [[ "$(id -u)" == 0 ]]; then
    return 0
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    echo sudo
  else
    return 1
  fi
}

gws_credentials() {
  if [[ -z "${GWS_CREDENTIALS:-}" ]]; then
    record WARN gws-credentials "GWS_CREDENTIALS not set — skipped writing ~/.config/gws/credentials.json"
    return 0
  fi
  mkdir -p "${HOME}/.config/gws"
  if (umask 077; printf '%s' "${GWS_CREDENTIALS}" > "${HOME}/.config/gws/credentials.json"); then
    record PASS gws-credentials "wrote ~/.config/gws/credentials.json from GWS_CREDENTIALS"
  else
    record FAIL gws-credentials "could not write ~/.config/gws/credentials.json"
    return 1
  fi
}

gws_install() {
  if command -v gws >/dev/null 2>&1; then
    record PASS gws "reused $(command -v gws)"
    return 0
  fi
  if ! command -v npm >/dev/null 2>&1; then
    record SKIP gws "npm not found; cannot install @googleworkspace/cli here, continuing"
    return 0
  fi
  local sudo_cmd
  if ! sudo_cmd="$(priv_cmd)"; then
    record SKIP gws "no root or passwordless sudo for npm install -g, continuing"
    return 0
  fi
  if ! ${sudo_cmd} npm install -g @googleworkspace/cli; then
    log "error: npm install -g @googleworkspace/cli failed"
    return 1
  fi
  hash -r 2>/dev/null || true
  if ! command -v gws >/dev/null 2>&1; then
    log "error: @googleworkspace/cli installed but gws is not on PATH"
    return 1
  fi
  record PASS gws "installed $(command -v gws)"
}

gtm_install() {
  if ! command -v uv >/dev/null 2>&1; then
    record SKIP gtm "uv not installed (see uv row); cannot install gtm-linear/gtm-attio, continuing"
    return 0
  fi
  local sudo_cmd
  if ! sudo_cmd="$(priv_cmd)"; then
    record SKIP gtm "no root or passwordless sudo for uv pip install --system, continuing"
    return 0
  fi
  if ! ${sudo_cmd} env "PATH=${PATH}" uv pip install --system --break-system-packages --upgrade-package gtm-linear --upgrade-package gtm-attio "gtm-linear>=${GTM_LINEAR_MIN}" "gtm-attio>=${GTM_ATTIO_MIN}"; then
    log "error: uv pip install gtm-linear/gtm-attio failed"
    return 1
  fi
  hash -r 2>/dev/null || true
  local lv av
  lv="$(gtm-linear --version 2>&1 | head -1)" || { log "error: gtm-linear --version failed"; return 1; }
  av="$(gtm-attio --version 2>&1 | head -1)" || { log "error: gtm-attio --version failed"; return 1; }
  record PASS gtm "gtm-linear ${lv}; gtm-attio ${av}"
}

# Repair only consuming repositories whose locked Python project explicitly
# references the private gtm-sdk/cli package. Conductor supplies the token as
# an environment secret; Git receives it through a temporary helper, never a
# remote URL, config value, command argument, or log.
gtm_sdk_dependency_repair() {
  if [[ ! -f pyproject.toml || ! -f uv.lock ]] ||
    { ! grep -Fq 'gtm-sdk/cli' pyproject.toml && ! grep -Fq 'gtm-sdk/cli' uv.lock; }; then
    record SKIP gtm-sdk-deps "no locked gtm-sdk/cli dependency in this repository"
    return 0
  fi
  if ! command -v uv >/dev/null 2>&1; then
    record SKIP gtm-sdk-deps "uv is unavailable; see the uv row above"
    return 0
  fi

  if [[ ! -f gtm-sdk/cli/pyproject.toml ]]; then
    local gitlink module_key module_url module_status helper
    gitlink="$(git ls-files --stage -- gtm-sdk 2>/dev/null | awk '$1 == "160000" { print $4; exit }' || true)"
    if [[ "${gitlink}" != "gtm-sdk" || ! -f .gitmodules ]]; then
      log "error: gtm-sdk/cli is missing and gtm-sdk is not a configured submodule"
      return 1
    fi

    module_key="$(git config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '$2 == "gtm-sdk" { sub(/\.path$/, "", $1); print $1; exit }' || true)"
    if [[ -z "${module_key}" ]]; then
      log "error: gtm-sdk path is missing from .gitmodules"
      return 1
    fi
    module_url="$(git config --file .gitmodules --get "${module_key}.url" 2>/dev/null || true)"
    local module_url_lower
    module_url_lower="$(printf '%s' "${module_url}" | tr '[:upper:]' '[:lower:]')"
    case "${module_url_lower}" in
    https://github.com/elviskahoro/gtm-sdk | https://github.com/elviskahoro/gtm-sdk.git | git@github.com:elviskahoro/gtm-sdk | git@github.com:elviskahoro/gtm-sdk.git | ssh://git@github.com/elviskahoro/gtm-sdk | ssh://git@github.com/elviskahoro/gtm-sdk.git)
      ;;
    *)
      log "error: gtm-sdk submodule URL is not the expected GitHub repository"
      return 1
      ;;
    esac

    module_status="$(git submodule status -- gtm-sdk 2>/dev/null || true)"
    if [[ "${module_status:0:1}" != "-" ]]; then
      log "error: gtm-sdk/cli is missing but the gtm-sdk submodule is not uninitialized"
      return 1
    fi
    if [[ -z "${GTM_SDK_GITHUB_TOKEN:-}" ]]; then
      log "error: GTM_SDK_GITHUB_TOKEN is required to initialize the private gtm-sdk submodule"
      return 1
    fi

    helper="${WORK}/gtm-sdk-credential-helper"
    cat >"${helper}" <<'GTM_CREDENTIAL_HELPER'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "get" ]] || exit 0
protocol=""
host=""
path=""
while IFS='=' read -r key value; do
  [[ -n "${key}" ]] || break
  case "${key}" in
  protocol) protocol="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')" ;;
  host) host="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')" ;;
  path) path="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')" ;;
  esac
done
path="${path#/}"
case "${protocol}:${host}:${path}" in
https:github.com:elviskahoro/gtm-sdk | https:github.com:elviskahoro/gtm-sdk.git)
  ;;
*)
  exit 0
  ;;
esac
token="${GTM_SDK_GITHUB_TOKEN:-}"
[[ -n "${token}" ]] || exit 0
[[ "${token}" != *$'\n'* && "${token}" != *$'\r'* ]] || exit 1
printf 'username=x-access-token\npassword=%s\n\n' "${token}"
GTM_CREDENTIAL_HELPER
    chmod 700 "${helper}"

    # Rewrite GitHub SSH URLs for HTTPS auth without changing repository or
    # user configuration. These command-scoped values contain no credential.
    if ! (
      unset GIT_TRACE GIT_TRACE_CURL GIT_CURL_VERBOSE GIT_TRACE_PACKET GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF
      export GIT_TERMINAL_PROMPT=0
      git -c url.https://github.com/.insteadOf='git@github.com:' -c url.https://github.com/.insteadOf='ssh://git@github.com/' -c credential.helper= -c "credential.helper=${helper}" -c credential.useHttpPath=true submodule update --init --recursive -- gtm-sdk
    ) >"${WORK}/gtm-sdk-submodule.log" 2>&1; then
      log "error: private gtm-sdk submodule checkout failed; check repository access and GTM_SDK_GITHUB_TOKEN"
      return 1
    fi
  fi

  if [[ ! -f gtm-sdk/cli/pyproject.toml ]]; then
    log "error: gtm-sdk checkout did not provide gtm-sdk/cli/pyproject.toml"
    return 1
  fi
  if ! (unset GTM_SDK_GITHUB_TOKEN; uv sync --dev --frozen --python 3.13); then
    log "error: uv sync --dev --frozen --python 3.13 failed after gtm-sdk checkout"
    return 1
  fi
  record PASS gtm-sdk-deps "private gtm-sdk checkout is ready and uv dependencies synced with Python 3.13"
}

# --- prerequisites -----------------------------------------------------------
# Every pinned CLI ships as a .tar.gz, but bare AL2023 images omit tar/gzip.
# Install them via dnf when root or passwordless sudo allows (same gating as
# python313_stage); otherwise say so plainly, since the stage errors that
# follow ("tarball did not yield an executable") would hide the real cause.
ensure_archive_tools() {
  if command -v tar >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$(uname -s)" != "Linux" ]] || ! command -v dnf >/dev/null 2>&1; then
    log "error: tar/gzip missing and no dnf to install them; install them and re-run setup"
    return 1
  fi
  local sudo_cmd=""
  if [[ "$(id -u)" != 0 ]]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo_cmd="sudo"
    else
      log "error: tar/gzip missing and no root or passwordless sudo to dnf-install them"
      return 1
    fi
  fi
  log "installing tar and gzip (missing on this image)"
  if ! ${sudo_cmd} dnf install -y tar gzip; then
    log "error: dnf install tar gzip failed"
    return 1
  fi
  hash -r 2>/dev/null || true
}

# --- run -------------------------------------------------------------------
# Every stage failure is fatal: a missing sandbox CLI fails setup loudly, but
# every stage still runs and reports before the deferred exit (issue #185).
log "host: $(uname -srm), user: $(id -un), pwd: $(pwd)"

if ensure_archive_tools; then :; else record FAIL prereqs "tar/gzip unavailable — see messages above"; FAILED=1; fi

if rwx_install; then :; else record FAIL rwx "provisioning failed — see messages above"; FAILED=1; fi
if infisical_install; then :; else record FAIL infisical "provisioning failed — see messages above"; FAILED=1; fi
if resend_install; then :; else record FAIL resend "provisioning failed — see messages above"; FAILED=1; fi
if railway_install; then :; else record FAIL railway "provisioning failed — see messages above"; FAILED=1; fi
# entire: operator-driven `entire enable` is never run here (a per-repo decision).
if entire_install; then :; else record FAIL entire "provisioning failed — see messages above"; FAILED=1; fi
if python313_stage; then :; else record FAIL python3.13 "provisioning failed — see messages above"; FAILED=1; fi
if uv_install; then :; else record FAIL uv "provisioning failed — see messages above"; FAILED=1; fi
if gws_credentials; then :; else FAILED=1; fi
if gws_install; then :; else record FAIL gws "provisioning failed — see messages above"; FAILED=1; fi
if gtm_install; then :; else record FAIL gtm "provisioning failed — see messages above"; FAILED=1; fi
if gtm_sdk_dependency_repair; then :; else record FAIL gtm-sdk-deps "private SDK checkout or dependency retry failed — see messages above"; FAILED=1; fi
if rwx_auth; then :; else FAILED=1; fi

log ""
log "---- workspace startup summary ----"
printf '%s' "${RESULTS}"
echo
if [[ -n "${LOCAL_FALLBACK_TOOLS}" ]]; then
  log ""
  log "warning: tools landed in ~/.local/bin (no writable /usr/local/bin, no passwordless sudo):${LOCAL_FALLBACK_TOOLS}"
  log "warning: that directory is not on the default PATH of later setup steps — this repo's .conductor/settings.toml exports it for the rest of setup; other callers must add it themselves"
fi
log "-------------------------------------"
log "full log: $SETUP_LOG"
# Surface the summary on the original stdout too (fd 3, saved before the redirect).
printf '%s' "${RESULTS}" >&3 || true
echo >&3 || true
if [[ -n "${LOCAL_FALLBACK_TOOLS}" ]]; then
  echo "warning: tools landed in ~/.local/bin (not on later steps' default PATH):${LOCAL_FALLBACK_TOOLS}" >&3 || true
fi
echo "full log: $SETUP_LOG" >&3 || true
echo "=== setup finished $(date -u +%FT%TZ) ==="

# Deferred failure so the summary above always completes.
if [[ "${FAILED}" != 0 ]]; then
  log "error: setup finished with FAIL rows — see the summary and $SETUP_LOG"
  echo "error: setup finished with FAIL rows — see the summary and $SETUP_LOG" >&4 || true
  exit 1
fi
