# Qualcomm Sensor Core: SLPI file service -> SEE discovery -> D-Bus proxy.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nabu.sensors;
  proxy = config.hardware.sensor.iio.package;
  seed = "${pkgs.xiaomi-nabu-firmware}/share/qcom/sm8150/xiaomi/nabu";
in
{
  imports = [ ./sensors-recovery.nix ];

  options.nabu.sensors.enable = lib.mkEnableOption "nabu SLPI sensors" // {
    default = true;
  };

  config = lib.mkIf cfg.enable {
    # Register the SSC-enabled package directly. The stock IIO module also
    # adds hid-sensor-hub to the initrd, which the fork does not build.
    environment.systemPackages = [
      proxy
      pkgs.libssc
    ];
    services.dbus.packages = [ proxy ];
    services.udev.packages = [ proxy ];
    systemd.packages = [ proxy ];

    # Upstream only tags FastRPC for light/compass by default. nabu also
    # exposes its accelerometer through SSC; leave axis calibration to SEE.
    services.udev.extraRules = ''
      SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-accel"
    '';

    systemd.services.hexagonrpcd = {
      description = "Nabu SLPI sensor file service";
      wantedBy = [ "multi-user.target" ];
      # Upholds starts the proxy after readiness and brings it back after a
      # failed attach/restart. BindsTo below stops stale proxy instances.
      upholds = [ "iio-sensor-proxy.service" ];
      before = [ "iio-sensor-proxy.service" ];
      unitConfig.StartLimitIntervalSec = 0;
      path = [ pkgs.coreutils ];
      preStart = ''
        ${pkgs.bash}/bin/bash ${../scripts/nabu-sensors-seed.sh} \
          "$STATE_DIRECTORY" ${seed}
        test -c /dev/fastrpc-sdsp
      '';
      # Retry discovery without tearing down a healthy FastRPC attachment
      # while the sensor firmware is still initializing its registry.
      postStart = ''
        until ${pkgs.libssc}/bin/ssccli --sensor accelerometer --timeout 1 &&
              ${pkgs.libssc}/bin/ssccli --sensor light --timeout 1; do
          sleep 2
        done
      '';
      serviceConfig = {
        Type = "exec";
        StateDirectory = "nabu-sensors";
        StateDirectoryMode = "0700";
        UMask = "0077";
        ExecStart = "${pkgs.hexagonrpc}/bin/hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R /var/lib/nabu-sensors/hexagonfs";
        # Ordering includes ExecStartPost. No client can start this proxy
        # while SEE still has no accelerometer/light sensor to enumerate.
        TimeoutStartSec = "90s";
        Restart = "always";
        RestartSec = "5s";
      };
    };

    systemd.services.iio-sensor-proxy = {
      bindsTo = [ "hexagonrpcd.service" ];
      after = [ "hexagonrpcd.service" ];
      partOf = [ "hexagonrpcd.service" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
