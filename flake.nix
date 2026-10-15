{
  description = "vp (Vite+) — the unified toolchain for the Web, packaged as a consumable Nix flake.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      # Bump this together with `pinnedHashes` when releasing a new pinned
      # version; see "Updating the pinned version" in the README.
      pinnedVersion = "1.2.0";

      # SRI hash of the npm platform tarball for `pinnedVersion`, per Nix
      # system. Each platform package ships a single `vp` binary — the same
      # artifact the official installer uses.
      # https://www.npmjs.com/package/@voidzero-dev/vite-plus-cli-darwin-arm64
      # (and its -linux-x64-gnu, -linux-arm64-gnu siblings; -darwin-x64 is
      # omitted because nixpkgs dropped x86_64-darwin support in 26.11)
      pinnedHashes = {
        x86_64-linux = "sha256-fBNrR5AhfC2IF3wg0d1ogv/fQFeosdxTTsQYmJbhljM=";
        aarch64-linux = "sha256-C382AUYi3aTm4pGGKurdPgGjmcKefL5Sd1cizNaD8B8=";
        aarch64-darwin = "sha256-jv+4PTVSnZBPFJkX24dNlUf7FH6GyDkgM07DP4cTko4=";
      };

      # npm platform-package suffix for each supported Nix system.
      platformSuffix = {
        x86_64-linux = "linux-x64-gnu";
        aarch64-linux = "linux-arm64-gnu";
        aarch64-darwin = "darwin-arm64";
      };

      systems = builtins.attrNames pinnedHashes;

      # Build the `vp` derivation for one system. Defaults to the pinned
      # release above; override `version`/`hash` to package a different
      # release from your own flake (see "vp.lib.mkVp" in the README).
      mkVp =
        {
          system,
          pkgs ? nixpkgs.legacyPackages.${system},
          version ? pinnedVersion,
          hash ? pinnedHashes.${system} or (throw "vp.lib.mkVp: no pinned hash for system ${system}; pass `hash`"),
        }:
        let
          cliPackage =
            "vite-plus-cli-${platformSuffix.${system} or (throw "vp.lib.mkVp: no npm platform suffix for system ${system}")}";
        in
        pkgs.stdenv.mkDerivation {
          pname = "vp";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/@voidzero-dev/${cliPackage}/-/${cliPackage}-${version}.tgz";
            inherit hash;
          };

          # The Linux builds are dynamically linked against glibc and need their
          # interpreter/rpath rewritten for the Nix store. macOS links only
          # against system frameworks, so nothing to do there.
          nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.autoPatchelfHook
          ];
          buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.stdenv.cc.cc.lib
          ];

          # Let the standard unpackPhase unpack the tarball; it contains a single
          # `package/` directory, which becomes the build root.
          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            cp vp "$out/bin/vp"
            chmod +x "$out/bin/vp"
            runHook postInstall
          '';

          meta = {
            description = "Unified toolchain for the Web (Vite, Rolldown, Vitest, Oxlint, and more)";
            homepage = "https://viteplus.dev";
            changelog = "https://github.com/voidzero-dev/vite-plus/releases/tag/v${version}";
            license = lib.licenses.mit;
            mainProgram = "vp";
            platforms = lib.unique (systems ++ [ system ]);
          };
        };

      vpPackages = lib.genAttrs systems (system: mkVp { inherit system; });
    in
    {
      # `vp.packages.${system}.vp` is the primary entry point when this
      # repo is consumed as a flake input.
      packages = lib.genAttrs systems (system: {
        vp = vpPackages.${system};
        default = vpPackages.${system};
      });

      # Optional convenience: `nix run .#vp` / `nix run .#`.
      apps = lib.genAttrs systems (system: {
        vp = {
          type = "app";
          program = "${vpPackages.${system}}/bin/vp";
          meta.description = "Run the vp (Vite+) CLI";
        };
        default = {
          type = "app";
          program = "${vpPackages.${system}}/bin/vp";
          meta.description = "Run the vp (Vite+) CLI";
        };
      });

      # Drop-in overlay for users who prefer `pkgs.vp`.
      overlays.default = final: _prev: {
        vp = self.packages.${final.stdenv.hostPlatform.system}.vp;
      };

      devShells = lib.genAttrs systems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = [ vpPackages.${system} ];
        };
      });

      formatter = lib.genAttrs systems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      # Consumer-facing helpers: inspect the pinned release, or build any
      # release from your own flake with `mkVp`.
      lib = {
        mkVp = mkVp;
        version = pinnedVersion;
        hashes = pinnedHashes;
        inherit platformSuffix;
      };
    };
}
