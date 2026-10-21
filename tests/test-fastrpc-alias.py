#!/usr/bin/env python3
"""Compile the actual patch helper with an instrumented fake IOMMU, on the host."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
for kernel in ("sm8150-fork", "mainline-latest"):
    patches = list((root / "pkgs/kernel" / kernel / "patches").glob("*-misc-fastrpc-nabu-sdsp-mappings.patch"))
    assert len(patches) == 1
    added = "\n".join(line[1:] for line in patches[0].read_text().splitlines()
                      if line.startswith(("+", " ")) and not line.startswith("+++"))
    start = added.index("/* The nabu firmware")
    end = added.index("\n}\n", added.index("rollback:", start)) + 3
    with tempfile.TemporaryDirectory(prefix="nabu-alias-test-") as tmp:
        path = Path(tmp)
        (path / "alias-under-test.h").write_text(added[start:end])
        subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
            "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-I" + tmp,
            str(root / "tests/fastrpc-alias-harness.c"), "-o", str(path / "test")
        ], check=True)
        print(kernel, flush=True)
        subprocess.run([str(path / "test")], check=True)
