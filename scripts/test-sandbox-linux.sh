#!/bin/sh
# Linux-only e2e probe for the bash strict-mode sandbox boundary.
#
# Spawns the already-built zag binary as the sandbox helper, exactly the
# way tools/bash.zig does in strict mode:
#
#     zag --__sandbox-helper <cwd> <home> -- /bin/sh -c <probe>
#
# main.zig short-circuits that argv into helper_linux.run, which installs
# landlock (filesystem) + seccomp-bpf (socket family) and then execve's the
# tail. So the probes below run under the REAL kernel enforcement, which the
# in-process `zig build test` runner can never exercise (the test runner
# replaces main(), so the --__sandbox-helper branch never fires).
#
# Asserts:
#   1. opening an AF_INET socket / connecting out is denied. bash's
#      /dev/tcp redirect forces a socket(AF_INET) which the seccomp filter
#      rejects with EACCES before connect() is ever reached.
#   2. reading a secret like ~/.ssh/id_rsa is denied. landlock does not
#      grant $HOME, so the read fails with EPERM/EACCES and no key bytes
#      leak (holds whether or not the file exists: a denied subtree yields
#      a permission error, not ENOENT-with-content).
#
# THIS SCRIPT ONLY MEANINGFULLY RUNS ON A LINUX HOST. The build step that
# invokes it is gated on `target.result.os.tag == .linux`, so a macOS dev
# box never reaches here through `zig build test-sandbox-linux`. The one way
# it CAN be reached on macOS is a cross-compile (`-Dtarget=x86_64-linux`),
# which installs a Linux ELF that cannot execve on the macOS host. To keep
# that from silently passing, every probe asserts its own `EXIT=` marker is
# present in the output: that marker is printed by the in-sandbox shell and
# only appears if the helper actually exec'd. A missing marker (exec format
# error, missing shell, helper crash) is a HARD FAIL, never a false "denied".
#
# On a kernel without landlock/seccomp the helper falls back to unconfined
# and prints a warning to stderr. That is the codebase's documented stance
# (see tools/bash.zig docstring), so this script SKIPS (exit 0) rather than
# failing, to avoid false negatives on CI runners with stripped kernels.

set -eu

ZAG="${1:?path to built zag binary required}"

if [ ! -x "$ZAG" ]; then
    echo "FAIL: zag binary not executable: $ZAG" >&2
    exit 1
fi

# The helper prints a one-line warning to stderr when a kernel feature is
# unavailable and it falls back to unconfined. If either feature is missing
# the boundary we are asserting does not exist, so skip instead of fail.
is_fallback_warning() {
    case "$1" in
        *"sandbox unavailable"*|\
        *"sandbox setup failed"*|\
        *"net filter unavailable"*|\
        *"net filter setup failed"*|\
        *"running unconfined"*|\
        *"network unrestricted"*)
            return 0
            ;;
    esac
    return 1
}

# A probe ran for real only if its shell reached `echo EXIT=$?`. Without
# that marker the helper never exec'd the shell (exec format error on a
# cross-compiled binary, a missing /bin/sh, or a helper crash). In that
# case the absence of `EXIT=0` is meaningless, so treat it as a hard fail
# rather than reporting a bogus "denied".
has_exit_marker() {
    case "$1" in
        *EXIT=*) return 0 ;;
    esac
    return 1
}

# --- Probe 1: AF_INET socket must be denied ------------------------------
# bash's /dev/tcp pseudo-device forces a socket(AF_INET, SOCK_STREAM) syscall
# before any connect(), so seccomp's family filter is what fails it. Guard on
# bash being present (minimal images may ship only /bin/sh).
if command -v bash >/dev/null 2>&1; then
    net_out="$("$ZAG" --__sandbox-helper "$PWD" "$HOME" -- \
        /bin/bash -c 'exec 3<>/dev/tcp/93.184.216.34/80 2>&1; echo EXIT=$?' 2>&1 || true)"

    if is_fallback_warning "$net_out"; then
        echo "SKIP: kernel lacks seccomp/landlock support (helper ran unconfined)"
        echo "  helper said: $net_out"
        exit 0
    fi

    if ! has_exit_marker "$net_out"; then
        echo "FAIL: AF_INET probe never executed (no EXIT marker); helper could not run the shell" >&2
        echo "  output: $net_out" >&2
        exit 1
    fi

    case "$net_out" in
        *EXIT=0*)
            echo "FAIL: AF_INET socket/connect succeeded under strict sandbox" >&2
            echo "  output: $net_out" >&2
            exit 1
            ;;
    esac
    echo "ok: AF_INET socket denied (non-zero exit; EACCES from seccomp)"
else
    echo "SKIP: bash not installed; cannot force a /dev/tcp AF_INET socket"
fi

# --- Probe 2: secret read must be denied ---------------------------------
secret_out="$("$ZAG" --__sandbox-helper "$PWD" "$HOME" -- \
    /bin/sh -c 'cat "$HOME/.ssh/id_rsa" 2>&1; echo EXIT=$?' 2>&1 || true)"

if is_fallback_warning "$secret_out"; then
    echo "SKIP: kernel lacks landlock support (helper ran unconfined)"
    echo "  helper said: $secret_out"
    exit 0
fi

if ! has_exit_marker "$secret_out"; then
    echo "FAIL: secret-read probe never executed (no EXIT marker); helper could not run the shell" >&2
    echo "  output: $secret_out" >&2
    exit 1
fi

case "$secret_out" in
    *BEGIN*|*"PRIVATE KEY"*)
        echo "FAIL: ~/.ssh/id_rsa key material leaked through the sandbox" >&2
        exit 1
        ;;
esac
case "$secret_out" in
    *EXIT=0*)
        echo "FAIL: ~/.ssh/id_rsa read succeeded under strict sandbox" >&2
        echo "  output: $secret_out" >&2
        exit 1
        ;;
esac
echo "ok: ~/.ssh/id_rsa read denied (non-zero exit; EPERM/EACCES from landlock)"

echo "sandbox-linux: OK"
