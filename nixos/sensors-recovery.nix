# Keep independent boot entries for isolating the unverified sensor path.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  disableSlpi =
    pkgs.buildPackages.runCommand "nabu-disable-slpi.dtbo"
      {
        nativeBuildInputs = [ pkgs.buildPackages.dtc ];
      }
      ''
        dtc -@ -I dts -O dtb -o "$out" ${./dts/nabu-disable-slpi.dts}
      '';
in
{
  options.nabu.sensors.slpi.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Allow the sensor DSP to boot. When disabled, an overlay disables only
      the SLPI device-tree node without rebuilding the selected kernel.
      Disable nabu.sensors.enable as well to stop the sensor userspace.
    '';
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !config.nabu.sensors.enable || config.nabu.sensors.slpi.enable;
          message = "nabu.sensors.enable requires nabu.sensors.slpi.enable; disable both for SLPI recovery.";
        }
      ];

      specialisation = {
        sensors-userspace-off.configuration = {
          nabu.sensors.enable = lib.mkForce false;
          # Hold an ordinary kernel panic for inspection. A hardware or
          # firmware watchdog reset can still reboot the device.
          boot.kernelParams = [ "panic=0" ];
        };
        sensors-off.configuration = {
          nabu.sensors.enable = lib.mkForce false;
          nabu.sensors.slpi.enable = lib.mkForce false;
          boot.kernelParams = [ "panic=0" ];
        };
      };
    }
    (lib.mkIf (!config.nabu.sensors.slpi.enable) {
      hardware.deviceTree.overlays = lib.mkAfter [
        {
          name = "nabu-disable-slpi";
          filter = "*sm8150-xiaomi-nabu.dtb";
          dtboFile = disableSlpi;
        }
      ];
    })
  ];
}
