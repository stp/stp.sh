# Worktree helpers for STP. Works in bash and zsh; source it from your rc file:
#
#     export STP_GIT=~/clones/stp/stp.git
#     source ~/clones/stp.sh/stp-worktree.sh
#
# It gives you four commands:
#
#     stp-env                     show what everything is set to
#     stp-warm                    fill the shared dependency caches, once
#     stp-new <branch> [from]     new branch in its own worktree
#     stp-build [worktree] [...]  configure and build one
#
# The point of all of it is that a worktree should be cheap. See the
# "Working across several worktrees" section of STP's own docs/building.rst
# for what these are doing and why. Nothing here is required to build STP --
# these only save you typing the same flags into every worktree.

# --- where things are ---------------------------------------------------
#
# STP_GIT is the only one you have to set: the bare repository. Worktrees are
# assumed to sit beside it, which is what `git worktree add` does by default
# if you let it.
: "${STP_GIT:=${HOME}/clones/stp/stp.git}"
: "${STP_CACHE:=${HOME}/.cache/stp}"
export STP_GIT STP_CACHE

# The four below are worked out when a command runs rather than when this file
# is sourced, so that STP_CACHE can be pointed somewhere else for one command
# and the rest follow it:
#
#     STP_CACHE=~/.cache/stp-asan stp-warm
#
# Setting any of them directly still wins, for a layout that does not fit.
_stp_root()  { printf '%s\n' "${STP_ROOT:-$(dirname "${STP_GIT}")}"; }
_stp_deps()  { printf '%s\n' "${STP_DEP_DIR:-${STP_CACHE}/deps}"; }
_stp_fetch() { printf '%s\n' "${STP_FETCH_DIR:-${STP_CACHE}/fetch}"; }
_stp_warm()  { printf '%s\n' "${STP_WARM_DIR:-${STP_CACHE}/warm}"; }

# `readlink -f` is GNU-only; this is the portable spelling and it is enough
# here, where everything being compared is a directory that exists.
_stp_abs() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

# ccache hashes the absolute path of the source when debug information is on,
# and STP always compiles with -g. Without these two, two worktrees share
# nothing: measured, 0 hits out of 282. With them, 131 of 141.
#
# CCACHE_BASEDIR only rewrites paths *below* it, which is why stp-build puts
# the build directory inside the worktree rather than somewhere in /tmp. A
# worktree outside STP_ROOT gets no sharing; move it under, or widen this.
: "${CCACHE_BASEDIR:=$(_stp_root)}"
: "${CCACHE_NOHASHDIR:=1}"
export CCACHE_BASEDIR CCACHE_NOHASHDIR

_stp_err() { printf 'stp: %s\n' "$*" >&2; return 1; }

_stp_have() { command -v "$1" >/dev/null 2>&1; }

# Fills the array STP_ARGS. An array rather than a string because the values
# contain paths, and re-splitting a string on spaces is how those break.
_stp_common_args() {
    STP_ARGS=("-DSTP_DEP_DIR=$(_stp_deps)")
    _stp_have ninja && STP_ARGS+=(-G Ninja)
    if _stp_have ccache; then
        STP_ARGS+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
    fi
    return 0
}

# The dependencies STP compiles rather than links -- mimalloc, unordered_dense,
# googletest, OutputCheck -- are added to the build with add_subdirectory, and
# FetchContent builds those in ${FETCHCONTENT_BASE_DIR}/<name>-build. That
# directory is *shared* if the base directory is, which is not what sharing a
# download should mean: two worktrees whose compiler or build type differ then
# overwrite each other's objects, and each one recompiles all of mimalloc the
# next time it is built. Measured, that is 37 steps on every alternation, in
# both directions, for as long as you keep switching between them.
#
# So share the sources and keep the builds apart: the base directory goes
# inside the build tree, and each fetched source is pointed at the copy
# stp-warm downloaded. Only the ones that exist are named -- pointing
# FETCHCONTENT_SOURCE_DIR_* at a directory that is not there fails the
# configure rather than falling back to downloading.
_stp_fetch_args() {
    local build="$1" shared name upper
    shared="$(_stp_fetch)"
    STP_ARGS+=("-DFETCHCONTENT_BASE_DIR=${build}/_deps")
    for name in mimalloc unordereddense googletest outputcheck; do
        if [ -d "${shared}/${name}-src" ]; then
            upper=$(printf '%s' "${name}" | tr '[:lower:]' '[:upper:]')
            STP_ARGS+=("-DFETCHCONTENT_SOURCE_DIR_${upper}=${shared}/${name}-src")
        fi
    done
    return 0
}

