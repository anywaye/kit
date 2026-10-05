#!/usr/bin/env bash
#
# kit's dependency bootstrap. SOURCED, not executed.
#
# The property this file exists to establish:
#
#     on a clean checkout with no .venv, ONE command runs the whole gate.
#
#     bash tests/validate.sh
#
# A gate that needs an undocumented manual step is not a gate. `validate.sh`
# used to prefer `$ROOT/.venv/bin/python`, fall back to `python3`, and print
#
#     no python with PyYAML: pip install -r tests/requirements.txt
#     GATE_EXIT=1
#
# `.venv` is gitignored, so *every* fresh clone and *every* CI runner hit that
# — including the CI job this repository now runs on itself. A developer who
# read the two-line instruction in AGENTS.md was fine; a CI runner and anyone
# who cloned without reading were not. That is a gate that fails on arrival
# rather than on content.
#
# So the gate installs its own dependencies on first run, into a directory it
# already owns (`.venv/`, gitignored). Nothing here is a kit dependency: kit
# still ships no library, no lockfile and no runtime code. These are the tools
# the test suite runs, exactly as `shellcheck` is — except that shellcheck is
# optional and these are not, because the suite cannot proceed without them.
#
# Resolved in this order, and the order is the contract:
#
#   1. $KIT_PYTHON — an explicit override is a promise. If it is set and cannot
#      import yaml, that is a configuration error and we say so rather than
#      silently building a second interpreter the caller did not ask for.
#   2. $ROOT/.venv/bin/python — what a previous run of this gate bootstrapped.
#   3. whatever python is on PATH that already has PyYAML — a developer with it
#      system-installed should not pay for a venv.
#   4. bootstrap: create .venv and pip install tests/requirements.txt.
#
# Steps 2 and 3 matter for speed and step 4 for correctness, in that order: a
# warm .venv means a normal gate run never touches the network.

# kit_activate_mise — put mise-managed toolchains on PATH when the invoking
# shell did not. No-op when mise is absent or already active.
#
# WHY THIS EXISTS, and it is the same reason kit_bootstrap_python exists below.
# That function stopped the gate from assuming a python it had not resolved.
# Everything ELSE in the gate still assumed a `command -v` would find go, node,
# gofmt, ruby, elixir and rustc, and that assumption is false in every shell
# that is not interactive: `zsh -c` and `bash -c` do not read `.zshrc`, and a CI
# runner has no rc files at all. On this repository's own machine the tools were
# installed the whole time, mise-managed, and the gate still reported
# `gofmt: command not found` and skipped three snippet checks and the canary
# suite. A check that goes red because of how the gate was launched is not a
# check, and a lint gate that escalates a skip into a failure ("a skipped lint
# proof is not a proof") turns a missing PATH entry into a red build.
#
# WHY mise AND NOT A KIT mise.toml.
#   mise owns version selection; this file only asks it what the environment
#   would have been. Which versions that is depends on config in scope at the
#   time — a repo mise.toml, the user's global one, or none. Pinning kit's own
#   toolchain here would be a second source of truth that CI cannot honour (a
#   runner that has no mise config would resolve to nothing), and kit ships a
#   template for exactly this decision rather than making it for every service.
#
# `mise hook-env` is mise's own supported mechanism for handing a shell that was
# not activated the environment it would otherwise have had — the same call
# `eval "$(mise activate bash)"` makes, minus the per-command hook cost. It is
# safe to eval here for the same reason your .zshrc already evals `mise
# activate zsh`: the output is mise describing its own resolved state.
kit_activate_mise() {
  # Already activated. mise exports MISE_SHELL and __MISE_DIFF into every shell
  # it has set up, so this is the cheap check for "someone else's shell config
  # already did this". Re-deriving would discard a deliberate PATH ordering.
  if [ -n "${MISE_SHELL:-}" ] || [ -n "${__MISE_DIFF:-}" ]; then
    return 0
  fi

  local mise_bin hook
  mise_bin="$(command -v mise 2>/dev/null || true)"
  if [ -z "$mise_bin" ]; then
    return 0
  fi

  hook="$("$mise_bin" hook-env -s bash 2>/dev/null || true)"
  if [ -n "$hook" ]; then
    eval "$hook"
  fi
}

