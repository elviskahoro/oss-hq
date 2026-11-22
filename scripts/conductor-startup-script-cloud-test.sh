#!/usr/bin/env bash
# Codified container verification for
# scripts/conductor-startup-script-cloud.sh.
#
# Runs INSIDE a throwaway amazonlinux:2023 container (the real Conductor
# cloud / Vercel runtime class), replicating the sandbox shape: a non-root
# user with passwordless sudo. Usage, from the repo root, with the docker
# host's NATIVE platform (never qemu emulation: the pinned Go binaries crash
# or hang at random there, issue #92):
#
#   docker run --platform linux/<native-arch> --rm -v "$PWD":/src:ro -w /src \
#     amazonlinux:2023 bash scripts/conductor-startup-script-cloud-test.sh
#
# Scope (issue #185: the script only provisions sandbox CLIs):
#   - shadow-safety facts for the python3.13 shim over AL2023's 3.9
#   - prerequisite gate: the image has no tar, so RUN 1 exercises
#     ensure_archive_tools (dnf-installs tar/gzip as non-root via sudo); RUN 2
#     covers its already-present short-circuit
#   - RUN 1: fresh run, no RWX_ACCESS_TOKEN: rwx, infisical, resend, railway, entire
#     (+ git-remote-entire), uv and python3.13 resolve under /usr/local/bin at
#     their pins, /usr/bin/python3 stays 3.9, dnf still works, the no-token WARN
#     row is present, and there are no FAIL rows. Dropped stages (roborev, pi,
#     pytools) must NOT appear.
#   - RUN 2: idempotent re-run: no FAIL rows, no ~/.local/bin fallback, reuse rows.
# Exits non-zero on the first broken assertion.
set -euo pipefail

# This suite provisions its own sandbox-user with dnf, so it must run as root
# inside the throwaway container (see Usage above). In a real non-root
# sandbox the first dnf call fails with "This command has to be run with
# superuser privileges"; fail early with the right pointer instead.
if [[ "$(id -u)" != 0 ]]; then
  echo "TEST FAIL: this suite must run as root inside a throwaway amazonlinux:2023 container (see Usage). To provision a workspace, run scripts/conductor-startup-script-cloud.sh instead." >&2
  exit 1
fi

# qemu-user runs a binary as `qemu-<arch> <binary> ...`, so the emulator is
# this shell's argv[0] (issue #92: see the usage note above). It must be read
# by a child process: qemu fakes a process's view of its own cmdline (bash's
# builtin read sees just "bash"), but not another process's.
emulator="$(tr '\0' '\n' </proc/$$/cmdline | sed -n 1p)"
if [[ "${emulator}" == *qemu-* ]]; then
  echo "TEST FAIL: running under ${emulator##*/} emulation, where the pinned Go binaries crash or hang at random (issue #92) — re-run with the docker host's native --platform" >&2
  exit 1
fi

STARTUP_SCRIPT="/src/scripts/conductor-startup-script-cloud.sh"

fail() { echo "TEST FAIL: $*" >&2; exit 1; }

# tar is deliberately NOT installed here: stock amazonlinux:2023 omits it, so
# RUN 1 makes the startup script's ensure_archive_tools install it back (as
# sandbox-user via sudo). If a future image ships tar, remove it before RUN 1.
dnf install -y sudo shadow-utils util-linux >/dev/null
command -v tar >/dev/null 2>&1 && fail "tar present before RUN 1; the prerequisite gate would go untested"
useradd -m sandbox-user
echo "sandbox-user ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/sandbox-user
chmod 440 /etc/sudoers.d/sandbox-user
# RWX's Docker runs containers where sudo's PAM account check fails (the
# setuid unix_chkpwd helper cannot read /etc/shadow), which would silently
# skip the sudo-only install paths. Let the user's group read shadow, only
# when sudo is actually broken, so the test exercises the real sudo path.
if ! su sandbox-user -c 'sudo -n true' >/dev/null 2>&1; then
  chgrp sandbox-user /etc/shadow
  chmod 640 /etc/shadow
fi

# Shadow-safety fact 1: dnf's own interpreter must be reached by an absolute
# shebang — not /usr/bin/env python3, which PATH would resolve through
# /usr/local/bin and the 3.13 shadow.
DNF_SHEBANG="$(head -1 /usr/bin/dnf)"
echo "dnf shebang: ${DNF_SHEBANG}"
[[ "${DNF_SHEBANG}" == '#!/usr/bin/python3' ]] ||
  fail "expected /usr/bin/dnf shebang #!/usr/bin/python3, got: ${DNF_SHEBANG}"

# Shadow-safety fact 2 (tripwire): no /usr/bin or /usr/sbin script may
# resolve its interpreter through PATH. A future AL2023 image that adds an
# env-shebang system tool fails here, forcing the shadow argument to be
# re-checked before the startup script's comment stays truthful. (grep
# exits 1 on zero matches — the expected outcome here — so neutralize it
# for set -e/pipefail instead of dying silently.)
ENV_PY3_CONSUMERS="$({ grep -rl '^#!/usr/bin/env python3' /usr/bin /usr/sbin 2>/dev/null || true; } | tr '\n' ' ')"
echo "env-python3 consumers in /usr/bin /usr/sbin: ${ENV_PY3_CONSUMERS:-none}"
[[ -z "${ENV_PY3_CONSUMERS}" ]] ||
  fail "unexpected /usr/bin/env python3 system consumers: ${ENV_PY3_CONSUMERS}"


