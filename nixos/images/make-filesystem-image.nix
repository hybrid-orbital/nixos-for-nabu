# Build a filesystem for an existing partition without mounting it or using a VM.
{
  pkgs,
  lib,
  toplevel,
  fsType,
  mountPaths,
  registrationPath,
  extraSizeMiB,
  compress,
  directories ? { },
}:
let
  canonical =
    path:
    path == "/"
    || (
      lib.hasPrefix "/" path
      && lib.all (
        part:
        !(builtins.elem part [
          ""
          "."
          ".."
        ])
      ) (lib.splitString "/" (lib.removePrefix "/" path))
    );
  mounts = lib.sort (a: b: builtins.stringLength a > builtins.stringLength b) (
    builtins.attrNames mountPaths
  );
  covers = mount: path: mount == "/" || path == mount || lib.hasPrefix "${mount}/" path;
  imagePath =
    path:
    let
      mount = lib.findFirst (m: covers m path) (throw "No image mount covers ${path}") mounts;
    in
    lib.concatStringsSep "/" (
      lib.filter (s: s != "") [
        mountPaths.${mount}
        (lib.removePrefix "/" (lib.removePrefix mount path))
      ]
    );
  closure = pkgs.closureInfo { rootPaths = [ toplevel ]; };
  subvolumes = builtins.attrValues mountPaths;
  nixPath = imagePath "/nix";
  manifestPath = imagePath registrationPath;
  fileName = "nabu-rootfs.${fsType}.img";
  buildFilesystem = pkgs.writeShellScript "make-nabu-filesystem" ''
    set -euo pipefail
    chown -R 0:0 "$root"
    sizeMiB=$(( $(du -sm --apparent-size "$root" | cut -f1) + ${toString extraSizeMiB} ))
    truncate -s "''${sizeMiB}M" "$IMG"
    ${
      if fsType == "ext4" then
        ''
          mke2fs -t ext4 -L nixos -d "$root" \
            -E lazy_itable_init=0,lazy_journal_init=0 "$IMG"
          e2fsck -fn "$IMG"
        ''
      else
        ''
          # Use portable 4 KiB sectors regardless of the builder's page size.
          # mkfs creates real subvolumes directly from the staged directories.
          mkfs.btrfs -f -L nixos -s 4096 --rootdir "$root" \
            ${lib.concatMapStringsSep " " (s: "--subvol " + lib.escapeShellArg s) subvolumes} "$IMG"
          btrfs check --readonly "$IMG"
        ''
    }
  '';
in
assert lib.assertMsg (builtins.elem fsType [
  "ext4"
  "btrfs"
]) "Unsupported nabu image filesystem";
assert lib.assertMsg (lib.all canonical (
  mounts ++ [ registrationPath ]
)) "Image paths must be canonical absolute paths";
assert lib.assertMsg (
  !(covers "/nix/store" registrationPath)
) "Keep the registration manifest outside /nix/store";
assert lib.assertMsg (
  if fsType == "ext4" then
    mountPaths == { "/" = ""; }
  else
    lib.all (s: builtins.match "[A-Za-z0-9_@-]+" s != null) subvolumes
    && builtins.length (lib.unique subvolumes) == builtins.length subvolumes
) "Expected an ext4 root or distinct top-level Btrfs subvolumes";
pkgs.runCommand "nabu-rootfs-image"
  {
    nativeBuildInputs = [
      pkgs.zstd
    ]
    ++ (
      if fsType == "ext4" then
        [
          pkgs.e2fsprogs
          pkgs.fakeroot
        ]
      else
        [
          pkgs.btrfs-progs
          pkgs.util-linux
        ]
    );
    passthru = { inherit fileName manifestPath; };
  }
  ''
    set -euo pipefail
    root="$PWD/root"
    export root IMG="$out/${fileName}"
    mkdir -p "$out" "$root"
    ${lib.concatMapStringsSep "\n" (path: ''mkdir -p "$root"/${lib.escapeShellArg path}'') subvolumes}

    nixRoot="$root"/${lib.escapeShellArg nixPath}
    mkdir -p "$nixRoot/store" "$nixRoot/var/nix/profiles"
    ${lib.concatStrings (
      lib.mapAttrsToList (path: mode: ''
        install -d -m ${lib.escapeShellArg mode} "$root"/${lib.escapeShellArg (imagePath path)}
      '') directories
    )}
    while IFS= read -r storePath; do
      cp -a --reflink=auto "$storePath" "$nixRoot/store/"
    done < ${closure}/store-paths
    install -Dm644 ${closure}/registration "$root"/${lib.escapeShellArg manifestPath}
    ln -s ${toplevel} "$nixRoot/var/nix/profiles/system-1-link"
    ln -s system-1-link "$nixRoot/var/nix/profiles/system"

    ${lib.optionalString (fsType == "ext4") ''
      mkdir -p "$root"/{etc,boot,var,tmp,home,root,run,dev,proc,sys}
      ln -s ${toplevel}/init "$root/init"
      touch "$root/etc/NIXOS"
    ''}
    # Btrfs rootdir uses nftw metadata which bypasses fakeroot's stat wrappers.
    # A user namespace makes actual staged ownership appear as root to mkfs.
    ${if fsType == "ext4" then "fakeroot" else "unshare --map-root-user"} ${buildFilesystem}

    ${lib.optionalString compress ''
      zstd -T0 --no-progress "$IMG"
      rm "$IMG"
    ''}
    chmod -R u+w "$root"
    rm -rf "$root"
  ''
