#!/usr/bin/env python3
"""Compile the actual kernel SSR helper and exercise inbound edge history."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
match = re.search(r"static bool qcom_smp2p_check_ssr\([^\n]+\)\n\{.*?^\}",
                  source, re.M | re.S)
assert match, "SSR helper missing"
with tempfile.TemporaryDirectory(prefix="nabu-smp2p-test-") as tmp:
    path = Path(tmp)
    (path / "ssr-under-test.h").write_text(match.group())
    subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
        "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-I" + tmp,
        str(Path(__file__).with_name("smp2p-ssr-harness.c")),
        "-o", str(path / "test")
    ], check=True)
    subprocess.run([str(path / "test")], check=True, timeout=10)
