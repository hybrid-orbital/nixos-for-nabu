{ pkgs }:
pkgs.runCommand "nabu-fastrpc-alias-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.stdenv.cc
    ];
  }
  ''
    python3 ${../.}/tests/test-fastrpc-alias.py
    touch "$out"
  ''
