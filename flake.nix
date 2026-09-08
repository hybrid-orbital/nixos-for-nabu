{
  description = "NixOS for Xiaomi Pad 5 (nabu)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    impermanence.url = "github:nix-community/impermanence";
    impermanence.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      impermanence,
    }:
    let
      lib = nixpkgs.lib;
      variants = {
        ext4 = ./nixos/storage/ext4.nix;
        impermanent = ./nixos/storage/impermanent.nix;
      };
      mkSystem =
        variant: buildSystem:
        lib.nixosSystem {
          modules = [
            { nixpkgs.overlays = [ (import ./pkgs) ]; }
            ./nixos/configuration.nix
            variants.${variant}
          ]
          ++ lib.optional (variant == "impermanent") impermanence.nixosModules.impermanence
          ++ lib.optional (buildSystem != null) { nixpkgs.buildPlatform.system = buildSystem; };
        };
    in
    {
      nixosConfigurations =
        lib.mapAttrs' (variant: _: {
          name = "${variant}-nabu";
          value = mkSystem variant null;
        }) variants
        // {
          nabu = self.nixosConfigurations.ext4-nabu;
        };

      packages = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
        system:
        let
          configs = lib.mapAttrs (
            variant: _:
            if system == "aarch64-linux" then
              self.nixosConfigurations."${variant}-nabu".config
            else
              (mkSystem variant system).config
          ) variants;
          images = lib.concatMapAttrs (variant: config: {
            "${variant}-nabu-esp" = config.system.build.esp-image;
            "${variant}-nabu-rootfs" = config.system.build.rootfs-image;
          }) configs;
        in
        images
        // {
          # Preserve the original ext4 entry points. Each pair uses one evaluation.
          nabu-esp = images.ext4-nabu-esp;
          nabu-rootfs = images.ext4-nabu-rootfs;
          nabu-kernel = configs.ext4.system.build.kernel;
          default = images.ext4-nabu-esp;
        }
      );
    };
}