# Resolve a worktree argument: a path, a name under STP_ROOT, or the current
# directory. Prints the absolute path, or fails saying what it looked for.
_stp_resolve() {
    local want="${1:-.}"
    local dir root
    root="$(_stp_root)"
    if [ -d "${want}/.git" ] || [ -f "${want}/.git" ]; then
        dir="$(_stp_abs "${want}")"
    elif [ -e "${root}/${want}/CMakeLists.txt" ]; then
        dir="${root}/${want}"
    elif [ "${want}" = "." ]; then
        dir="$(git rev-parse --show-toplevel 2>/dev/null)" || dir=""
        [ -n "${dir}" ] || { _stp_err "not in a git worktree, and no worktree named"; return 1; }
    else
        _stp_err "no worktree '${want}' here or at ${root}/${want}"; return 1
    fi
    [ -e "${dir}/CMakeLists.txt" ] || { _stp_err "${dir} is not an STP checkout"; return 1; }
    printf '%s\n' "${dir}"
}

# --- stp-env ------------------------------------------------------------
stp-env() {
    local d f g n
    d="$(_stp_deps)"; f="$(_stp_fetch)"
    printf 'STP_GIT          %s%s\n' "${STP_GIT}"  "$([ -d "${STP_GIT}" ] || printf '   (missing)')"
    printf 'STP_ROOT         %s\n'   "$(_stp_root)"
    printf 'STP_CACHE        %s\n'   "${STP_CACHE}"
    printf 'STP_DEP_DIR      %s%s\n' "${d}" "$([ -d "${d}" ] || printf '   (cold)')"
    printf 'STP_FETCH_DIR    %s%s\n' "${f}" "$([ -d "${f}" ] || printf '   (cold)')"
    printf 'STP_WARM_DIR     %s\n'   "$(_stp_warm)"
    printf 'CCACHE_BASEDIR   %s\n'   "${CCACHE_BASEDIR}"
    printf 'CCACHE_NOHASHDIR %s\n'   "${CCACHE_NOHASHDIR}"
    for g in ninja ccache; do
        if _stp_have "${g}"; then n=yes; else n="no (optional)"; fi
        printf '%-16s %s\n' "${g}" "${n}"
    done
    if [ -d "${STP_GIT}" ]; then
        printf 'worktrees        %s\n' \
            "$(git -C "${STP_GIT}" worktree list 2>/dev/null | wc -l | tr -d ' ')"
    fi
}

