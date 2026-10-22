#!/usr/bin/env python3
"""Extract and run open/close callbacks from the supplied libssc source file."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
callbacks = []
for operation in ("open", "close"):
    match = re.search(r"static void\nsensor_" + operation + r"_ready \([^\n]+\)\n\{.*?^\}",
                      source, re.M | re.S)
    assert match, operation
    callbacks.append(match.group())
flags = subprocess.check_output(
    [os.environ.get("PKG_CONFIG", "pkg-config"), "--cflags", "--libs", "gio-2.0"], text=True
)
with tempfile.TemporaryDirectory(prefix="libssc-errors-") as tmp:
    path = Path(tmp)
    (path / "callbacks-under-test.h").write_text("\n".join(callbacks))
    subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
        "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-I" + tmp,
        str(Path(__file__).with_name("libssc-task-errors.c")), "-o", str(path / "test"),
    ] + shlex.split(flags), check=True)
    subprocess.run([str(path / "test")], check=True, timeout=10)
