#!/usr/bin/env bash

kit_activate_mise() {
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


KIT_HADOLINT_VERSION='2.15.1'
KIT_HADOLINT_SHA256S='hadolint-macos-arm64 5c09f3213f8e40406abe048233d985eebef336d4a6a20021be47fadb6cf480a2
hadolint-macos-x86_64 ffe9bb18b23d5ed1eae50237aecdbb523d016e96da0bd4e7aa432040acfc3fde
hadolint-linux-arm64 f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d
hadolint-linux-x86_64 c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507'

PATH_SWEEP_DIRS=""

kit_bootstrap_binary() {
  local name="$1" base="$2" sums="$3" root="${4:-.}"
  local template="${5:-$name-@os@-@arch@}" inner="${6:-}"
  local dir="$root/tests/.bin"

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
  mkdir -p "$dir" "$root/tests/.bin"
  dir="$root/tests/.bin"
  local url="$base/$asset" got scratch
  if ! got="$(curl -fsSL --max-time 180 "$url" | shasum -a 256 | awk '{ print $1 }')" ||
    [ "$got" != "$want" ]; then
    rm -f "$dir/$name"
    cat >&2 <<MSG
could not fetch or verify $name from $url.

  expected sha256: $want
  got:             ${got:-<nothing>}

If this machine cannot reach github.com, install it and re-run:

MSG
    return 1
  fi

  if [ -z "$inner" ]; then
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

  scratch="$(mktemp -d "${TMPDIR:-/tmp}/kit-${name}.XXXXXX")"
  trap "rm -rf '$scratch'" RETURN

  if ! curl -fsSL --max-time 300 -o "$scratch/$asset" "$url"; then
    printf 'note: could not download %s; install it and re-run\n' "$name" >&2
    return 1
  fi
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
