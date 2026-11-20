#!/usr/bin/env bash
# Pin-sync validation for the workspace startup provisioning pins.
#
# The roborev version (pinned in .rwx/roborev.yml), the uv pin and the
# RESEND/ENTIRE pins are checked here. Sync surfaces:
#   1. roborev: .rwx/roborev.yml ROBOREV_VERSION == envs/repackage's
#      [build.roborev] version == envs/floxhub-provision's roborev.version
#   4. startup-script paste-safety (no triple-quotes / line-continuations)
#   5. uv: UV_PIN == envs/prebuilt == envs/floxhub-provision uv.version
#   6. RESEND_PIN exact x.y.z + hex-64 sha256s
#   9. ENTIRE_PIN (issue #91): exactly x.y.z, like pi's pin shape. The four
#      ENTIRE_SHA256_<platform> constants must all be present and hex-64; a
#      missing constant makes the runtime install fail closed on that
#      platform, so the CI check is presence-and-shape, not cross-check.
#
# The former checks that cross-compared two in-repo scripts
# (conductor-cloud-install.sh vs conductor-startup-script.sh, before they
# merged into the single startup script) died with that merge: one file is
# now the only in-repo pin home. The remaining sync surfaces are the Flox
# manifests (checks 1-2, 5). (gtm-sdk's
# former conductor-workspace-setup.sh sibling died with that repo's
# retirement of the script, gtm-sdk#944 — nothing to sync there anymore.)
#
# No process substitution anywhere (gtm-sdk#279 — same rule as every other
# provisioning script in this repo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STARTUP="${REPO_ROOT}/scripts/conductor-startup-script-cloud.sh"
REPACKAGE_MANIFEST="${REPO_ROOT}/envs/repackage/.flox/env/manifest.toml"
PROVISION_MANIFEST="${REPO_ROOT}/envs/floxhub-provision/.flox/env/manifest.toml"
PREBUILT_MANIFEST="${REPO_ROOT}/envs/prebuilt/.flox/env/manifest.toml"

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
# EXIT does the cleanup; the signal traps exit with the conventional codes
# instead — a cleanup-only trap lets bash resume the script with WORK
# already deleted, and the next redirect into WORK then dies confusingly
# under set -e (the same finding fixed in the generic setup script).
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

log() { printf '[validate-pins] %s\n' "$*"; }
FAILED=0

fail() { # <check> <detail>
  FAILED=1
  log "FAIL  $1 — $2"
}
pass() { log "PASS  $1 — $2"; }

# The [build.roborev] manifest section (up to the next table header).
awk 'BEGIN { f = 0 } /^\[build\.roborev\]$/ { f = 1; next } /^\[/ { f = 0 } f' \
  "${REPACKAGE_MANIFEST}" >"${WORK}/repackage_section"

