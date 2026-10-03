#!/usr/bin/env bash
#
# adapters/go.sh — the SECOND implemented adapter of the cross-tenant harness:
# Go, against `identity`.
#
# SKELETON. Committed early on purpose (a previous attempt at this packet ran
# for 58 minutes and committed nothing). The anchors and the probe are filled
# in by the commits that follow.

# shellcheck disable=SC2209
set -uo pipefail

adapter_language_tool() { printf 'go'; }

adapter_prepare() { return 1; }
adapter_migrate() { return 1; }
adapter_install_probe() { return 1; }
adapter_run() { return 1; }