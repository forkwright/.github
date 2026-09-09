#!/usr/bin/env bash
# Lock the two system-package paths in hybrid-gate.yml: existing callers keep
# their runner APT commands while opted-in callers use the pinned isolated
# Ubuntu installer. actionlint validates YAML, but does not establish that
# these complementary conditions or the action pin remain paired.
set -euo pipefail

workflow="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/workflows/hybrid-gate.yml"

python3 - "$workflow" <<'PY'
from pathlib import Path
import sys

workflow = Path(sys.argv[1]).read_text()


def section(start: str, end: str) -> str:
    try:
        return workflow.split(start, 1)[1].split(end, 1)[0]
    except IndexError as error:
        raise SystemExit(f"missing workflow contract section: {start!r}") from error


input_spec = section("      system_packages_ubuntu_only:\n", "      fmt_cmd:\n")
for expected in (
    "type: boolean",
    "required: false",
    "default: false",
):
    if expected not in input_spec:
        raise SystemExit(f"system_packages_ubuntu_only missing {expected!r}")

default_step = section(
    "      - name: Install system dependencies\n",
    "      - name: Install Ubuntu-only system dependencies\n",
)
if "if: inputs.system_packages != '' && !inputs.system_packages_ubuntu_only" not in default_step:
    raise SystemExit("default system-package step is not limited to non-opted-in callers")
expected_default_body = """run: |
          sudo apt-get update
          sudo apt-get install --yes --no-install-recommends ${{ inputs.system_packages }}"""
if expected_default_body not in default_step:
    raise SystemExit("default system-package install body changed")

opt_in_step = section(
    "      - name: Install Ubuntu-only system dependencies\n",
    "      - name: Configure git credentials for fleet deps\n",
)
for expected in (
    "if: inputs.system_packages != '' && inputs.system_packages_ubuntu_only",
    "uses: forkwright/.github/.github/actions/install-ubuntu-packages@637f0e9d1b795e455d1dea96824ad7322002019f",
    "packages: ${{ inputs.system_packages }}",
):
    if expected not in opt_in_step:
        raise SystemExit(f"Ubuntu-only system-package step missing {expected!r}")
PY
