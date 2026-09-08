{ ... }:
{
  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/linux";
    fsType = "ext4";
    # Grow the filesystem to the existing partition; never change the GPT.
    options = [
      "rw"
      "errors=remount-ro"
      "x-systemd.growfs"
    ];
  };
  nabu.image = {
    fsType = "ext4";
    mountPaths."/" = "";
  };
}
