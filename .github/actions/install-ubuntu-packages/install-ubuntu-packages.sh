#!/usr/bin/env bash
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

readonly PACKAGE_NAME_PATTERN='^[a-z0-9][a-z0-9+.-]*$'
readonly UBUNTU_CODENAME_PATTERN='^[a-z][a-z0-9-]*$'
readonly UBUNTU_KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg
cleanup_dir=''

fail() {
  printf 'ubuntu package installer: %s\n' "$*" >&2
  return 1
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$cleanup_dir" ]] && ! rm -rf -- "$cleanup_dir"; then
    printf 'ubuntu package installer: cannot remove owned temporary state: %s\n' "$cleanup_dir" >&2
    if [[ "$status" -eq 0 ]]; then
      status=1
    fi
  fi
  exit "$status"
}

run_apt() {
  local log_file="$1"
  shift

  "$@" 2>&1 | tee "$log_file"
  if grep -Fq 'unsandboxed as root' "$log_file"; then
    fail 'APT downloaded outside its _apt sandbox'
    return 1
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

require_exact_package() {
  local package="$1"
  shift
  local -a package_apt_options=("$@")
  local metadata
  local -a metadata_names=()

  metadata="$(apt-cache "${package_apt_options[@]}" show --no-all-versions -- "$package")"
  mapfile -t metadata_names < <(printf '%s\n' "$metadata" | awk '$1 == "Package:" { print $2 }')
  if [[ "${#metadata_names[@]}" -ne 1 || "${metadata_names[0]}" != "$package" ]]; then
    fail "package must resolve to one exact Ubuntu binary package: $package"
    return 1
  fi
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

  local temp_dir sources_file sourceparts_dir lists_dir cache_dir archives_dir
  # WHY: RUNNER_TEMP can have private ancestors that _apt cannot traverse.
  # Only the fresh child is ours to change; never loosen runner-home permissions.
  temp_dir="$(mktemp -d /tmp/forkwright-ubuntu-apt.XXXXXXXX)"
  sources_file="$temp_dir/ubuntu.sources"
  sourceparts_dir="$temp_dir/sourceparts"
  lists_dir="$temp_dir/lists"
  cache_dir="$temp_dir/cache"
  archives_dir="$cache_dir/archives"
  cleanup_dir="$temp_dir"
  trap cleanup EXIT

  chmod 0755 "$temp_dir"
  install -d -m 0755 \
    "$sourceparts_dir" \
    "$lists_dir" \
    "$archives_dir"
  install -d -o _apt -g root -m 0700 \
    "$lists_dir/partial" \
    "$archives_dir/partial"
  write_sources "$sources_file"

  runuser --user _apt -- /usr/bin/test -r "$sources_file"
  runuser --user _apt -- /usr/bin/test -w "$lists_dir/partial"
  runuser --user _apt -- /usr/bin/test -w "$archives_dir/partial"

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

  run_apt "$temp_dir/update.log" apt-get "${apt_options[@]}" update
  local -a install_specs=()
  local package
  for package in "${packages[@]}"; do
    require_exact_package "$package" "${apt_options[@]}"
    install_specs+=("${package}+")
  done
  run_apt "$temp_dir/install.log" apt-get "${apt_options[@]}" install --yes --no-install-recommends -- "${install_specs[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
