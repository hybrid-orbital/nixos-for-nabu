#!/usr/bin/env python3
"""Exercise the patch's real wait helper with injected completion/freezer events."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
patch = root / "pkgs/kernel/patches/0006-misc-fastrpc-preserve-invoke-across-freezer.patch"
added = "\n".join(line[1:] for line in patch.read_text().splitlines()
                  if line.startswith("+") and not line.startswith("+++"))
start = added.index("static int fastrpc_wait_for_user_completion")
end = added.index("\n}", start) + 2
helper = added[start:end]
with tempfile.TemporaryDirectory(prefix="nabu-freezer-test-") as tmp:
    path = Path(tmp)
    (path / "wait-under-test.h").write_text(helper)
    subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
        "-std=c11", "-Wall", "-Wextra", "-Werror", "-I" + tmp,
        str(root / "tests/fastrpc-freezer-harness.c"), "-o", str(path / "test")
    ], check=True)
    subprocess.run([str(path / "test")], check=True)
