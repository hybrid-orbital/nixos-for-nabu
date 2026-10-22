{
  pkgs,
  lib,
  configuration,
}:
let
  base = configuration.config;
  lab = base.specialisation.sensors-lab.configuration;
  slpi = base.specialisation.sensors-userspace-off.configuration;
  off = base.specialisation.sensors-off.configuration;
  enabled = configuration.extendModules {
    modules = [
      {
        nabu.sensors = {
          enable = true;
          autoStart = true;
          proxy.enable = true;
        };
      }
    ];
  };
  live = enabled.config;
in
assert lib.assertMsg (
  !base.nabu.sensors.enable && !base.nabu.sensors.slpi.enable
) "The default boot must not start experimental SLPI sensors";
assert lib.assertMsg (
  slpi.nabu.sensors.slpi.enable && !slpi.nabu.sensors.enable
) "SLPI-only boot must not register the sensor userspace";
assert lib.assertMsg (
  !off.nabu.sensors.slpi.enable && !off.nabu.sensors.enable
) "Sensor recovery must disable both SLPI and userspace";
assert lib.assertMsg (
  lab.nabu.sensors.enable
  && lab.nabu.sensors.slpi.enable
  && !lab.nabu.sensors.autoStart
  && !lab.nabu.sensors.proxy.enable
) "Sensor lab must require manual file-service startup and omit proxy activation";
assert lib.assertMsg (
  lab.systemd.services.hexagonrpcd.wantedBy == [ ]
  && lab.systemd.services.hexagonrpcd.upholds == [ ]
  && lab.systemd.services.hexagonrpcd.postStart == ""
  && lab.systemd.services.hexagonrpcd.serviceConfig.Restart == "no"
  && !(lab.systemd.services ? iio-sensor-proxy)
) "Sensor lab must not autostart, sample during service startup or retry attachment";
assert lib.assertMsg (
  base.system.build.kernel.drvPath == lab.system.build.kernel.drvPath
  && base.system.build.kernel.drvPath == slpi.system.build.kernel.drvPath
) "Sensor isolation entries must share one kernel build";
assert lib.assertMsg (
  lib.elem "dev-fastrpc\\x2dsdsp.device" live.systemd.services.hexagonrpcd.bindsTo
  && lib.elem "dev-fastrpc\\x2dsdsp.device" live.systemd.services.hexagonrpcd.after
  && lib.elem "iio-sensor-proxy.service" live.systemd.services.hexagonrpcd.wants
  && lib.hasInfix ''ENV{SYSTEMD_WANTS}+="hexagonrpcd.service"'' live.services.udev.extraRules
  && lib.hasInfix ''ENV{ACCEL_MOUNT_MATRIX}="-1,0,0;0,-1,0;0,0,1"'' live.services.udev.extraRules
  && !(lib.hasInfix "SYSTEMD_WANTS" lab.services.udev.extraRules)
) "Automatic sensor recovery must follow SDSP device recreation; lab stays manual";
assert lib.assertMsg (
  lib.elem enabled.pkgs.libssc.drvPath (
    map (p: p.drvPath) live.hardware.sensor.iio.package.buildInputs
  )
  && lib.elem ../pkgs/libssc/0001-log-errors-before-task-transfer.patch enabled.pkgs.libssc.patches
) "The proxy must link to the patched libssc, not just install it alongside";
pkgs.runCommand "nabu-sensors-policy-check" { } ''
  touch "$out"
''
