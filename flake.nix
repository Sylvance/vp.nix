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

      # Prefetch a project's dependencies into a content-addressed pnpm store
      # using nixpkgs' standard `fetchPnpmDeps`, laid out as a ready-to-use
      # Vite+ home directory.
      #
      # The heavy lifting (resolving the lockfile, downloading and normalising
      # the store) is delegated to `fetchPnpmDeps`, so this no longer depends on
      # vp's own install logic. `buildVpProject` points `HOME` at a writable
      # copy of the output and materialises `node_modules` from the store with
      # a plain, offline `pnpm install`.
      #
      # `src` must contain a committed lockfile (`pnpm-lock.yaml`), and `hash`
      # is the output hash of the *pnpm store* printed by Nix the first time you
      # build it (the same hash-mismatch workflow as `fetchPnpmDeps`).
      fetchVpDeps =
        {
          pname,
          pkgs,
          src,
          hash,
          version ? pinnedVersion,
          pnpm ? pkgs.pnpm,
          # nixpkgs' pnpm fetcher version; 4 (SQL-dump store index) is the one
          # supported by pnpm 11+, which is what Vite+ projects use.
          fetcherVersion ? 4,
          nativeBuildInputs ? [ ],
        }:
        let
          pnpmDeps = pkgs.fetchPnpmDeps {
            inherit
              pname
              src
              pnpm
              fetcherVersion
              hash
              ;
            nativeBuildInputs = nativeBuildInputs;
          };

          # pnpm appends its store version directory (e.g. `v11`) below this
          # base. The base is relative to `HOME`, so it stays correct when a
          # consumer copies the home to a different path.
          storeBase =
            if pkgs.stdenv.hostPlatform.isDarwin then "Library/pnpm/store" else ".local/share/pnpm/store";
        in
        pkgs.runCommand "vp-deps-${pname}-${version}"
          {
            # Store paths must be passed as derivation attributes, never
            # interpolated into the builder, or Nix rejects the derivation.
            pnpmDeps = pnpmDeps;
            # Plain strings are fine as environment variables.
            config = systemFirstConfig;
            inherit storeBase;

            nativeBuildInputs = [
              pkgs.sqlite
              pkgs.zstd
            ]
            ++ nativeBuildInputs;
            dontUnpack = true;
          }
          ''
            export HOME="$out"
            mkdir -p "$HOME/.config/vite-plus" "$HOME/$storeBase"
            printf '%s\n' "$config" > "$HOME/.config/vite-plus/config.json"

            # Unpack the reproducible store tarball into pnpm's default store
            # location for this HOME, then rebuild its SQLite index from the
            # text dump the fetcher produced (the binary database is not
            # reproducible across builds).
            tar --zstd -xf "$pnpmDeps/pnpm-store.tar.zst" -C "$HOME/$storeBase"
            chmod -R u+w "$HOME/$storeBase"
            storeDir="$(echo "$HOME/$storeBase"/v*)"
            if [ -f "$storeDir/index.db.sql" ]; then
              sqlite3 "$storeDir/index.db" < "$storeDir/index.db.sql"
              rm -f "$storeDir/index.db.sql"
            fi

            # Keep only the packaged files and the index; pnpm recreates the
            # rest on demand.
            rm -rf "$storeDir"/tmp
            find "$out" -name '*.lock' -delete
          '';

      # Build a Vite+ project hermetically: restore the Vite+ home (and its
      # pnpm store) from `vpDeps`, materialise `node_modules` from that store
      # with an offline `pnpm install`, run the build, and install the result.
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
          # Extra `pnpm install` flags. Lifecycle scripts are always skipped
          # (`--ignore-scripts`); projects that need postinstall steps should
          # add the toolchain they require via `nativeBuildInputs`.
          pnpmInstallFlags ? [ ],
          pnpmWorkspaces ? [ ],
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

              export CI=true
              export VP_NO_UPDATE_CHECK=1
              export VP_GIT_HOOKS=0

              # Materialise `node_modules` from the store captured by
              # `fetchVpDeps`. pnpm's registry supply-chain verification needs
              # network access, so opt out for this offline install (the fetch
              # already performed the check online). `clone-or-copy` keeps the
              # install working on filesystems without hard-link support. The
              # overrides are scoped to the install so the build itself runs
              # with a clean pnpm environment.
              pnpm_config_pm_on_fail=ignore \
              pnpm_config_trust_lockfile=true \
              pnpm_config_package_import_method=clone-or-copy \
              pnpm_config_side_effects_cache=false \
              pnpm_config_update_notifier=false \
              pnpm_config_reporter=append-only \
                pnpm install \
                  --offline \
                  --ignore-scripts \
                  --frozen-lockfile \
                  ${lib.escapeShellArgs (pnpmInstallFlags ++ map (w: "--filter=${w}") pnpmWorkspaces)}

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