echo "=== RUN 1: fresh startup run (login shell of non-root sandbox-user, no token) ==="
RUN1_OUTPUT="$(su - sandbox-user -c "bash ${STARTUP_SCRIPT}")" ||
  fail "fresh conductor-startup-script-cloud.sh exited non-zero"
printf '%s\n' "${RUN1_OUTPUT}"
case "${RUN1_OUTPUT}" in
*" | FAIL |"*) fail "fresh run recorded FAIL row(s)" ;;
esac
case "${RUN1_OUTPUT}" in *"RWX_ACCESS_TOKEN not set"*) ;; *) fail "fresh run missing the no-token WARN row" ;; esac
for stage in rwx infisical resend railway entire python3.13 uv; do
  case "${RUN1_OUTPUT}" in *" ${stage} | PASS |"*) ;; *) fail "fresh run missing a PASS row for ${stage}" ;; esac
done
for gone in roborev pi pytools python3.11; do
  case "${RUN1_OUTPUT}" in *" ${gone} |"*) fail "dropped stage ${gone} still produced a row" ;; esac
done

echo "=== VERIFY: every deliverable resolves as sandbox-user ==="
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  pin() { sed -n \"s/^\$1=\\\"\([^\\\"]*\)\\\".*/\\1/p\" ${STARTUP_SCRIPT}; }
  at_local_bin() { [ \"\$(command -v \$1)\" = \"/usr/local/bin/\$1\" ] || fail \"\$1 resolved to \$(command -v \$1)\"; }

  command -v tar >/dev/null || fail \"tar missing after startup: ensure_archive_tools did not install it\"
  at_local_bin python3
  python3 --version 2>&1 | grep -q '^Python 3\.13\.' || fail \"python3 is not 3.13: \$(python3 --version 2>&1)\"
  pip3 --version 2>&1 | grep -q 'python 3\.13' || fail \"pip3 does not run on python 3.13: \$(pip3 --version 2>&1)\"

  at_local_bin rwx
  out=\"\$(rwx --version 2>&1)\" || true
  printf '%s' \"\${out}\" | grep -q \"\$(pin RWX_PIN)\" || fail \"rwx does not report the pin: \${out}\"

  at_local_bin infisical
  out=\"\$(infisical --version 2>&1)\" || true
  printf '%s' \"\${out}\" | grep -q \"\$(pin INFISICAL_PIN)\" || fail \"infisical does not report the pin: \${out}\"

  at_local_bin resend
  out=\"\$(resend --version 2>&1)\" || true
  printf '%s' \"\${out}\" | grep -q \"\$(pin RESEND_PIN)\" || fail \"resend does not report the pin: \${out}\"

  at_local_bin railway
  out=\"\$(railway --version 2>&1)\" || true
  printf '%s' \"\${out}\" | grep -q \"\$(pin RAILWAY_PIN)\" || fail \"railway does not report the pin: \${out}\"

  at_local_bin entire
  out=\"\$(entire version 2>&1)\" || true
  printf '%s' \"\${out}\" | grep -q \"Entire CLI \$(pin ENTIRE_PIN)\" || fail \"entire does not report the pin: \${out}\"
  at_local_bin git-remote-entire
  git-remote-entire --help >/dev/null 2>&1 || fail \"git-remote-entire is not runnable\"

  at_local_bin uv
  out=\"\$(uv --version 2>&1)\" || true
  printf '%s' \"\${out}\" | grep -q \"\$(pin UV_PIN)\" || fail \"uv does not report the pin: \${out}\"

  /usr/bin/python3 --version 2>&1 | grep -q '^Python 3\.9\.' || fail \"/usr/bin/python3 must stay 3.9 for dnf\"
  sudo dnf repolist >/dev/null 2>&1 || fail \"dnf stopped working after the python3 shadow\"
  for gone in roborev pi pytest reflex ruff pyright pyrefly; do
    ! command -v \${gone} >/dev/null 2>&1 || fail \"\${gone} must not be provisioned by setup (it runs on RWX)\"
  done
" || fail "verification as sandbox-user failed"

echo "=== RUN 2: idempotent re-run ==="
RUN2_OUTPUT="$(su - sandbox-user -c "bash ${STARTUP_SCRIPT}")" ||
  fail "second conductor-startup-script-cloud.sh exited non-zero"
printf '%s\n' "${RUN2_OUTPUT}"
case "${RUN2_OUTPUT}" in
*" | FAIL |"*) fail "second run recorded FAIL row(s) — not idempotent" ;;
*"~/.local/bin"*) fail "second run used the ~/.local/bin fallback — unexpected on the target class" ;;
esac
case "${RUN2_OUTPUT}" in *"reused"*) ;; *) fail "second run missing reuse rows — re-downloaded instead of reusing" ;; esac

echo "ALL CHECKS PASSED"
