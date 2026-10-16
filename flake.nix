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

      # `config.json` placed in a hermetic Vite+ home so `vp` prefers the
      # pinned Node.js and pnpm already on `$PATH` instead of downloading and
      # managing its own copies under the home directory. Without this, the
      # first `vp install` / `vp build` bootstraps Node.js + pnpm from the
      # network into the home directory, which is impossible in a Nix build
      # sandbox.
      systemFirstConfig = builtins.toJSON {
        nodeShimMode = "system_first";
        packageManagerShimModes = {
          bun = "system_first";
          npm = "system_first";
          pnpm = "system_first";
          yarn = "system_first";
        };
      };

      # Build the `vp` derivation for one system. Defaults to the pinned
      # release above; override `version`/`hash` to package a different
      # release from your own flake (see "vp.lib.mkVp" in the README).
      #
      # When `withRuntime` is true (the default) the binary is wrapped so that
      # `node` and `pnpm` from nixpkgs are prepended to `$PATH`. Combined with
      # system-first mode this lets `vp` use the pinned Nix runtimes instead of
      # downloading its own.
      mkVp =
        {
          system,
          pkgs ? nixpkgs.legacyPackages.${system},
          version ? pinnedVersion,
          hash ?
            pinnedHashes.${system} or (throw "vp.lib.mkVp: no pinned hash for system ${system}; pass `hash`"),
          node ? pkgs.nodejs,
          pnpm ? pkgs.pnpm,
          withRuntime ? true,
        }:
        let
          cliPackage = "vite-plus-cli-${
            platformSuffix.${system} or (throw "vp.lib.mkVp: no npm platform suffix for system ${system}")
          }";
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
          nativeBuildInputs =
            lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.autoPatchelfHook ]
            ++ lib.optionals withRuntime [ pkgs.makeWrapper ];
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

          postFixup = lib.optionalString withRuntime ''
            wrapProgram $out/bin/vp \
              --prefix PATH : ${
                lib.makeBinPath [
                  node
                  pnpm
                ]
              } \
              --set VP_NO_UPDATE_CHECK 1
          '';

          passthru = {
            inherit
              node
              pnpm
              withRuntime
              version
              ;
          };

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

      # Prefetch a project's dependencies (and the Vite+ home state) into a
      # fixed-output derivation, so that `nix build` can install and build the
      # project without network access.
      #
      # The output is a ready-to-use Vite+ home directory: point `HOME` at a
      # writable copy of it and `vp install --offline` reconstructs
      # `node_modules` from the store inside it. `buildVpProject` does this for
      # you.
      #
      # `src` must contain a committed lockfile (`pnpm-lock.yaml`), and `hash`
      # is the output hash printed by Nix the first time you build it.
      fetchVpDeps =
        {
          pname,
          pkgs,
          src,
          hash,
          version ? pinnedVersion,
          vp ? self.packages.${pkgs.stdenv.hostPlatform.system}.vp,
          node ? pkgs.nodejs,
          pnpm ? pkgs.pnpm,
          # `--ignore-scripts` skips lifecycle scripts (including the project's
          # dev-only `prepare`/`vp config` hook setup and dependency build
          # scripts, which pnpm does not approve by default). Projects that
          # need postinstall steps can override this and add the build inputs
          # they require via `nativeBuildInputs`.
          installFlags ? [
            "--frozen-lockfile"
            "--ignore-scripts"
          ],
          nativeBuildInputs ? [ ],
        }:
        pkgs.runCommand "vp-deps-${pname}-${version}"
          {
            inherit
              src
              vp
              node
              pnpm
              ;
            # Plain strings (no store-path context) are fine to pass through
            # the environment; store paths themselves must be passed as
            # attributes (above), never interpolated into the builder, or Nix
            # rejects the fixed-output derivation.
            config = systemFirstConfig;
            installFlags = lib.escapeShellArgs installFlags;

            nativeBuildInputs = [
              pkgs.jq
              pkgs.git
            ]
            ++ nativeBuildInputs;

            # Fixed-output derivation: network is allowed while building this,
            # but the result is content-addressed so consumers stay hermetic.
            outputHashMode = "recursive";
            outputHash = hash;

            dontUnpack = true;
          }
          ''
            mkdir -p "$out/.config/vite-plus"
            printf '%s\n' "$config" > "$out/.config/vite-plus/config.json"

            export HOME="$out"
            export CI=true
            export VP_NO_UPDATE_CHECK=1
            # The `prepare` lifecycle script (`vp config`) installs a git hook
            # dispatcher; skip it — hooks are a dev-time concern and would need
            # a git repository in the sandbox.
            export VP_GIT_HOOKS=0
            export PATH="$node/bin:$pnpm/bin:$PATH"

            cp -R "$src/." ./project
            chmod -R u+w ./project
            (
              cd ./project
              "$vp/bin/vp" install $installFlags
            )
            # Ship the installed dependency tree with the store seed.
            # Consumers restore it verbatim: pnpm's supply-chain lockfile
            # verification runs on every `vp install` and needs registry
            # access, so reinstalling offline is not possible today.
            rm -rf "$out/node_modules"
            cp -R ./project/node_modules "$out/node_modules"
            # pnpm records absolute paths (home, store dir) in its
            # `node_modules` bookkeeping. A fixed-output derivation's output
            # must not reference store paths at all — not even its own output
            # path — so scrub any that leaked in.
            rm -f "$out/node_modules/.modules.yaml"
            # Note: `set -o pipefail` is active in the stdenv builder, so a
            # `grep | while` pipeline would abort the build when nothing
            # matches. Iterate over a substitution instead.
            for f in $(grep -rIl -- "$out" "$out/node_modules" 2>/dev/null || true); do
              sed -i.bak "s|$out|/vp-nix-home|g" "$f"
              rm -f "$f.bak"
            done
            rm -rf ./project

            # Keep only the state needed to reinstall offline: the lockfile
            # config, the pnpm store, and any managed runtime/package manager
            # that was pinned by the project. Everything else (caches, logs,
            # shims, update metadata) is either volatile or path-dependent.
            #
            # Fixed-output derivations must not reference store paths at all
            # (not even their own output path), so we must also strip vp's
            # global self-setup state (which records vp's own store path) and
            # the shell shims it writes into `.config/vite-plus` (which embed
            # `$HOME`, i.e. the output path itself).
            find "$out" -mindepth 1 -maxdepth 1 ! -name .config ! -name .local ! -name Library ! -name node_modules -exec rm -rf {} +
            rm -rf "$out/.local/state"
            find "$out/.config/vite-plus" -mindepth 1 ! -name config.json -delete
            if [ -d "$out/.local/share" ]; then
              find "$out/.local/share" -mindepth 1 -maxdepth 1 ! -name pnpm ! -name vite-plus -exec rm -rf {} +
            fi
            if [ -d "$out/.local/share/vite-plus" ]; then
              find "$out/.local/share/vite-plus" -mindepth 1 -maxdepth 1 ! -name package_manager ! -name js_runtime -exec rm -rf {} +
            fi
            if [ -d "$out/Library" ]; then
              find "$out/Library" -mindepth 1 -maxdepth 1 ! -name pnpm ! -name Caches -exec rm -rf {} +
            fi
            # pnpm's registry metadata cache is required by the offline
            # supply-chain lockfile verification that runs during
            # `vp install --offline`. It records only registry-supplied
            # `etag`/`modified` values, so it is deterministic for a given
            # lockfile. The verification result file, however, contains a
            # timestamp and must go.
            if [ -d "$out/Library/Caches" ]; then
              find "$out/Library/Caches" -mindepth 1 -maxdepth 1 ! -name pnpm -exec rm -rf {} +
            fi
            if [ -d "$out/Library/Caches/pnpm" ]; then
              find "$out/Library/Caches/pnpm" -mindepth 1 -maxdepth 1 ! -name 'v*' -exec rm -rf {} +
              for d in "$out"/Library/Caches/pnpm/v*; do
                [ -d "$d" ] && find "$d" -mindepth 1 -maxdepth 1 ! -name metadata ! -name metadata-full -exec rm -rf {} +
              done
              find "$out/Library/Caches/pnpm" -name 'lockfile-verified.jsonl' -delete
            fi
            rm -rf "$out"/Library/pnpm/store/*/projects "$out"/.local/share/pnpm/store/*/projects 2>/dev/null || true
            find "$out" -name '*.lock' -delete
            find "$out" -name 'index_cache.json' -delete

            # pnpm's store index records a per-file `checkedAt` timestamp, which
            # would change the fixed-output hash on every build. Normalise it.
            normalize_index() {
              for f in "$@"; do
                jq -c 'walk(if type == "object" and has("checkedAt") then .checkedAt = 0 else . end)' "$f" > "$f.tmp"
                mv "$f.tmp" "$f"
              done
            }
            normalize_index $(find "$out" -path '*/store/*/index/*.json')
          '';

      # Build a Vite+ project hermetically: seed a writable Vite+ home and
      # dependency tree from `vpDeps`, run `vp build` offline, and install
      # the result. No install step is run here — pnpm's supply-chain
      # lockfile verification requires registry access, so `fetchVpDeps`
      # captures `node_modules` instead.
      buildVpProject =
        {
          pname,
          pkgs,
          src,
          vpDeps,
          version ? "0.0.0",
          vp ? self.packages.${pkgs.stdenv.hostPlatform.system}.vp,
          node ? pkgs.nodejs,
          pnpm ? pkgs.pnpm,
          buildScript ? "vp build",
          installPhase ? ''
            runHook preInstall
            mkdir -p $out
            cp -R dist/. $out/
            runHook postInstall
          '',
          nativeBuildInputs ? [ ],
          env ? { },
        }:
        pkgs.stdenv.mkDerivation (
          env
          // {
            inherit pname version src;

            nativeBuildInputs = nativeBuildInputs ++ [
              vp
              node
              pnpm
            ];

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild

              chmod -R u+w .
              export HOME=$PWD/.vp-home
              cp -R ${vpDeps} $HOME
              chmod -R u+w $HOME
              rm -rf $HOME/node_modules

              export CI=true
              export VP_NO_UPDATE_CHECK=1
              export VP_GIT_HOOKS=0

              cp -R ${vpDeps}/node_modules ./node_modules
              chmod -R u+w ./node_modules
              ${buildScript}

              runHook postBuild
            '';

            inherit installPhase;

            passthru = {
              inherit
                vpDeps
                vp
                node
                pnpm
                ;
            };
          }
        );
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

      # Consumer-facing helpers: inspect the pinned release, package any
      # release from your own flake with `mkVp`, or build a project
      # hermetically with `fetchVpDeps` + `buildVpProject`.
      lib = {
        mkVp = mkVp;
        fetchVpDeps = fetchVpDeps;
        buildVpProject = buildVpProject;
        version = pinnedVersion;
        hashes = pinnedHashes;
        inherit platformSuffix;
      };
    };
}
