#!/usr/bin/env bash
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly PACKAGE_NAME_PATTERN='^[a-z0-9][a-z0-9+.-]*$'
readonly UBUNTU_CODENAME_PATTERN='^[a-z][a-z0-9-]*$'
readonly UBUNTU_KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg
cleanup_dir=''

fail() {
  printf 'ubuntu package installer: %s\n' "$*" >&2
  return 1
}

cleanup() {
  if [[ -n "$cleanup_dir" ]]; then
    rm -rf -- "$cleanup_dir"
  fi
}

parse_packages() {
  local package_input="$1"
  local -n package_names="$2"

  if [[ -z "$package_input" || "$package_input" == *$'\n'* || "$package_input" == *$'\r'* ]]; then
    fail 'packages must be a non-empty, single-line whitespace-separated list'
    return 1
  fi

  package_names=()
  read -r -a package_names <<< "$package_input"
  if [[ "${#package_names[@]}" -eq 0 ]]; then
    fail 'packages must contain at least one package name'
    return 1
  fi

  local package
  for package in "${package_names[@]}"; do
    if [[ ! "$package" =~ $PACKAGE_NAME_PATTERN ]]; then
      fail "invalid Ubuntu package name: $package"
      return 1
    fi
  done
}

read_os_release_value() {
  local field="$1"
  awk -F= -v field="$field" '$1 == field { sub(/^[^=]*=/, ""); print; exit }' /etc/os-release
}

load_ubuntu_release() {
  if [[ ! -r /etc/os-release ]]; then
    fail 'cannot read /etc/os-release'
    return 1
  fi

  local os_id version_codename
  os_id="$(read_os_release_value ID)"
  version_codename="$(read_os_release_value VERSION_CODENAME)"
  os_id="${os_id#\"}"
  os_id="${os_id%\"}"
  version_codename="${version_codename#\"}"
  version_codename="${version_codename%\"}"

  if [[ "$os_id" != ubuntu ]]; then
    fail "unsupported operating system: $os_id"
    return 1
  fi
  if [[ ! "$version_codename" =~ $UBUNTU_CODENAME_PATTERN ]]; then
    fail "unsupported Ubuntu codename: $version_codename"
    return 1
  fi
  if [[ ! -r "$UBUNTU_KEYRING" ]]; then
    fail "missing Ubuntu archive keyring: $UBUNTU_KEYRING"
    return 1
  fi
  if [[ "$(dpkg --print-architecture)" != amd64 ]]; then
    fail 'unsupported architecture: this action supports Ubuntu amd64 runners only'
    return 1
  fi

  ubuntu_codename="$version_codename"
}

write_sources() {
  local sources_file="$1"

  cat > "$sources_file" <<EOF
Types: deb
URIs: https://archive.ubuntu.com/ubuntu
Suites: $ubuntu_codename $ubuntu_codename-updates $ubuntu_codename-backports
Components: main universe restricted multiverse
Signed-By: $UBUNTU_KEYRING

Types: deb
URIs: https://security.ubuntu.com/ubuntu
Suites: $ubuntu_codename-security
Components: main universe restricted multiverse
Signed-By: $UBUNTU_KEYRING
EOF
}

main() {
  if [[ "$#" -ne 1 ]]; then
    fail 'expected one packages argument'
    return 1
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    fail 'must run as root through the composite action'
    return 1
  fi

  local -a packages=()
  parse_packages "$1" packages
  load_ubuntu_release

  local temp_parent temp_dir sources_file sourceparts_dir lists_dir cache_dir archives_dir
  temp_parent="${RUNNER_TEMP:-/tmp}"
  temp_dir="$(mktemp -d "$temp_parent/forkwright-ubuntu-apt.XXXXXXXX")"
  sources_file="$temp_dir/ubuntu.sources"
  sourceparts_dir="$temp_dir/sourceparts"
  lists_dir="$temp_dir/lists"
  cache_dir="$temp_dir/cache"
  archives_dir="$cache_dir/archives"
  cleanup_dir="$temp_dir"
  trap cleanup EXIT

  install -d -m 0755 \
    "$sourceparts_dir" \
    "$lists_dir/partial" \
    "$archives_dir/partial"
  write_sources "$sources_file"

  local -a apt_options=(
    -o "Dir::Etc::sourcelist=$sources_file"
    -o "Dir::Etc::sourceparts=$sourceparts_dir"
    -o "Dir::State::lists=$lists_dir"
    -o "Dir::Cache::archives=$archives_dir"
    -o "Dir::Cache::pkgcache=$cache_dir/pkgcache.bin"
    -o "Dir::Cache::srcpkgcache=$cache_dir/srcpkgcache.bin"
    -o APT::Update::Error-Mode=any
    -o Acquire::Retries=0
    -o Acquire::http::Timeout=120
    -o Acquire::https::Timeout=120
  )

  apt-get "${apt_options[@]}" update
  apt-get "${apt_options[@]}" install --yes --no-install-recommends -- "${packages[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "$#" -eq 2 && "$1" == --validate-package-input ]]; then
    packages=()
    parse_packages "$2" packages
    exit 0
  fi
  main "$@"
fi
