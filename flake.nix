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
        variant: buildSystem: kernelName:
        lib.nixosSystem {
          modules = [
            { nixpkgs.overlays = [ (import ./pkgs) ]; }
            { networking.hostName = hostNameFor variant; }
            ./nixos/configuration.nix
            variants.${variant}
          ]
          ++ lib.optional (variant == "impermanent") impermanence.nixosModules.impermanence
          ++ lib.optional (buildSystem != null) { nixpkgs.buildPlatform.system = buildSystem; }
          # Pinned explicitly by the per-kernel package outputs below; `null`
          # keeps the default from nixos/hardware-nabu.nix.
          ++ lib.optional (kernelName != null) { nabu.kernel.name = kernelName; };
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
          value = mkSystem variant null null;
        }) variants
        // {
          nabu = self.nixosConfigurations.ext4-nabu;
        };

      packages = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
        system:
        let
          # Kernel names come from pkgs/kernel/default.nix; only the attribute
          # names are needed here, so the registry stays unevaluated.
          kernelNames = builtins.attrNames (import ./pkgs/kernel {
            callPackage = nixpkgs.legacyPackages.${system}.callPackage;
          });

          configs = lib.mapAttrs (
            variant: _:
            if system == "aarch64-linux" then
              self.nixosConfigurations."${variant}-nabu".config
            else
              (mkSystem variant system null).config
          ) variants;
          images = lib.concatMapAttrs (variant: config: {
            "${variant}-nabu-esp" = config.system.build.esp-image;
            "${variant}-nabu-rootfs" = config.system.build.rootfs-image;
          }) configs;

          # One kernel output per entry in pkgs/kernel/default.nix, so the CI
          # workflow can build and cache any of them by name.  These are the
          # same derivations the system uses (`boot.kernelPackages.kernel`).
          kernelFor =
            kernelName:
            if system == "aarch64-linux" then
              # Reuse the flake's configuration and only flip the kernel
              # selection, so the default kernel keeps its existing store path.
              (
                self.nixosConfigurations.ext4-nabu.extendModules {
                  modules = [ { nabu.kernel.name = kernelName; } ];
                }
              ).config.system.build.kernel
            else
              (mkSystem "ext4" system kernelName).config.system.build.kernel;
        in
        images
        // {
          # Preserve the original ext4 entry points. Each pair uses one evaluation.
          nabu-esp = images.ext4-nabu-esp;
          nabu-rootfs = images.ext4-nabu-rootfs;
          nabu-kernel = configs.ext4.system.build.kernel;
          default = images.ext4-nabu-esp;
        }
        // lib.listToAttrs (
          map (kernelName: {
            name = "nabu-kernel-${kernelName}";
            value = kernelFor kernelName;
          }) kernelNames
        )
        // lib.optionalAttrs (system == "aarch64-linux") (
          let
            # Compiles only the GPU/DRM part of the mainline-latest kernel
            # against the already built kbuild tree, so iterating on a GPU patch
            # does not cost a full kernel build:
            #   nix build .#nabu-msm-module && ls result
            #   nix build --impure --expr '(builtins.getFlake (toString ./.))
            #     .packages.aarch64-linux.nabu-msm-module.override {
            #       dirs = [ "drivers/gpu/drm/msm" "drivers/gpu/drm/panel" ];
            #     }'
            #
            # This is an *external* module build and does not reproduce the
            # kernel's own msm.ko (docs/kernel-gpu-fault.md, section 12.3), and a
            # boot with it leaves the panel dark, so it is for build-time
            # iteration and for the vm-log instrumentation below - not for
            # judging what a patch does on the device.  A patch that has to
            # reach the device belongs to the kernel package
            # (pkgs/kernel/mainline-latest/patches/).
            msmModule = nixpkgs.legacyPackages.${system}.callPackage
              ./pkgs/kernel/mainline-latest/msm-module.nix
              {
                kernel = kernelFor "mainline-latest";
              };
            # Same module with `debug/vm-log-dmesg.sh` applied, i.e. with the
            # msm.vm_log_dmesg parameter that prints every VM map/unmap op.
            msmModuleDebug = msmModule.override {
              extraShell = builtins.readFile ./pkgs/kernel/mainline-latest/debug/vm-log-dmesg.sh;
            };
          in
          {
            nabu-msm-module = msmModule;
            nabu-msm-module-debug = msmModuleDebug;
            # The kernel's `modules` output with that module swapped in, for
            # `system.modulesTree` (including initrd module aggregation).
            nabu-msm-modules-debug = nixpkgs.legacyPackages.${system}.callPackage
              ./pkgs/kernel/mainline-latest/msm-modules-debug.nix
              {
                kernel = kernelFor "mainline-latest";
                module = msmModuleDebug;
              };
          }
        )
      );
    };
}
