# Install Ubuntu packages

Install a non-empty whitespace-separated list of exact Ubuntu package names on a
GitHub-hosted Ubuntu amd64 runner.

```yaml
- uses: forkwright/.github/.github/actions/install-ubuntu-packages@<immutable-commit-sha>
  with:
    packages: libamdhip64-dev bubblewrap shellcheck util-linux
```

The action refuses non-Ubuntu or non-amd64 hosts, invalid package names, an
unknown Ubuntu codename, or a missing Ubuntu archive keyring. Rather than
reusing runner source files, it generates a temporary Deb822 source set for the
runner's validated Ubuntu codename and uses that same set, plus fresh temporary
APT lists and caches, for both `update` and `install`. It leaves the runner's
configured sources and caches unchanged.

Consumer workflow references must use an immutable commit SHA. The existing
GitHub Actions Dependabot configuration owns keeping those SHA references
current through its normal review flow.
