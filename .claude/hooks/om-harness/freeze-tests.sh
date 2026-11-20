#!/usr/bin/env bash
# Compatibility entrypoint. Node is found through node.sh (hooks run in a non-interactive shell).
source "$(dirname "$0")/node.sh"
om_harness_run freeze