# kit_bootstrap_python — sets $PY, or exits 1 with one paste-able command.
#
# Sets a variable rather than echoing a path because every caller wants it as a
# variable. SC2034 fires on all four assignments because nothing in THIS file
# reads it back; the readers are the two scripts that source this one.
# shellcheck disable=SC2034
kit_bootstrap_python() {
  local root="$1"

  if [ -n "${KIT_PYTHON:-}" ]; then
    if "$KIT_PYTHON" -c 'import yaml' >/dev/null 2>&1; then
      PY="$KIT_PYTHON"
      return 0
    fi
    cat >&2 <<MSG
KIT_PYTHON is set to '$KIT_PYTHON' and it cannot import PyYAML.

An explicit override is a promise, so the gate does not quietly substitute a
different interpreter. Unset KIT_PYTHON to let the gate bootstrap its own:

    unset KIT_PYTHON && bash tests/validate.sh
MSG
    return 1
  fi

  if [ -x "$root/.venv/bin/python" ] && "$root/.venv/bin/python" -c 'import yaml' >/dev/null 2>&1; then
    PY="$root/.venv/bin/python"
    return 0
  fi

  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 &&
      "$candidate" -c 'import yaml' >/dev/null 2>&1; then
      PY="$(command -v "$candidate")"
      return 0
    fi
  done

  # Nothing usable. Build it.
  #
  # `python3 -m venv` rather than a bare `python3`: a venv is the only way to
  # get PyYAML onto a machine that does not have it, and it is the same thing
  # AGENTS.md and the README already told people to run by hand — except that
  # now it happens as part of the gate rather than as a step nobody remembers.
  local creator=''
  for candidate in python3 python; do
    command -v "$candidate" >/dev/null 2>&1 && creator="$candidate" && break
  done

  if [ -z "$creator" ]; then
    cat >&2 <<'MSG'
the gate needs python, and this machine has neither python3 nor python.

Install one and re-run the same command:

    bash tests/validate.sh
MSG
    return 1
  fi

  printf 'note: bootstrapping %s/.venv from tests/requirements.txt (first run)\n' \
    "${root#"$PWD"/}" >&2

  # A venv left behind by a failed or cancelled run is not necessarily broken,
  # but it is cheap to prove rather than assume, and `venv` over an existing
  # directory is the exact thing that produces a half-built environment.
  if [ ! -x "$root/.venv/bin/python" ]; then
    if ! "$creator" -m venv "$root/.venv" >&2; then
      cat >&2 <<MSG
could not create $root/.venv. To do it by hand:

    $creator -m venv $root/.venv && $root/.venv/bin/pip install -r $root/tests/requirements.txt

then re-run:

    bash tests/validate.sh
MSG
      return 1
    fi
  fi

  if ! "$root/.venv/bin/python" -m pip install --quiet --disable-pip-version-check \
    -r "$root/tests/requirements.txt" >&2; then
    cat >&2 <<MSG
could not install the gate's dependencies from tests/requirements.txt
(the download failed, or there is no network). To do it by hand:

    $root/.venv/bin/pip install -r $root/tests/requirements.txt

then re-run:

    bash tests/validate.sh
MSG
    return 1
  fi

  if ! "$root/.venv/bin/python" -c 'import yaml' >/dev/null 2>&1; then
    cat >&2 <<MSG
$root/.venv exists and pip reported success, but PyYAML is still not importable.
Something is wrong with the environment rather than with the gate. Check:

    $root/.venv/bin/pip list

then re-run:

    bash tests/validate.sh
MSG
    return 1
  fi

  PY="$root/.venv/bin/python"
  return 0
}

# hadolint's pinned release, and the sha256 of the binary for the four
# platforms kit's developers and CI actually run on.
#
# Pinned and verified rather than "whatever is on PATH", for the reason the
# check above is a FAIL and not a SKIP: a linter that is silently a different
# version is a check that is silently a different check. The values are hadolint
# 2.15.1's published `checksums.sha256` from the release itself, and the whole
# block is one `HADOLINT_VERSION=` edit away from being updated.
#
# Keyed by asset filename, not by `macos-arm64`. See kit_bootstrap_binary.

