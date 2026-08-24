# Worktree helpers for STP. Source this from ~/.zshrc:
#
#     export STP_GIT=~/clones/stp/stp.git
#     source ~/clones/stp.zsh/stp-worktree.zsh
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
: ${STP_GIT:=${HOME}/clones/stp/stp.git}
: ${STP_CACHE:=${HOME}/.cache/stp}
export STP_GIT STP_CACHE

# The four below are worked out when a command runs rather than when this file
# is sourced, so that STP_CACHE can be pointed somewhere else for one command
# and the rest follow it:
#
#     STP_CACHE=~/.cache/stp-asan stp-warm
#
# Setting any of them directly still wins, for a layout that does not fit.
_stp_root()  { print -r -- ${STP_ROOT:-${STP_GIT:h}} }
_stp_deps()  { print -r -- ${STP_DEP_DIR:-${STP_CACHE}/deps} }
_stp_fetch() { print -r -- ${STP_FETCH_DIR:-${STP_CACHE}/fetch} }
_stp_warm()  { print -r -- ${STP_WARM_DIR:-${STP_CACHE}/warm} }

# ccache hashes the absolute path of the source when debug information is on,
# and STP always compiles with -g. Without these two, two worktrees share
# nothing: measured, 0 hits out of 282. With them, 131 of 141.
#
# CCACHE_BASEDIR only rewrites paths *below* it, which is why stp-build puts
# the build directory inside the worktree rather than somewhere in /tmp. A
# worktree outside STP_ROOT gets no sharing; move it under, or widen this.
: ${CCACHE_BASEDIR:=$(_stp_root)}
: ${CCACHE_NOHASHDIR:=1}
export CCACHE_BASEDIR CCACHE_NOHASHDIR

_stp_err() { print -u2 -- "stp: $*"; return 1 }

_stp_have() { (( $+commands[$1] )) }

# The generator and the compiler cache are used if present, not required.
_stp_common_args() {
    local -a args
    args=(
        -DSTP_DEP_DIR="$(_stp_deps)"
        -DFETCHCONTENT_BASE_DIR="$(_stp_fetch)"
    )
    _stp_have ninja && args+=(-G Ninja)
    if _stp_have ccache; then
        args+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
    fi
    print -r -- ${(j: :)${(q)args}}
}

# Resolve a worktree argument: a path, a name under STP_ROOT, or the current
# directory. Prints the absolute path, or fails saying what it looked for.
_stp_resolve() {
    local want=${1:-.}
    local dir
    if [[ -d ${want}/.git || -f ${want}/.git ]]; then
        dir=${want:A}
    elif [[ -e $(_stp_root)/${want}/CMakeLists.txt ]]; then
        dir=$(_stp_root)/${want}
    elif [[ ${want} == . ]]; then
        dir=$(git rev-parse --show-toplevel 2>/dev/null) || \
            { _stp_err "not in a git worktree, and no worktree named"; return 1 }
    else
        _stp_err "no worktree '${want}' here or at $(_stp_root)/${want}"; return 1
    fi
    [[ -e ${dir}/CMakeLists.txt ]] || { _stp_err "${dir} is not an STP checkout"; return 1 }
    print -r -- ${dir}
}

# --- stp-env ------------------------------------------------------------
stp-env() {
    local d=$(_stp_deps) f=$(_stp_fetch)
    print -r -- "STP_GIT          ${STP_GIT}$([[ -d ${STP_GIT} ]] || print -n '   (missing)')"
    print -r -- "STP_ROOT         $(_stp_root)"
    print -r -- "STP_CACHE        ${STP_CACHE}"
    print -r -- "STP_DEP_DIR      ${d}$([[ -d ${d} ]] || print -n '   (cold)')"
    print -r -- "STP_FETCH_DIR    ${f}$([[ -d ${f} ]] || print -n '   (cold)')"
    print -r -- "STP_WARM_DIR     $(_stp_warm)"
    print -r -- "CCACHE_BASEDIR   ${CCACHE_BASEDIR}"
    print -r -- "CCACHE_NOHASHDIR ${CCACHE_NOHASHDIR}"
    local g n
    for g in ninja ccache; do
        _stp_have $g && n=yes || n="no (optional)"
        print -r -- "$(printf '%-16s' $g) ${n}"
    done
    if [[ -d ${STP_GIT} ]]; then
        print -r -- "worktrees        $(git -C ${STP_GIT} worktree list 2>/dev/null | wc -l | tr -d ' ')"
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
    local wt; wt=$(_stp_resolve "${1:-master}") || return 1
    print -r -- "stp: warming $(_stp_deps) and $(_stp_fetch) from ${wt}"
    local -a args; args=(${(z)$(_stp_common_args)})
    local warm=$(_stp_warm)

    # This build directory is scratch -- what it produces lives in
    # STP_DEP_DIR, not here -- but CMake refuses to reuse a cache that a
    # different source directory generated, and warming from whichever
    # worktree is to hand is the normal thing to do. So discard it rather
    # than fail, which costs a reconfigure and nothing else.
    if [[ -e ${warm}/CMakeCache.txt ]]; then
        local had=$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' ${warm}/CMakeCache.txt)
        if [[ -n ${had} && ${had:A} != ${wt:A} ]]; then
            print -r -- "stp: warm directory was configured from ${had}; starting it again"
            rm -rf -- ${warm}
        fi
    fi

    cmake -S "${wt}" -B "${warm}" ${args} \
        -DENABLE_AUTO_DOWNLOAD=ON -DENABLE_TESTING=ON || return 1
    cmake --build "$(_stp_warm)" --target deps || return 1
    print -r -- "stp: warm. lit at $(_stp_warm)/venv/bin/lit"
}

# --- stp-new ------------------------------------------------------------
#
# A branch and its worktree in one step. Second argument is what to branch
# from, defaulting to master.
stp-new() {
    local branch=$1 from=${2:-master}
    [[ -n ${branch} ]] || { _stp_err "usage: stp-new <branch> [start-point]"; return 1 }
    [[ -d ${STP_GIT} ]] || { _stp_err "STP_GIT does not exist: ${STP_GIT}"; return 1 }
    local dir=$(_stp_root)/${branch}
    [[ -e ${dir} ]] && { _stp_err "${dir} already exists"; return 1 }
    git -C "${STP_GIT}" worktree add "${dir}" -b "${branch}" "${from}" || return 1
    print -r -- "stp: ${branch} at ${dir} (from ${from})"
    cd "${dir}"
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
    local wt; wt=$(_stp_resolve "${1:-.}") || return 1
    [[ $# -gt 0 ]] && shift
    local build=${wt}/build
    local -a args; args=(${(z)$(_stp_common_args)})

    if [[ ! -e ${build}/CMakeCache.txt || $# -gt 0 ]]; then
        cmake -S "${wt}" -B "${build}" ${args} -DENABLE_AUTO_DOWNLOAD=ON "$@" || return 1
    fi
    cmake --build "${build}" --parallel "$(nproc 2>/dev/null || print 4)" || return 1
    print -r -- "stp: built ${build}"
}
