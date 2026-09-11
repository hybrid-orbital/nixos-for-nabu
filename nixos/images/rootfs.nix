{
  config,
  lib,
  pkgs,
  ...
}:
{
  system.build.rootfs-image = pkgs.callPackage ./make-filesystem-image.nix {
    pkgs = pkgs.buildPackages;
    toplevel = config.system.build.toplevel;
    inherit (config.nabu.image)
      fsType
      mountPaths
      registrationPath
      compress
      ;
    extraSizeMiB = config.nabu.image.rootFsExtraSize;
    # Seed bind-mount sources for the first boot, before activation can run.
    directories = lib.listToAttrs (
      lib.concatMap (
        p:
        lib.optionals p.enable (
          map (d: {
            name = "${d.persistentStoragePath}${d.dirPath}";
            value = d.mode;
          }) (p.directories ++ map (f: f.parentDirectory) p.files)
        )
      ) (builtins.attrValues (config.environment.persistence or { }))
    );
  };
}
