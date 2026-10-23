{ pkgs }:
pkgs.runCommand "nabu-smp2p-ssr-check"
  { nativeBuildInputs = [ pkgs.python3 pkgs.stdenv.cc pkgs.patch pkgs.xz ]; }
  ''
    tar -xf ${pkgs.linux_latest.src} --strip-components=1 --wildcards '*/drivers/soc/qcom/smp2p.c'
    chmod -R u+w drivers
    if python3 ${../.}/tests/test-smp2p-ssr.py drivers/soc/qcom/smp2p.c >before.log 2>&1; then
      echo "Expected the pinned unpatched kernel to lose inbound edge history" >&2
      exit 1
    fi
    grep -F 'slpi.last_value == 6' before.log
    patch -p1 -F0 < ${../pkgs/kernel/mainline-latest/patches/0013-soc-qcom-smp2p-reset-state-only-on-ssr.patch}
    python3 ${../.}/tests/test-smp2p-ssr.py drivers/soc/qcom/smp2p.c
    touch "$out"
  ''