# Both read by tests/validate.sh, which sources this file and passes them
# to kit_bootstrap_binary; SC2034 cannot see across a source boundary, for
# the same reason kit_bootstrap_python carries a directive above. One
# directive per statement because that is shellcheck's unit of scope.
# shellcheck disable=SC2034
KIT_HADOLINT_VERSION='2.15.1'
# shellcheck disable=SC2034
KIT_HADOLINT_SHA256S='hadolint-macos-arm64 5c09f3213f8e40406abe048233d985eebef336d4a6a20021be47fadb6cf480a2
hadolint-macos-x86_64 ffe9bb18b23d5ed1eae50237aecdbb523d016e96da0bd4e7aa432040acfc3fde
hadolint-linux-arm64 f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d
hadolint-linux-x86_64 c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507'

# `PATH_SWEEP_DIRS` — directories a scanner bootstrap walks when looking for an
# already-installed tool, on top of `$PATH`.
#
# Set by the caller to the tree it wants searched, so one bootstrap can serve a
# tree other than the one it is running inside. It is empty by default, which is
# the right default: a caller without that problem should not have to think
# about it.
#
# A directory, rather than a direct path to the binary, because the lookup
# mirrors what `command -v` does: a name that resolves to something executable.
# Anything else would need every caller to know the install layout.
PATH_SWEEP_DIRS=""

