{ pkgs }:
pkgs.runCommand "nabu-fastrpc-freezer-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.stdenv.cc
    ];
  }
  ''
    python3 ${../.}/tests/test-fastrpc-freezer.py
    touch "$out"
  ''
