#!/usr/bin/env bash
set -euo pipefail

installer="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/actions/install-ubuntu-packages/install-ubuntu-packages.sh"

assert_accepts() {
  local package_input="$1"
  bash "$installer" --validate-package-input "$package_input"
}

assert_rejects() {
  local package_input="$1"
  if bash "$installer" --validate-package-input "$package_input" >/dev/null 2>&1; then
    printf 'accepted invalid package input: %q\n' "$package_input" >&2
    return 1
  fi
}

assert_source_contains() {
  local expected="$1"
  if ! grep -Fqx -- "$expected" "$installer"; then
    printf 'installer source does not contain: %s\n' "$expected" >&2
    return 1
  fi
}

assert_accepts 'libamdhip64-dev bubblewrap shellcheck util-linux'
assert_accepts 'shellcheck'
assert_rejects ''
assert_rejects '--allow-unauthenticated'
assert_rejects 'shellcheck; id'
assert_rejects $'shellcheck\nutil-linux'

assert_source_contains "    -o \"Dir::Etc::sourcelist=\$sources_file\""
assert_source_contains "    -o \"Dir::Etc::sourceparts=\$sourceparts_dir\""
assert_source_contains "    -o \"Dir::State::lists=\$lists_dir\""
assert_source_contains "    -o \"Dir::Cache::archives=\$archives_dir\""
assert_source_contains "    -o \"Dir::Cache::pkgcache=\$cache_dir/pkgcache.bin\""
assert_source_contains "    -o \"Dir::Cache::srcpkgcache=\$cache_dir/srcpkgcache.bin\""
assert_source_contains '    -o APT::Update::Error-Mode=any'
assert_source_contains '    -o Acquire::Retries=0'
assert_source_contains '  trap cleanup EXIT'
assert_source_contains "  apt-get \"\${apt_options[@]}\" update"
assert_source_contains "  apt-get \"\${apt_options[@]}\" install --yes --no-install-recommends -- \"\${packages[@]}\""
assert_source_contains 'URIs: https://archive.ubuntu.com/ubuntu'
assert_source_contains 'URIs: https://security.ubuntu.com/ubuntu'
assert_source_contains "Signed-By: \$UBUNTU_KEYRING"

printf 'ubuntu apt installer package parsing tests passed\n'
