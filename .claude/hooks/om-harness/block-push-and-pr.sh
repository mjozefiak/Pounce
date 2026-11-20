#!/usr/bin/env bash
# Compatibility entrypoint. Host permissions remain the publication boundary.
source "$(dirname "$0")/node.sh"
om_harness_run block
