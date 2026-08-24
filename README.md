# stp.sh

Helpers for working on [STP](https://github.com/stp/stp) across several
worktrees. Works in **bash** and **zsh**.

None of this is needed to build STP -- `cmake` and the flags in STP's own
`docs/building.rst` are the whole story. What these save you is typing the
same four flags into every worktree, and remembering the two ccache settings
without which worktrees share no compilation at all.

## Why

STP fetches its dependencies at pinned revisions rather than carrying them in
the repository, which is good for the repository and awkward for a second
worktree: a fresh one looks like a fresh machine to the build and downloads and
rebuilds everything. Pointing every worktree at one shared dependency
directory, one shared fetch directory and one compiler cache fixes that, and
the functions here are that arrangement with names on it.

The "Working across several worktrees" section of STP's `docs/building.rst`
explains what each flag does and why; this repository just applies them.

## Install

Clone it anywhere; the instructions below assume `~/clones/stp.sh`:

```sh
git clone https://github.com/stp/stp.sh ~/clones/stp.sh
```

Then point your shell at it. `STP_GIT` -- your bare STP repository -- is the
only variable you have to set; everything else is derived from it.

### zsh

```zsh
cat >> ~/.zshrc <<'EOF'
# STP worktree helpers -- https://github.com/stp/stp.sh
export STP_GIT=~/clones/stp/stp.git
if [[ -r ~/clones/stp.sh/stp-worktree.sh ]]; then
  source ~/clones/stp.sh/stp-worktree.sh
fi
EOF
exec zsh
```

### bash

```bash
cat >> ~/.bashrc <<'EOF'
# STP worktree helpers -- https://github.com/stp/stp.sh
export STP_GIT=~/clones/stp/stp.git
if [ -r ~/clones/stp.sh/stp-worktree.sh ]; then
  . ~/clones/stp.sh/stp-worktree.sh
fi
EOF
exec bash
```

On macOS a login shell reads `~/.bash_profile` rather than `~/.bashrc`, so
put it there instead, or have one source the other.

The `-r` test is not decoration: without it, moving or deleting the clone
makes every new shell start with an error. It is an `if` rather than
`[ ... ] && ...` for a smaller reason -- the `&&` form leaves `$?` at 1 when
the file is absent, which anyone whose prompt shows the last exit status
would see on every new shell.

Check it took:

```sh
stp-env
```

which prints every path it will use and whether the caches have been filled.

### Requirements

`git` and `cmake`. `ninja` and `ccache` are used if they are installed and
skipped if they are not -- `stp-env` says which it found.

Developed against bash 5.3 and zsh 5.9. Nothing here needs bash 4 features
(no associative arrays, no `mapfile`, no case conversion), so bash 3.2 -- the
one macOS ships -- should be fine, though that is reasoning rather than a
test result.

## Use

```sh
stp-env                       # what everything is set to, and what is cold
stp-warm                      # build the shared dependencies, once
stp-new my-feature            # new branch in its own worktree, and cd into it
stp-build                     # configure if needed, then build
```

A first run is `stp-warm` and then `stp-new`/`stp-build` per branch:

```sh
stp-warm                      # a few minutes, once
stp-new fix-something         # instant, leaves you in the new worktree
stp-build                     # builds STP; the dependencies are already there
```

### `stp-env`

Prints every path the others use, whether the caches have been filled, and
whether `ninja` and `ccache` were found. Run it first if something is not
behaving.

### `stp-warm [worktree]`

Builds every dependency once into the shared directories, using the given
worktree only as a source of CMake files -- nothing of STP itself is built.
Defaults to a worktree called `master`.

Tests are enabled for this build so that the `lit` virtual environment is
created too. `lit` is pip-installed per build directory rather than fetched,
so this is the one copy that a fully disconnected build can be pointed at:

```sh
stp-build my-feature -DLIT_TOOL=~/.cache/stp/warm/venv/bin/lit -DENABLE_TESTING=ON
```

`stp-warm` prints that path when it finishes, and `stp-env` shows it.

### `stp-new <branch> [start-point]`

Creates the branch and its worktree beside the bare repository, then changes
into it. The start point defaults to `master`; if your `master` is behind the
remote, so is your new branch, so fetch first.

### `stp-build [worktree] [cmake args...]`

Configures the worktree if it has not been configured, then builds it. The
worktree can be a path, a name next to the bare repository, or omitted for the
one you are standing in.

Any extra arguments go to CMake and force a reconfigure:

```sh
stp-build my-feature -DENABLE_TESTING=ON -DCMAKE_BUILD_TYPE=Debug
```

The build directory is `<worktree>/build`, and it has to be inside the
worktree: `CCACHE_BASEDIR` only rewrites paths below itself, so a build
directory in `/tmp` gets no cache sharing.

A worktree you made yourself works the same way -- `stp-new` is only a
convenience, and nothing here cares how the worktree came about:

```sh
cd ~/somewhere/my-worktree && stp-build   # anywhere inside it, not just the root
stp-build ~/somewhere/my-worktree         # or by path, from anywhere
stp-build my-worktree                     # by bare name, only if it is under STP_ROOT
```

If it has already been configured, `stp-build` builds it with whatever it was
configured with rather than reconfiguring behind your back. That is usually
what you want, but a build directory set up without the shared dependency tree
shares nothing and looks no different from outside, so it says so:

```
stp: .../build was configured with STP_DEP_DIR=/some/other/place,
stp: not ~/.cache/stp/deps. Building it as it is.
stp: to move it, pass any cmake argument to reconfigure, or delete .../build.
```

## Variables

| Variable | Default | What it is |
| --- | --- | --- |
| `STP_GIT` | `~/clones/stp/stp.git` | the bare STP repository. The only one you must set |
| `STP_ROOT` | the directory holding `STP_GIT` | where worktrees are made and looked for |
| `STP_CACHE` | `~/.cache/stp` | the root of everything shared |
| `STP_DEP_DIR` | `$STP_CACHE/deps` | built dependencies, shared between worktrees |
| `STP_FETCH_DIR` | `$STP_CACHE/fetch` | fetched sources, shared between worktrees |
| `STP_WARM_DIR` | `$STP_CACHE/warm` | the build directory `stp-warm` uses |
| `CCACHE_BASEDIR` | `$STP_ROOT` | see below |
| `CCACHE_NOHASHDIR` | `1` | see below |

The four derived from `STP_CACHE` are worked out when a command runs rather
than when the file is sourced, so pointing `STP_CACHE` elsewhere for a single
command takes the rest with it. Setting any of them directly still wins.

## The ccache settings are not optional

A compiler launcher on its own shares nothing between worktrees. STP compiles
with `-g`, and ccache hashes the absolute path of the source file when debug
information is on, so the same file in two worktrees hashes differently.
Building an identical tree from a second worktree:

| Setting | Cross-worktree hits |
| --- | --- |
| `CMAKE_<LANG>_COMPILER_LAUNCHER=ccache` alone | 0 / 282 (0%) |
| plus `CCACHE_BASEDIR` and `CCACHE_NOHASHDIR` | 131 / 141 (93%) |

which took that build from 26s to 9s. Both are exported for you.

The trade is that a cached object's debug information names the directory of
whichever worktree compiled it first. For everyday work that is a fair price;
before debugging something subtle, build that worktree without the launcher.

## Caveats

A worktree outside `STP_ROOT` gets no cache sharing, because `CCACHE_BASEDIR`
only rewrites paths below itself. Move it under, or set `CCACHE_BASEDIR` wider.

One `STP_DEP_DIR` holds one copy of each library, whatever compiled it. STP
warns when the compiler, sanitizer, toolchain or ABC ABI settings that filled
it differ from the build now using it -- a sanitizer build wants a dependency
directory of its own:

```sh
STP_CACHE=~/.cache/stp-asan stp-warm
```

`STP_FETCH_DIR` needs more care, and `stp-build` handles it for you. The
dependencies STP compiles are added with `add_subdirectory`, and FetchContent
builds those in `<base>/<name>-build` -- so sharing the base directory shares
the *build*, not just the download. Two worktrees whose compiler or build type
differ then own the same object directory, and each recompiles all of mimalloc
the next time it is built: measured with a gcc worktree and a clang one, 37
steps to redo on every alternation, in both directions. Sequential use does not
save you -- nothing is racing, both builds simply own the path they were given.

So `stp-build` puts `FETCHCONTENT_BASE_DIR` inside the build tree and points
each `FETCHCONTENT_SOURCE_DIR_*` at the copy `stp-warm` downloaded: sources
shared, builds private, nothing fetched twice. If you configure by hand, do the
same, or give each build tree its own base directory and accept the extra
downloads.

These assume STP has its dependencies fetched rather than in submodules, which
is true from
[#967](https://github.com/stp/stp/pull/967) onwards. Against anything older
they will not do anything useful.
