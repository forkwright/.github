# forkwright/.github

Reusable CI workflows for the forkwright fleet. All repos call these instead of
maintaining local copies.

## Caller pattern

Each repo keeps a thin `.github/workflows/<name>.yml` that delegates entirely:

```yaml
# .github/workflows/gate-attestation.yml
name: Gate Attestation
on:
  pull_request:
    branches: [main]
jobs:
  call:
    uses: forkwright/.github/.github/workflows/gate-attestation.yml@main
    # NOTE: pass runner: self-hosted for repos on self-hosted runners
```

```yaml
# .github/workflows/security.yml
name: Security
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  schedule:
    - cron: "23 11 * * *"
  workflow_dispatch:
jobs:
  call:
    uses: forkwright/.github/.github/workflows/security.yml@main
    secrets: inherit
    # NOTE: add `with: { has_private_deps: true }` for repos with private fleet deps
    # NOTE: add `with: { cargo_audit_timeout_minutes: 30 }` for large workspaces
```

```yaml
# .github/workflows/stale.yml
name: Stale
on:
  schedule:
    - cron: "0 12 * * 0"
  workflow_dispatch:
jobs:
  call:
    uses: forkwright/.github/.github/workflows/stale.yml@main
```

```yaml
# .github/workflows/release-please.yml
name: Release Please
on:
  push:
    branches: [main]
  workflow_dispatch: {}
jobs:
  call:
    uses: forkwright/.github/.github/workflows/release-please.yml@main
```

## Workflow inputs

| Workflow | Input | Default | Notes |
|----------|-------|---------|-------|
| gate-attestation | `runner` | `ubuntu-latest` | Use `self-hosted` for private-network repos |
| security | `runner` | `ubuntu-latest` | |
| security | `cargo_audit_timeout_minutes` | `15` | Set `30` for large workspaces |
| security | `has_private_deps` | `false` | `true` configures FLEET_REPO_TOKEN credentials |
| stale | `days_before_issue_stale` | `60` | |
| stale | `days_before_pr_stale` | `30` | |
| stale | `days_before_close` | `14` | |

## Pinned action versions

| Action | Version | SHA |
|--------|---------|-----|
| actions/checkout | v6 | `de0fac2e4500dabe0009e67214ff5f5447ce83dd` |
| actions-rust-lang/setup-rust-toolchain | v1.16.1 | `46268bd060767258de96ed93c1251119784f2ab6` |
| Swatinem/rust-cache | v2 | `e18b497796c12c097a38f9edb9d0641fb99eee32` |
| EmbarkStudios/cargo-deny-action | v2.0.19 | `a531616d8ce3b9177443e48a1159bc945a099823` |
| actions/stale | v10.3.0 | `eb5cf3af3ac0a1aa4c9c45633dd1ae542a27a899` |
| googleapis/release-please-action | v5.0.0 | `45996ed1f6d02564a971a2fa1b5860e934307cf7` |

## Remaining fleet rollout

Repos not yet converted (busy repos excluded from initial proof):

- aletheia, kanon, logismos, akroasis, harmonia, thumos, epistole — convert during each repo's next spotless pass
- hamma, zetesis, gnomon — convert at will (low traffic)

Proof repos already converted: **theatron**, **dioptron**.
