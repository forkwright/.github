#!/usr/bin/env bash
set -euo pipefail

installer="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/actions/install-ubuntu-packages/install-ubuntu-packages.sh"

assert_parser_boundary() {
  bash -s -- "$installer" <<'BASH'
set -euo pipefail
source "$1"

packages=()
parse_packages 'libamdhip64-dev bubblewrap shellcheck util-linux' packages
[[ "${packages[*]}" == 'libamdhip64-dev bubblewrap shellcheck util-linux' ]]

for invalid in '' '--allow-unauthenticated' 'shellcheck; id' $'shellcheck\nutil-linux'; do
  packages=()
  if parse_packages "$invalid" packages >/dev/null 2>&1; then
    printf 'accepted invalid package input: %q\n' "$invalid" >&2
    exit 1
  fi
done
BASH
}

run_main_case() {
  local label="$1"
  local update_status="$2"
  local install_status="$3"
  local metadata_name="$4"
  local expected_status="$5"
  local expected_install_calls="$6"
  local sandbox_status="${7:-0}"
  local expected_update_calls="${8:-1}"
  local cleanup_failure="${9:-0}"
  local scratch
  scratch="$(mktemp -d)"

  set +e
  MOCK_UPDATE_STATUS="$update_status" \
  MOCK_INSTALL_STATUS="$install_status" \
  MOCK_METADATA_NAME="$metadata_name" \
  MOCK_SANDBOX_STATUS="$sandbox_status" \
  MOCK_CLEANUP_FAILURE="$cleanup_failure" \
  bash -s -- "$installer" "$scratch" > "$scratch/child-output" 2>&1 <<'BASH'
set -euo pipefail
source "$1"
scratch="$2"
[[ "$LC_ALL" == C ]]

id() {
  printf '0\n'
}

load_ubuntu_release() {
  ubuntu_codename=noble
}

mktemp() {
  local template="${2:?expected a mktemp template}"
  [[ "$template" == /tmp/forkwright-ubuntu-apt.XXXXXXXX ]]
  local directory="$scratch/forkwright-ubuntu-apt.fixture"
  mkdir -p "$directory"
  printf '%s\n' "$directory"
}

install() {
  printf '%s\n' "$@" >> "$scratch/directory-arguments"
  local argument
  for argument in "$@"; do
    if [[ "$argument" == /* ]]; then
      mkdir -p "$argument"
    fi
  done
}

write_sources() {
  : > "$1"
}

runuser() {
  [[ "$1" == --user && "$2" == _apt && "$3" == -- && "$4" == /usr/bin/test ]]
  printf 'preflight\n' >> "$scratch/calls"
  return "${MOCK_SANDBOX_STATUS:?}"
}

rm() {
  if [[ "${MOCK_CLEANUP_FAILURE:?}" -ne 0 ]]; then
    return 1
  fi
  command rm "$@"
}

apt-cache() {
  printf 'Package: %s\n' "${MOCK_METADATA_NAME:?}"
}

apt-get() {
  local -a arguments=("$@")
  local index
  for index in "${!arguments[@]}"; do
    case "${arguments[$index]}" in
      update)
        local expected
        for expected in \
          "Dir::Etc::sourcelist=$scratch/forkwright-ubuntu-apt.fixture/ubuntu.sources" \
          "Dir::Etc::sourceparts=$scratch/forkwright-ubuntu-apt.fixture/sourceparts" \
          "Dir::State::lists=$scratch/forkwright-ubuntu-apt.fixture/lists" \
          "Dir::Cache::archives=$scratch/forkwright-ubuntu-apt.fixture/cache/archives" \
          "Dir::Cache::pkgcache=$scratch/forkwright-ubuntu-apt.fixture/cache/pkgcache.bin" \
          "Dir::Cache::srcpkgcache=$scratch/forkwright-ubuntu-apt.fixture/cache/srcpkgcache.bin" \
          'APT::Update::Error-Mode=any' \
          'Acquire::Retries=0'; do
          if [[ " ${arguments[*]} " != *" $expected "* ]]; then
            printf 'missing isolated APT option: %s\n' "$expected" >&2
            return 1
          fi
        done
        printf '%s\n' "${arguments[@]:0:index}" > "$scratch/update-options"
        printf 'update\n' >> "$scratch/calls"
        return "${MOCK_UPDATE_STATUS:?}"
        ;;
      install)
        printf '%s\n' "${arguments[@]:0:index}" > "$scratch/install-options"
        printf '%s\n' "${arguments[@]:index}" > "$scratch/install-arguments"
        printf 'install\n' >> "$scratch/calls"
        return "${MOCK_INSTALL_STATUS:?}"
        ;;
    esac
  done
  printf 'unexpected apt-get arguments\n' >&2
  return 1
}

main 'libamdhip64-dev'
BASH
  local status=$?
  set -e

  if [[ "$status" -ne "$expected_status" ]]; then
    printf '%s: exit status %s, expected %s\n' "$label" "$status" "$expected_status" >&2
    cat "$scratch/child-output" >&2
    return 1
  fi
  if [[ ! -f "$scratch/calls" ]] \
    || [[ "$(grep -Fc update "$scratch/calls")" -ne "$expected_update_calls" ]] \
    || [[ "$(grep -Fc install "$scratch/calls")" -ne "$expected_install_calls" ]]; then
    printf '%s: unexpected APT call count\n' "$label" >&2
    return 1
  fi
  if [[ "$expected_install_calls" -eq 0 ]] && [[ -f "$scratch/install-options" ]]; then
    printf '%s: install ran after a rejected update or package lookup\n' "$label" >&2
    return 1
  fi
  if [[ "$expected_install_calls" -eq 1 ]]; then
    cmp "$scratch/update-options" "$scratch/install-options"
    grep -Fx 'install' "$scratch/install-arguments" >/dev/null
    grep -Fx 'libamdhip64-dev+' "$scratch/install-arguments" >/dev/null
    grep -Fx -- -o "$scratch/directory-arguments" >/dev/null
    grep -Fx _apt "$scratch/directory-arguments" >/dev/null
    grep -Fx 0700 "$scratch/directory-arguments" >/dev/null
  fi
  if [[ "$cleanup_failure" -eq 0 ]] && compgen -G "$scratch/forkwright-ubuntu-apt.*" >/dev/null; then
    printf '%s: normal exit or failure leaked helper-owned temporary state\n' "$label" >&2
    return 1
  fi
  if [[ "$cleanup_failure" -ne 0 ]]; then
    [[ -d "$scratch/forkwright-ubuntu-apt.fixture" ]]
    grep -F 'cannot remove owned temporary state' "$scratch/child-output" >/dev/null
  fi

  rm -rf -- "$scratch"
}

assert_parser_boundary
run_main_case 'successful install' 0 0 libamdhip64-dev 0 1
run_main_case 'failed update prevents install' 100 0 libamdhip64-dev 100 0
run_main_case 'failed install cleans up' 0 100 libamdhip64-dev 100 1
run_main_case 'regex-only package match prevents install' 0 0 libamdhip64-dev-tools 1 0
run_main_case 'sandbox refusal prevents network' 0 0 libamdhip64-dev 77 0 77 0
run_main_case 'cleanup failure is fatal' 0 0 libamdhip64-dev 1 1 0 1 1
run_main_case 'cleanup failure preserves install failure' 0 100 libamdhip64-dev 100 1 0 1 1

printf 'ubuntu apt installer tests passed\n'