# 1. roborev version: roborev now runs only as an RWX task (issue #185), so
# .rwx/roborev.yml is its pin home; the Flox manifests must still agree.
RWX_YML="${REPO_ROOT}/.rwx/roborev.yml"
PIN="$(sed -n 's/^ *ROBOREV_VERSION: *\([0-9][0-9.]*\).*/\1/p' "${RWX_YML}" | head -1)"
REPACKAGE_VERSION="$(sed -n 's/^version = "\([^"]*\)".*/\1/p' "${WORK}/repackage_section" | head -1)"
PROVISION_VERSION="$(sed -n 's/^roborev\.version *= *"\^\{0,1\}\([^"]*\)".*/\1/p' "${PROVISION_MANIFEST}")"
if [[ -n "${PIN}" && "${PIN}" == "${REPACKAGE_VERSION}" && "${PIN}" == "${PROVISION_VERSION}" ]]; then
  pass "roborev version" "rwx pipeline ${PIN} == repackage ${REPACKAGE_VERSION} == floxhub-provision ^${PROVISION_VERSION}"
else
  fail "roborev version" "drift: .rwx/roborev.yml=${PIN:-<missing>}, repackage=${REPACKAGE_VERSION:-<missing>}, floxhub-provision=${PROVISION_VERSION:-<missing>}"
fi

# 4. Paste-safety of the startup script. Its whole purpose includes being
# pasted into Conductor's GUI setup field, which Conductor serializes into
# a TOML multiline string — a triple-double-quote would terminate the
# string early and a backslash line-continuation would join lines with
# leading whitespace stripped. Both are documented constraints in the
# script's header; this turns them into a CI-enforced invariant.
if grep -n '"""' "${STARTUP}" >/dev/null; then
  fail "startup paste-safety" "triple-double-quote sequence present — TOML multiline hazard for the GUI paste"
elif grep -nE '\\$' "${STARTUP}" >/dev/null; then
  fail "startup paste-safety" "backslash line-continuation present — TOML multiline hazard for the GUI paste"
else
  pass "startup paste-safety" "no triple-double-quotes, no backslash line-continuations"
fi

# 5. uv version across the startup script and the two Flox manifests that
# pin it (issue #44). The manifests' uv is a process-scoped activation
# install; the startup script's UV_PIN is the persistent PATH binary —
# different installs of the SAME tool, so version drift between them is
# exactly the confusion the roborev check above exists to prevent.
UV_PIN_V="$(sed -n 's/^UV_PIN="\([^"]*\)".*/\1/p' "${STARTUP}")"
PREBUILT_UV="$(sed -n 's/^uv\.version *= *"\([^"]*\)".*/\1/p' "${PREBUILT_MANIFEST}")"
PROVISION_UV="$(sed -n 's/^uv\.version *= *"\([^"]*\)".*/\1/p' "${PROVISION_MANIFEST}")"
if [[ -n "${UV_PIN_V}" && "${UV_PIN_V}" == "${PREBUILT_UV}" && "${UV_PIN_V}" == "${PROVISION_UV}" ]]; then
  pass "uv version" "pin ${UV_PIN_V} == prebuilt ${PREBUILT_UV} == floxhub-provision ${PROVISION_UV}"
else
  fail "uv version" "drift: startup-script=${UV_PIN_V:-<missing>}, prebuilt=${PREBUILT_UV:-<missing>}, floxhub-provision=${PROVISION_UV:-<missing>}"
fi

# 6. RESEND_PIN + the per-platform sha256s in resend_install(): exact x.y.z
# pin, and every sha256 in the stage must be 64-char lowercase hex.
RESEND_PIN_VALUE="$(sed -n 's/^RESEND_PIN="\([^"]*\)".*/\1/p' "${STARTUP}")"
if [[ "${RESEND_PIN_VALUE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pass "RESEND_PIN" "exact pin ${RESEND_PIN_VALUE}"
else
  fail "RESEND_PIN" "missing or not an exact x.y.z pin: ${RESEND_PIN_VALUE:-<missing>}"
fi
awk '/^resend_install\(\)/,/^}$/' "${STARTUP}" | sed -n 's/^ *sha256="\([^"]*\)".*/\1/p' >"${WORK}/resend_hashes"
RESEND_BAD=0
RESEND_N=0
while read -r h; do
  RESEND_N=$((RESEND_N + 1))
  [[ "${h}" =~ ^[0-9a-f]{64}$ ]] || RESEND_BAD=1
done <"${WORK}/resend_hashes"
if [[ ${RESEND_N} -ge 3 && ${RESEND_BAD} -eq 0 ]]; then
  pass "resend sha256" "${RESEND_N} platform hashes, all 64-char hex"
else
  fail "resend sha256" "expected >=3 valid platform hashes, got ${RESEND_N} (bad=${RESEND_BAD})"
fi

# 9. ENTIRE_PIN + ENTIRE_SHA256_* (issue #91). ENTIRE_PIN must be a
# non-floating x.y.z, exactly like pi's. The four per-platform SHA256
# constants must each be present and a 64-char lowercase hex string — the
# runtime install fails closed on any missing entry, so the CI check just
# catches that case earlier, before a sandbox sees it. The tarball URL is
# derived inline from ENTIRE_PIN (no separate constant to drift), so it
# stays in sync by construction; no extra cross-check needed there.
ENTIRE_PIN_VALUE="$(sed -n 's/^ENTIRE_PIN="\([^"]*\)".*/\1/p' "${STARTUP}")"
if ! [[ "${ENTIRE_PIN_VALUE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "ENTIRE_PIN" "missing or not an exact x.y.z pin: ${ENTIRE_PIN_VALUE:-<missing>}"
else
  pass "ENTIRE_PIN" "exact pin ${ENTIRE_PIN_VALUE}"
fi
for plat in LINUX_AMD64 LINUX_ARM64 DARWIN_AMD64 DARWIN_ARM64; do
  hash_value="$(sed -n "s/^ENTIRE_SHA256_${plat}=\"\([0-9a-f]*\)\".*/\1/p" "${STARTUP}")"
  if [[ -z "${hash_value}" ]]; then
    fail "ENTIRE_SHA256_${plat}" "missing — required for issue #91's entire install on platform ${plat,,}"
  elif ! [[ "${hash_value}" =~ ^[0-9a-f]{64}$ ]]; then
    fail "ENTIRE_SHA256_${plat}" "not a 64-char lowercase hex sha256: ${hash_value}"
  else
    pass "ENTIRE_SHA256_${plat}" "pinned (${hash_value:0:12}...)"
  fi
done

if [[ ${FAILED} -ne 0 ]]; then
  log "pin validation FAILED"
  exit 1
fi
log "pin validation passed"
