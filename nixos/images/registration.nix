{ config, lib, ... }:
let
  manifest = config.nabu.image.registrationPath;
in
{
  # Keep initialization independent of the filesystem/image builder. The
  # manifest is installed into the image, not referenced by the system closure.
  systemd.services.register-nix-paths = {
    description = "Register Nix Store Paths";
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = manifest;
      RequiresMountsFor = [
        (builtins.dirOf manifest)
        "/nix/var/nix"
      ];
    };
    wantedBy = [ "sysinit.target" ];
    before = [
      "sysinit.target"
      "shutdown.target"
      "nix-daemon.socket"
      "nix-daemon.service"
    ];
    after = [ "local-fs.target" ];
    conflicts = [ "shutdown.target" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${lib.getExe' config.nix.package.out "nix-store"} --load-db < ${lib.escapeShellArg manifest}
      ${lib.getExe' config.nix.package.out "nix-env"} \
        -p /nix/var/nix/profiles/system --set /run/current-system
      # Only remove the manifest after both operations succeed; retry on failure.
      rm -f -- ${lib.escapeShellArg manifest}
    '';
  };
}
