# Exercise the real image builder with a small closure, without tablet hardware.
{ pkgs, lib }:
let
  dependency = pkgs.runCommand "nabu-image-test-dependency" { } ''
    # Large enough to distinguish compressed image sizing from input sizing.
    head -c 268435456 /dev/zero | tr '\0' x > "$out"
  '';
  toplevel = pkgs.runCommand "nabu-image-test-system" { } ''
    mkdir -p "$out"
    ln -s ${dependency} "$out/dependency"
    touch "$out/init"
  '';
  mkImage =
    args:
    import ../nixos/images/make-filesystem-image.nix (
      {
        inherit pkgs lib toplevel;
        extraSizeMiB = 128;
        compress = false;
      }
      // args
    );
  ext4 = mkImage {
    fsType = "ext4";
    mountPaths."/" = "";
    registrationPath = "/custom/state/nix-path-registration";
  };
  btrfs =
    persistentDirectory:
    mkImage {
      fsType = "btrfs";
      mountPaths = {
        "/nix" = "@nix";
        "${persistentDirectory}" = "@persistent";
        "/home" = "@home";
      };
      registrationPath = "${persistentDirectory}/nix-path-registration";
      directories."${persistentDirectory}/var/lib/nixos" = "0755";
      directories."${persistentDirectory}/root" = "0700";
    };
  nested = btrfs "/nix/persistent";
  separate = btrfs "/persist";
in
pkgs.runCommand "nabu-filesystem-image-check"
  {
    nativeBuildInputs = [
      pkgs.btrfs-progs
      pkgs.e2fsprogs
      pkgs.fakeroot
      pkgs.nix
    ];
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" ext4
    debugfs -R "rdump / ext4" ${ext4}/${ext4.fileName}
    test -f ext4/custom/state/nix-path-registration
    test "$(readlink ext4/init)" = ${toplevel}/init
    debugfs -R "stat ${toplevel}" ${ext4}/${ext4.fileName} > ownership
    grep -E 'User: +0 +Group: +0' ownership

    for image in ${nested}/${nested.fileName} ${separate}/${separate.fileName}; do
      mkdir -p restored
      btrfs restore -S "$image" restored
      btrfs inspect-internal dump-tree "$image" > metadata
      grep -m1 'compression 3 (zstd)' metadata
      test "$(stat -c %s "$image")" -lt $(( $(stat -c %s ${dependency}) + 128 * 1024 * 1024 ))
      grep 'mode 40700 .* uid 0 gid 0' metadata
      if grep ' uid ' metadata | grep -v ' uid 0 gid 0 '; then
        echo "The image contains files owned by the builder" >&2
        exit 1
      fi
      btrfs inspect-internal dump-tree -t root "$image" > roots
      for name in @nix @persistent @home; do grep -E "root ref key .* name $name$" roots; done
      test -d restored/@persistent/var/lib/nixos
      test -f restored/@persistent/nix-path-registration
      test ! -e restored/@nix/persistent/nix-path-registration
      test "$(readlink restored/@nix/var/nix/profiles/system-1-link)" = ${toplevel}
      test "$(readlink restored/@nix/var/nix/profiles/system)" = system-1-link
      mkdir dbroot
      mv restored/@nix dbroot/nix
      nix-store --store "$PWD/dbroot" --load-db < restored/@persistent/nix-path-registration
      nix-store --store "$PWD/dbroot" --query --requisites ${toplevel} > registered
      grep -Fx ${dependency} registered
      nix-store --store "$PWD/dbroot" --verify --check-contents
      chmod -R u+w restored dbroot
      rm -rf restored dbroot
    done
    mkdir -p "$out"
    cp registered "$out/registered-paths"
  ''
