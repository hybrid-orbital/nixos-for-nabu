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
      # nixosConfigurations key for each storage variant.
      configName = variant: "${variant}-nabu";
      # Host name baked into each system.  `nixos-rebuild switch --flake .`
      # (without an explicit #hostname) resolves the current host name to
      # nixosConfigurations.<host name>, so each variant's host name must be a
      # key or alias that points at its own configuration:
      #   ext4        -> "nabu"              (alias of ext4-nabu, keeps the old name)
      #   impermanent -> "impermanent-nabu"
      # Without this the impermanent system resolved to the ext4 config and
      # rebuilt the wrong root filesystem (ending in emergency mode).
      hostNameFor = variant: if variant == "ext4" then "nabu" else configName variant;
      variants = {
        ext4 = ./nixos/storage/ext4.nix;
        impermanent = ./nixos/storage/impermanent.nix;
      };
      mkSystem =
        variant: buildSystem:
        lib.nixosSystem {
          modules = [
            { nixpkgs.overlays = [ (import ./pkgs) ]; }
            { networking.hostName = hostNameFor variant; }
            ./nixos/configuration.nix
            variants.${variant}
          ]
          ++ lib.optional (variant == "impermanent") impermanence.nixosModules.impermanence
          ++ lib.optional (buildSystem != null) { nixpkgs.buildPlatform.system = buildSystem; };
        };
    in
    {
      checks = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: {
        filesystem-images = import ./tests/filesystem-images.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit lib;
        };
        storage-boot = import ./tests/storage-boot.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit lib impermanence;
        };
      });

      nixosConfigurations =
        lib.mapAttrs' (variant: _: {
          name = configName variant;
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