# --- stp-warm -----------------------------------------------------------
#
# Builds every dependency once, into the shared directories, so that the
# worktrees that follow find them instead of building them. Uses whichever
# checkout you give it purely as a source of CMake files -- nothing of STP
# itself is built.
#
# ENABLE_TESTING is on so that the lit virtual environment is created too:
# lit is pip-installed per build directory rather than fetched, so this is
# the one copy a disconnected build can be pointed at.
stp-warm() {
    local wt warm had
    wt="$(_stp_resolve "${1:-master}")" || return 1
    warm="$(_stp_warm)"
    printf 'stp: warming %s and %s from %s\n' "$(_stp_deps)" "$(_stp_fetch)" "${wt}"
    _stp_common_args
    STP_ARGS+=("-DFETCHCONTENT_BASE_DIR=$(_stp_fetch)")

    # This build directory is scratch -- what it produces lives in
    # STP_DEP_DIR, not here -- but CMake refuses to reuse a cache that a
    # different source directory generated, and warming from whichever
    # worktree is to hand is the normal thing to do. So discard it rather
    # than fail, which costs a reconfigure and nothing else.
    if [ -e "${warm}/CMakeCache.txt" ]; then
        had="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "${warm}/CMakeCache.txt")"
        if [ -n "${had}" ] && [ "$(_stp_abs "${had}")" != "$(_stp_abs "${wt}")" ]; then
            printf 'stp: warm directory was configured from %s; starting it again\n' "${had}"
            rm -rf -- "${warm}"
        fi
    fi

    cmake -S "${wt}" -B "${warm}" "${STP_ARGS[@]}" \
        -DENABLE_AUTO_DOWNLOAD=ON -DENABLE_TESTING=ON || return 1
    cmake --build "${warm}" --target deps || return 1
    printf 'stp: warm. lit at %s/venv/bin/lit\n' "${warm}"
}

# --- stp-new ------------------------------------------------------------
#
# A branch and its worktree in one step. Second argument is what to branch
# from, defaulting to master.
stp-new() {
    local branch="$1" from="${2:-master}" dir
    [ -n "${branch}" ] || { _stp_err "usage: stp-new <branch> [start-point]"; return 1; }
    [ -d "${STP_GIT}" ] || { _stp_err "STP_GIT does not exist: ${STP_GIT}"; return 1; }
    dir="$(_stp_root)/${branch}"
    [ -e "${dir}" ] && { _stp_err "${dir} already exists"; return 1; }
    git -C "${STP_GIT}" worktree add "${dir}" -b "${branch}" "${from}" || return 1
    printf 'stp: %s at %s (from %s)\n' "${branch}" "${dir}" "${from}"
    cd "${dir}" || return 1
}

# --- stp-build ----------------------------------------------------------
#
# Configure if it has not been configured, then build. Any extra arguments
# are passed to CMake and force a reconfigure, so
#
#     stp-build my-feature -DENABLE_TESTING=ON
#
# does what you would expect. The build directory is <worktree>/build, which
# has to be inside the worktree for CCACHE_BASEDIR to rewrite its paths.
stp-build() {
    local wt build had want jobs
    wt="$(_stp_resolve "${1:-.}")" || return 1
    [ $# -gt 0 ] && shift
    build="${wt}/build"
    _stp_common_args
    _stp_fetch_args "${build}"

    if [ ! -e "${build}/CMakeCache.txt" ] || [ $# -gt 0 ]; then
        cmake -S "${wt}" -B "${build}" "${STP_ARGS[@]}" -DENABLE_AUTO_DOWNLOAD=ON "$@" || return 1
    else
        # An existing build directory is built with whatever it was configured
        # with, which is right -- reconfiguring someone's build behind their
        # back is worse. But a directory configured without the shared
        # dependency tree shares nothing, builds everything itself, and looks
        # from the outside exactly like one that does. Say so once.
        had="$(sed -n 's/^STP_DEP_DIR:PATH=//p' "${build}/CMakeCache.txt")"
        want="$(_stp_deps)"
        if [ -n "${had}" ] && [ "$(_stp_abs "${had}")" != "$(_stp_abs "${want}")" ]; then
            printf 'stp: %s was configured with STP_DEP_DIR=%s,\n' "${build}" "${had}" >&2
            printf 'stp: not %s. Building it as it is.\n' "${want}" >&2
            printf 'stp: to move it, pass any cmake argument to reconfigure, or delete %s.\n' "${build}" >&2
        fi
    fi
    jobs="$(nproc 2>/dev/null || printf '4')"
    cmake --build "${build}" --parallel "${jobs}" || return 1
    printf 'stp: built %s\n' "${build}"
}
