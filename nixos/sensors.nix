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
  sdspDevice = "dev-fastrpc\\x2dsdsp.device";
in
{
  imports = [ ./sensors-recovery.nix ];

  options.nabu.sensors = {
    enable = lib.mkEnableOption "experimental nabu SLPI sensor tools and file service";
    autoStart = lib.mkEnableOption "start the verified sensor file service at boot";
    proxy.enable = lib.mkEnableOption "SSC D-Bus proxy activation after hardware validation";
  };

  config = lib.mkIf cfg.enable {
    # Register the SSC-enabled package directly. The stock IIO module also
    # adds hid-sensor-hub to the initrd, which the fork does not build.
    environment.systemPackages = [
      pkgs.libssc
      pkgs.qrtr
      pkgs.hexagonrpc
    ]
    ++ lib.optional cfg.proxy.enable proxy;
    services.dbus.packages = lib.optional cfg.proxy.enable proxy;
    services.udev.packages = lib.optional cfg.proxy.enable proxy;
    systemd.packages = lib.optional cfg.proxy.enable proxy;

    assertions = [
      {
        assertion = !cfg.proxy.enable || cfg.autoStart;
        message = "nabu.sensors.proxy.enable requires autoStart; first validate manual SSC sampling.";
      }
    ];

    services.udev.extraRules = ''
      SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp", TAG+="systemd"
    ''
    + lib.optionalString cfg.autoStart ''
      ACTION=="add", SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp", ENV{SYSTEMD_WANTS}+="hexagonrpcd.service"
    ''
    + lib.optionalString cfg.proxy.enable ''
      SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-accel", ENV{ACCEL_MOUNT_MATRIX}="-1,0,0;0,-1,0;0,0,1"
    '';

    systemd.services.hexagonrpcd = {
      description = "Nabu SLPI sensor file service";
      wantedBy = lib.optional cfg.autoStart "multi-user.target";
      # SLPI recovery removes and recreates this device. An old open fd
      # cannot serve the new DSP; stop on removal and start on the new add.
      bindsTo = [ sdspDevice ];
      after = [ sdspDevice ];
      wants = lib.optional cfg.proxy.enable "iio-sensor-proxy.service";
      before = lib.optional cfg.proxy.enable "iio-sensor-proxy.service";
      path = [ pkgs.coreutils ];
      preStart = ''
        ${pkgs.bash}/bin/bash ${../scripts/nabu-sensors-seed.sh} \
          "$STATE_DIRECTORY" ${seed}
        test -c /dev/fastrpc-sdsp
      '';
      serviceConfig = {
        Type = "exec";
        StateDirectory = "nabu-sensors";
        StateDirectoryMode = "0700";
        UMask = "0077";
        ExecStart = "${pkgs.hexagonrpc}/bin/hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R /var/lib/nabu-sensors/hexagonfs";
        # Type=exec confirms execve, not PD/SEE readiness. Keep sampling out
        # of this service: --timeout in ssccli starts only after open_sync.
        TimeoutStartSec = "30s";
        TimeoutStopSec = "5s";
        Restart = "no";
      };
    };

    systemd.services.iio-sensor-proxy = lib.mkIf cfg.proxy.enable {
      bindsTo = [ "hexagonrpcd.service" ];
      after = [ "hexagonrpcd.service" ];
      partOf = [ "hexagonrpcd.service" ];
      serviceConfig = {
        # Closing SSC clients can time out against a vanished DSP. Do not
        # hold up the new file service through the firmware's init watchdog.
        TimeoutStopSec = "10s";
        Restart = "no";
      };
    };
  };
}
