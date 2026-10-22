{ pkgs }:
pkgs.runCommand "nabu-libssc-task-errors-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.stdenv.cc
      pkgs.pkg-config
      pkgs.patch
    ];
    buildInputs = [ pkgs.glib ];
  }
  ''
    mkdir src
    cp ${pkgs.libssc.src}/src/libssc-sensor.c src/
    # Verify the regression really detects the old reentrant ownership bug.
    if python3 ${../.}/tests/test-libssc-task-errors.py src/libssc-sensor.c >before.log 2>&1; then
      echo "Expected unpatched libssc to fail the ownership regression" >&2
      exit 1
    fi
    grep -F 'messages == 1' before.log
    patch -p1 -F0 < ${../pkgs/libssc/0001-log-errors-before-task-transfer.patch}
    python3 ${../.}/tests/test-libssc-task-errors.py src/libssc-sensor.c
    touch "$out"
  ''