# kit_bootstrap_binary <name> <release-url-prefix> <sha256-table> <root> [asset-template] [inner-path]
#
# Sets $BIN, or returns 1 with an explanation. Used for the tools that are a
# single static binary rather than a python package: hadolint.
#
# <sha256-table> is keyed by the EXACT ASSET FILENAME, not by an os/arch pair.
# It used to be keyed by `macos-arm64`, which forced every caller's asset name
# to be derivable from `<name>-<os>-<arch>` — true for hadolint, false for
# everything else, and the reason this function could not install a second tool
# without inventing a naming convention the caller then had to match. Keying on
# the filename makes the table say what it is checked against.
#
# <asset-template> may contain @os@ (macos|linux), @ros@ (darwin|linux), @arch@
# (arm64|x86_64) and @triple@ (e.g. aarch64-apple-darwin), and defaults to
# `<name>-@os@-@arch@`. The three OS spellings are spelled out above because upstream
# upstreams disagree about the same fact. <inner-path> is the executable inside
# a `.tar.gz`; when it is given, the asset is fetched, verified, unpacked, and
# the inner file is what gets installed.
#
# Resolution is: already in the gate's own bin dir (a previous run), then on
# PATH (the developer's own install, which they may have pinned differently and
# that is their business), then fetch-and-verify. We do not verify a binary the
# developer installed themselves — the sha256 is a claim about OUR download, not
# about every hadolint on earth.
# shellcheck disable=SC2034
kit_bootstrap_binary() {
  local name="$1" base="$2" sums="$3" root="${4:-.}"
  local template="${5:-$name-@os@-@arch@}" inner="${6:-}"
  # Kept as a local rather than a literal, because it is written twice below and
  # the two writes must be the same directory. See the comment at the mkdir for
  # why it is not `.venv/bin`.
  local dir="$root/tests/.bin"

  # Resolution order, and the order is the contract:
  #   1. $PATH_SWEEP_DIRS — extra trees the caller named (see above)
  #   2. PATH            — the developer's own install
  #   3. this root's .venv/bin — what a previous run of this gate fetched
  #   4. fetch and verify
  #
  # (1) before (2) is deliberate and is the opposite of hadolint's historical
  # order, for a reason specific to how the gate is invoked: a self_test copy
  # must use the binary the REAL tree verified, or each copy re-downloads.
  found=""
  local candidate_dir
  for candidate_dir in $PATH_SWEEP_DIRS; do
    if [ -x "$candidate_dir/$name" ]; then
      found="$candidate_dir/$name"
      break
    fi
  done
  if [ -z "$found" ]; then
    found="$(command -v "$name" 2>/dev/null || true)"
  fi
  if [ -z "$found" ] && [ -x "$dir/$name" ]; then
    found="$dir/$name"
  fi
  if [ -n "$found" ]; then
    BIN="$found"
    return 0
  fi

  local os ros arch triple asset want
  # Three spellings of the same two facts, and they do not agree.
  #
  #   `uname -s`            says Darwin
  #   hadolint's assets     say macos
  #   Rust-style triples    say apple-darwin
  #
  # Getting any of them wrong is a 404, not a clear error, so all three are
  # spelled out here and the template picks. `@os@` is the macos/linux spelling
  # (hadolint's, and the default), `@ros@` is the darwin/linux one,
  # and `@triple@` is the Rust-style quadruple.
  #
  # A caller that does not care should not have to think about it, which is why
  # `@os@` keeps the spelling the first caller used.
  case "$(uname -s)" in
    Darwin)
      os=macos
      ros=darwin
      triple_unknown=apple-darwin
      ;;
    Linux)
      os=linux
      ros=linux
      triple_unknown=unknown-linux-gnu
      ;;
    *)
      printf 'note: no prebuilt %s for %s; install it and re-run\n' "$name" "$(uname -s)" >&2
      return 1
      ;;
  esac
  case "$(uname -m)" in
    arm64 | aarch64)
      arch=arm64
      arch_x64=arm64
      triple_arch=aarch64
      ;;
    x86_64 | amd64)
      # `@rax@` is the short spelling and `@arch@` the long one, because
      # `x64` and `x86_64` are two different SPELLINGS of the same
      # architecture and a release that wants one 404s on the other. A
      # missing sha256 entry and a mismatched asset name read identically,
      # which is why the table is keyed on the exact filename and the
      # template picks the spelling.
      arch=x86_64
      arch_x64=x64
      triple_arch=x86_64
      ;;
    *)
      printf 'note: no prebuilt %s for %s; install it and re-run\n' "$name" "$(uname -m)" >&2
      return 1
      ;;
  esac
  triple="$triple_arch-$triple_unknown"
  asset="${template//@os@/$os}"
  asset="${asset//@ros@/$ros}"
  asset="${asset//@arch@/$arch}"
  asset="${asset//@rax@/$arch_x64}"
  asset="${asset//@triple@/$triple}"

  want="$(printf '%s\n' "$sums" | awk -v a="$asset" '$1 == a { print $2 }')"
  if [ -z "$want" ]; then
    printf 'note: %s has no recorded sha256 for %s; add one to tests/bootstrap.sh\n' \
      "$name" "$asset" >&2
    return 1
  fi

  printf 'note: fetching %s for %s (first run)\n' "$name" "$asset" >&2
  # The install dir is `<root>/tests/.bin`, not `<root>/.venv/bin`.
  #
  # A binary in a gitignored venv is invisible to any caller that bootstraps
  # into a different root, so the tool would be fetched again for every such
  # tree. `tests/.bin` is one location this owns, and `root` says which tree.
  #
  # `.bin` is gitignored (see .gitignore) for the same reason `.venv` is.
  mkdir -p "$dir" "$root/tests/.bin"
  dir="$root/tests/.bin"
  local url="$base/$asset" got scratch
  if ! got="$(curl -fsSL --max-time 180 "$url" | shasum -a 256 | awk '{ print $1 }')" ||
    [ "$got" != "$want" ]; then
    # A checksum mismatch is reported as exactly what it is, and the partial file
    # is removed rather than left for the next run to find.
    rm -f "$dir/$name"
    cat >&2 <<MSG
could not fetch or verify $name from $url.

  expected sha256: $want
  got:             ${got:-<nothing>}

If this machine cannot reach github.com, install it and re-run:

    brew install $name        # macOS
