{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flakever.url = "github:numinit/flakever";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    zippy.url = "git+https://git.lilithsemi.com/LilithSemi/zippy";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-parts,
      flakever,
      treefmt-nix,
      zippy,
      ...
    }@inputs:
    let
      flakeverConfig = flakever.lib.mkFlakever {
        inherit inputs;

        digits = [
          1
          2
          2
        ];
      };

      # The SD card reports a manufacture date in the MDT field of its CID,
      # and that date is the date this flake was last modified.
      #
      # The fallback is REQUIRED and is not decoration. On a dirty tree the
      # flake has NO lastModified and NO lastModifiedDate at all: the names
      # are absent from the attribute set, so `or` is what answers, not an
      # empty string. On a clean ref lastModifiedDate is the string this
      # slices.
      #
      # SOURCE_DATE_EPOCH is deliberately NOT the source here. nix stdenv
      # sets it to 1980-01-01, so a build that let the generator read it
      # would ship a card that says it was made in 1980. The flag wins over
      # the variable, so passing it explicitly is what keeps the date real.
      lastModifiedDate = inputs.self.lastModifiedDate or "20260909000000";

      # YYYYMMDDHHMMSS to the YYYY-MM the CID field can hold. The MDT field
      # has month granularity, so the rest of the stamp is dropped.
      manufactureDate =
        let
          year = builtins.substring 0 4 lastModifiedDate;
          month = builtins.substring 4 2 lastModifiedDate;
        in
        "${year}-${month}";
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
        inputs.treefmt-nix.flakeModule
      ];

      flake.versionTemplate = "1.1pre-<lastModifiedDate>-<rev>";

      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      perSystem =
        {
          system,
          pkgs,
          final,
          ...
        }:
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [
              self.overlays.default
              inputs.zippy.overlays.default
            ];
          };

          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              dart-format.enable = true;
              nixfmt.enable = true;
              jsonfmt.enable = true;
              zig.enable = true;
            };
          };

          overlayAttrs = {
            # openFPGALoader v1.1.1 breaks dirtyJTag
            # https://github.com/trabucayre/openFPGALoader/issues/727
            openfpgaloader = pkgs.openfpgaloader.overrideAttrs (
              finalAttrs: prev: {
                version = "1.0.0";

                src = pkgs.fetchFromGitHub {
                  owner = "trabucayre";
                  repo = "openFPGALoader";
                  tag = "v${finalAttrs.version}";
                  hash = "sha256-GPYYvsMSzgZCU4qaANaP3nTa6ooJ7pjJDIzW0H4juQM=";
                };
              }
            );

            mimic-ip = pkgs.callPackage ./pkgs/mimic-ip {
              flakever = flakeverConfig;
              inherit manufactureDate;
            };
            mimic-rt = pkgs.callPackage ./pkgs/mimic-rt {
              flakever = flakeverConfig;
              zippy =
                if builtins.hasAttr "zippy" final then
                  final.zippy
                else
                  inputs.zippy.packages.${pkgs.hostPlatform.system}.default;
            };
          };

          packages = {
            inherit (pkgs) mimic-ip mimic-rt;
          };

          devShells = {
            default = pkgs.mimic-ip.shell;
            ip = pkgs.mimic-ip.shell;
            rt = pkgs.mimic-rt.shell;
          };
        };
    };
}
