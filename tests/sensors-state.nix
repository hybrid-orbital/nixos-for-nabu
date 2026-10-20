{ pkgs }:
pkgs.runCommand "nabu-sensors-state-check" { } ''
  set -euo pipefail
  mkdir -p state seed/sensors/registry seed/socinfo retry
  printf 'factory' > seed/sensors/registry/calibration
  printf '356' > seed/socinfo/soc_id
  ln -s soc_id seed/socinfo/alias
  chmod -R a-w seed

  seedState() {
    ${pkgs.bash}/bin/bash ${../scripts/nabu-sensors-seed.sh} "$1" "$2"
  }
  seedState "$PWD/state" "$PWD/seed"
  test -w state/hexagonfs/sensors/registry/calibration
  test -f state/hexagonfs/socinfo/alias
  test ! -L state/hexagonfs/socinfo/alias

  # A subsequent activation must preserve per-device calibration.
  printf 'device calibration' > state/hexagonfs/sensors/registry/calibration
  seedState "$PWD/state" "$PWD/seed"
  test "$(cat state/hexagonfs/sensors/registry/calibration)" = 'device calibration'

  # A failed initial copy must not publish a partial tree or prevent retry.
  if seedState "$PWD/retry" "$PWD/missing"; then
    echo 'Missing seed unexpectedly succeeded' >&2
    exit 1
  fi
  test ! -e retry/hexagonfs
  test -z "$(ls -A retry)"
  seedState "$PWD/retry" "$PWD/seed"
  test -f retry/hexagonfs/sensors/registry/calibration
  touch "$out"
''
