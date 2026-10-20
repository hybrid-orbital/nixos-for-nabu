#!/usr/bin/env bash
# Publish a writable HexagonFS seed atomically; never replace live calibration.
set -euo pipefail

state=$1
seed=$2

if [ ! -e "$state/hexagonfs" ]; then
  staging=$(mktemp -d "$state/.hexagonfs.XXXXXX")
  trap 'rm -rf -- "$staging"' EXIT
  cp -rL "$seed/." "$staging/"
  chmod -R u+rwX "$staging"
  mv -T "$staging" "$state/hexagonfs"
  trap - EXIT
fi