MSG
    return 1
  fi

  if [ -z "$inner" ]; then
    # A bare binary: fetch to a temp name and move, so an interrupted run cannot
    # leave a truncated file that is executable and wrong.
    if ! curl -fsSL --max-time 300 -o "$dir/$name.tmp" "$url"; then
      rm -f "$dir/$name.tmp"
      printf 'note: could not download %s; install it and re-run\n' "$name" >&2
      return 1
    fi
    local again
    again="$(shasum -a 256 < "$dir/$name.tmp" | awk '{ print $1 }')"
    if [ "$again" != "$want" ]; then
      rm -f "$dir/$name.tmp"
      printf 'note: %s failed verification after download; refusing to run it\n' "$name" >&2
      return 1
    fi
    chmod +x "$dir/$name.tmp"
    mv "$dir/$name.tmp" "$dir/$name"
    BIN="$dir/$name"
    return 0
  fi

  # A tarball. Unpacked in a scratch directory rather than in place, because
  # `tar -C .venv/bin` on an archive with a path traversal in it writes outside
  # the directory, and the whole point of verifying this download is that we may
  # trust its contents.
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/kit-${name}.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$scratch'" RETURN

  if ! curl -fsSL --max-time 300 -o "$scratch/$asset" "$url"; then
    printf 'note: could not download %s; install it and re-run\n' "$name" >&2
    return 1
  fi
  # Re-verify the file on disk rather than the stream: an interrupted write
  # that hashes differently from the stream is exactly the case this catches.
  local again
  again="$(shasum -a 256 < "$scratch/$asset" | awk '{ print $1 }')"
  if [ "$again" != "$want" ]; then
    printf 'note: %s failed verification after download; refusing to run it\n' "$name" >&2
    return 1
  fi
  if ! tar -xzf "$scratch/$asset" -C "$scratch" "$inner"; then
    printf 'note: %s archive does not contain %s; refusing to install it\n' "$name" "$inner" >&2
    return 1
  fi
  chmod +x "$scratch/$inner"
  mv "$scratch/$inner" "$dir/$name"
  BIN="$dir/$name"
  return 0
}

# kit_bootstrap_console_script <name> <module> — sets $CONSOLE, or exits 1.
#
# yamllint is required and has the same failure mode PyYAML had, so it gets the
# same treatment. The subtlety is WHERE it has to live.
#
# It cannot simply be `$ROOT/.venv/bin/yamllint`. $PY is not always the
# bootstrap's own interpreter: it is a system python3 that already had PyYAML
# when no venv was needed, or — inside self_test — the interpreter of the tree
# that was invoked, passed in as KIT_PYTHON so sixteen throwaway copies share
# one. In both cases `$ROOT/.venv` does not exist, and looking there yielded
#
#     FAIL yamllint (required, not installed: pip install -r ...)
#
# on a clean clone of the real tree. A required check whose path is hardcoded
# to a directory the resolver may have decided not to create is a gate that
# fails on arrival, which is the exact defect this file was written to remove.
#
# So the script is looked for next to the interpreter we actually chose, then on
# PATH, and only then installed — into that same interpreter, so the two can
# never disagree about which environment the tool lives in.
#
# $CONSOLE is a variable, not an echo, for the same reason $PY is.
# shellcheck disable=SC2034
kit_bootstrap_console_script() {
  local name="$1" module="$2" root="$3"

  local beside
  beside="$(dirname "$PY")/$name"
  if [ -x "$beside" ]; then
    CONSOLE="$beside"
    return 0
  fi
  if command -v "$name" >/dev/null 2>&1; then
    CONSOLE="$(command -v "$name")"
    return 0
  fi

  printf 'note: installing %s into %s (first run)\n' "$name" "$PY" >&2
  if ! "$PY" -m pip install --quiet --disable-pip-version-check "$module" >&2; then
    cat >&2 <<MSG
the gate needs $name, and installing it failed (no network, or no permission
to write to the environment). To do it by hand:

    $PY -m pip install -r $root/tests/requirements.txt

then re-run:

    bash tests/validate.sh
MSG
    return 1
  fi

  if [ -x "$beside" ]; then
    CONSOLE="$beside"
    return 0
  fi
  # A venv on some platforms puts scripts elsewhere; ask the interpreter rather
  # than guessing a path.
  CONSOLE="$("$PY" -c 'import sysconfig, sys; print(sysconfig.get_path("scripts"))' 2>/dev/null)/$name"
  if [ -x "$CONSOLE" ]; then
    return 0
  fi

  cat >&2 <<MSG
pip reported installing $name, but it is still not on PATH and cannot be
imported as $module. The environment is broken rather than the gate. Check:

    $PY -m pip list

then re-run:

    bash tests/validate.sh
MSG
  return 1
}
