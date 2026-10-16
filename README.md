# vp.nix

A Nix flake that packages [vp](https://viteplus.dev) — the Vite+ unified
toolchain for the Web (Vite, Rolldown, Vitest, Oxlint, Oxfmt, tsdown, and Vite
Task) — so it can be consumed as a flake input from another `flake.nix`.

Binaries are pinned to an upstream [vite-plus release](https://github.com/voidzero-dev/vite-plus/releases)
and content-addressed with SRI hashes, so builds are reproducible and cached.
Each system is fetched from the matching `@voidzero-dev/vite-plus-cli-*` npm
platform package — the same artifacts the [official installer](https://vite.plus)
uses.

## Supported systems

`x86_64-linux`, `aarch64-linux`, `aarch64-darwin`.

(`x86_64-darwin` is not packaged: nixpkgs dropped support for it in 26.11.)

## Usage

### As a flake input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    vp.url = "github:Sylvance/vp.nix";
  };

  outputs = { self, nixpkgs, vp }: {
    # e.g. a package set that includes vp
    packages.x86_64-linux.default =
      let
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
      in
      pkgs.runCommand "with-vp" { } ''
        mkdir -p $out/bin
        ln -s ${vp.packages.x86_64-linux.vp}/bin/vp $out/bin/vp
      '';
  };
}
```

### Via the overlay

```nix
{
  inputs.vp.url = "github:Sylvance/vp.nix";

  outputs = { nixpkgs, vp, ... }: {
    packages.x86_64-linux.default =
      let
        pkgs = nixpkgs.legacyPackages.x86_64-linux.extend vp.overlays.default;
      in
      pkgs.vp;
  };
}
```

### In a multi-system project (`flake-utils` + `overlays`)

If your project already builds a `pkgs` from an `overlays` list (e.g. a
`flake-utils.lib.eachSystem` monorepo), do **not** vendor a copy of the vp
package expression. Add this flake as an input and put its overlay in the list,
then use `pkgs.vp` everywhere — `packages`, `devShells`, and other overlays.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    vp.url = "github:Sylvance/vp.nix";   # add this
  };

  outputs = { self, flake-utils, nixpkgs, vp, ... }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ] (system:
      let
        overlays = [
          # ...your existing overlays...
          vp.overlays.default            # add this -> exposes pkgs.vp
        ];

        pkgs = import nixpkgs { inherit system overlays; };
      in
      {
        packages = {
          default = pkgs.vp;             # `nix build .#`
          vp = pkgs.vp;                  # `nix build .#vp`
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.nodejs
            pkgs.vp                      # vp on $PATH
          ];
        };
      });
}
```

Because the overlay injects `vp` into `pkgs`, any *other* overlay you load
after it can also reference `prev.vp` directly — for example to bundle the
binary next to an app:

```nix
# nix/overlays/my-app.nix
{ }: final: prev: {
  my-app = prev.stdenv.mkDerivation {
    # ...
    installPhase = ''
      mkdir -p $out/bin
      ln -s ${prev.vp}/bin/vp $out/bin/vp
    '';
  };
}
```

> Note: since `pkgs.vp` is injected via the overlay, the pinned version and
> per-system hashes come from this flake — you don't need to manage any hashes
> in your own repo. To build a different release yourself, use `vp.lib.mkVp`;
> see [Using a different vp version from your flake](#using-a-different-vp-version-from-your-flake).

### NixOS / Home Manager

Use the overlay, then reference `pkgs.vp`:

```nix
{
  nixpkgs.overlays = [ vp.overlays.default ];
  environment.systemPackages = [ pkgs.vp ];
}
```

## Flake outputs

| Output | Description |
| --- | --- |
| `packages.<system>.vp` | The `vp` binary |
| `packages.<system>.default` | Alias for `packages.<system>.vp` |
| `apps.<system>.vp` | `nix run`-able app |
| `overlays.default` | Adds `pkgs.vp` |
| `lib.mkVp` | Build any vp release from your own flake |
| `lib.fetchVpDeps` | Fixed-output derivation capturing a project's pnpm store as a Vite+ home |
| `lib.buildVpProject` | Build a Vite+ project offline from a `fetchVpDeps` result |
| `lib.version` | The pinned Vite+ version |
| `lib.hashes` | The pinned per-system SRI hashes |
| `devShells.<system>.default` | Shell with `vp` on `$PATH` |
| `formatter.<system>` | `nixfmt` for `nix fmt` |

## Local development

```bash
direnv allow          # or: nix develop
nix build .#vp        # build the pinned binary
nix run .#vp          # run it
nix fmt               # format this flake
```

## Runtime notes

The `vp` CLI bootstraps its own managed toolchain (Node.js, pnpm, and project
dependencies) into XDG directories in your home on first use — the global
install under `~/.local/share/vite-plus`, caches under `~/.cache/vite-plus`,
and configuration under `~/.config/vite-plus` — exactly as it does with the
official installer. The Nix package only provides the `vp` binary itself; the
state it manages lives in your home directory, outside the Nix store.

The default package wraps `vp` so Nix's `nodejs` and `pnpm` are on `PATH`
(which keeps vp from downloading its own) and sets `VP_NO_UPDATE_CHECK=1`.
`mkVp` accepts `node`, `pnpm`, and `withRuntime = false` to change that; see
the argument table below.

## Hermetic builds (`nix build`)

`lib.fetchVpDeps` and `lib.buildVpProject` let you build a Vite+ project with
Nix without network access or a writable home:

- **`fetchVpDeps`** resolves the lockfile with nixpkgs' standard
  `fetchPnpmDeps` (fixed-output, so its hash pins the whole dependency
  closure) and lays the resulting pnpm store out as a ready-to-use Vite+ home
  with a `system_first` configuration. It does not run `vp install` and does
  not capture `node_modules`.
- **`buildVpProject`** copies that home into the sandbox and materialises
  `node_modules` from the store with an offline `pnpm install` (workspaces
  included), then runs `vp build` — fully offline.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    vp.url = "github:Sylvance/vp.nix";
  };

  outputs = { nixpkgs, vp, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      deps = vp.lib.fetchVpDeps {
        pname = "my-app";
        inherit pkgs;
        src = ./.;                 # project root, must include pnpm-lock.yaml
        hash = "sha256-...";       # see "Updating the hash" below
      };
    in {
      packages.${system}.default = vp.lib.buildVpProject {
        pname = "my-app";
        inherit pkgs;
        src = ./;
        vpDeps = deps;
      };
    };
}
```

### Updating the hash

`fetchVpDeps` is fixed-output: `hash` is the hash of the **pnpm store**
produced by `fetchPnpmDeps`, not of `node_modules`. Put a placeholder
(`sha256-AAAA…=`), run `nix build`, and copy the `got:` value from the
mismatch error:

```console
$ nix build
error: hash mismatch in fixed-output derivation '/nix/store/…-pnpm-deps-my-app.drv':
    specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
       got:    sha256-EXq2goYjfQed+qt2Gj40krazYTattfPFHc1I6rrghQ0=
```

Update the hash whenever the lockfile or the project's dependencies change.

### Why the install happens at build time

pnpm verifies the lockfile against the npm registry (supply-chain policies:
release age, integrity, tarball bindings) on every invocation. That check
needs network access, so it is performed once, by `fetchPnpmDeps`, while
fetching. `buildVpProject` then runs its install with
`pnpm_config_trust_lockfile=true`, which skips the online re-check and lets a
seeded store install offline. (Without it pnpm fails with
`ERR_PNPM_NO_OFFLINE_META`.)

`buildVpProject` runs the install itself, rather than shipping a captured
`node_modules` tree, so that workspace links are recreated correctly. A copied
root `node_modules` does not include the per-package `node_modules` of
workspace members, which breaks monorepo builds.

### Arguments

`fetchVpDeps { pname, pkgs, src, hash, … }`:

| Argument | Default | Description |
| --- | --- | --- |
| `pname` | *(required)* | Project name; output is named `vp-deps-<pname>-<version>` |
| `pkgs` | *(required)* | Package set to build with |
| `src` | *(required)* | Project source, including the lockfile |
| `hash` | *(required)* | SRI hash of the pnpm store |
| `version` | the pinned Vite+ version | Version suffix for the output name |
| `pnpm` | `pkgs.pnpm` | pnpm used to fetch the store (must be ≥ 11 for `fetcherVersion = 4`) |
| `fetcherVersion` | `4` | nixpkgs `fetchPnpmDeps` fetcher version |
| `nativeBuildInputs` | `[ ]` | Extra inputs for the fetch |

`buildVpProject { pname, pkgs, src, vpDeps, … }`:

| Argument | Default | Description |
| --- | --- | --- |
| `pname` / `pkgs` / `src` | *(required)* | As above |
| `vpDeps` | *(required)* | Result of `fetchVpDeps` for the same `src` |
| `version` | `"0.0.0"` | Output version |
| `vp` / `node` / `pnpm` | as in `fetchVpDeps` | Toolchain used for the build |
| `buildScript` | `"vp build"` | Command run in the project directory |
| `pnpmInstallFlags` | `[ ]` | Extra flags for the offline install |
| `pnpmWorkspaces` | `[ ]` | Workspaces to `--filter` during the install |
| `installPhase` | copies `dist/` into `$out` | Custom install phase |
| `env` / `nativeBuildInputs` | `{ }` / `[ ]` | Extra environment and inputs |

### Caveats

- **Store size.** `fetchPnpmDeps` runs pnpm with `--force` and
  `force_ignores_platform`, so the store contains tarballs for *every*
  platform, not just the one you are building for. Expect the output to be
  considerably larger than a single-platform `node_modules` (multi-gigabyte
  for large monorepos).
- **Lifecycle scripts.** The offline install always passes
  `--ignore-scripts`, skipping dependency build scripts and the project's own
  `prepare` script (`vp migrate` sets `prepare` to `vp config`, which needs
  `git` and installs a git-hook dispatcher; `VP_GIT_HOOKS=0` is already set).
  If a dependency needs a postinstall step, add the toolchain it needs to
  `nativeBuildInputs`, or override the install by supplying your own
  `buildScript`. Note that pnpm 12 refuses `--frozen-lockfile` installs when
  build scripts are present but unapproved (`ERR_PNPM_IGNORED_BUILDS`); pass
  `-- --config.strict-dep-builds=false` or `-- --allow-build=<pkg>` through
  `pnpmInstallFlags` to allow them.
- **Vite+ projects only.** `vp build` refuses a plain Vite project (it
  resolves `vite` to `@voidzero-dev/vite-plus-core`). For non-Vite+ projects
  point `buildScript` at `vpr build` or another command.
- **NixOS.** Node.js binaries downloaded by vp's own runtime manager do not
  execute on NixOS. The `system_first` configuration avoids that path — vp
  uses the Nix-provided `node` and `pnpm` instead.

## Using a different vp version from your flake

The default `packages` / `apps` / `overlays` outputs always expose the version
pinned in this repo's `flake.nix` — you don't edit that file. To pin your own
version, call `vp.lib.mkVp` from your flake with a `version` and the matching
per-system `hash`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    vp.url = "github:Sylvance/vp.nix";
  };

  outputs = { nixpkgs, vp, ... }: {
    packages.aarch64-darwin.default =
      vp.lib.mkVp {
        system = "aarch64-darwin";
        version = "1.1.0";
        # SRI hash of that version's npm platform tarball:
        #   nix store prefetch-file --json \
        #     https://registry.npmjs.org/@voidzero-dev/vite-plus-cli-darwin-arm64/-/vite-plus-cli-darwin-arm64-1.1.0.tgz
        hash = "sha256-KTzDt6Lk7x0RtIN8zKvkgpY3+fXo0PGueW6HMmP1HXc=";
      };
  };
}
```

`mkVp` arguments:

| Argument | Default | Description |
| --- | --- | --- |
| `system` | *(required)* | Nix system to build for (e.g. `x86_64-linux`, `aarch64-darwin`) |
| `version` | the pinned release | Vite+ release to package |
| `hash` | the pinned hash for `system` | SRI hash of the npm platform tarball for that version |
| `pkgs` | `nixpkgs.legacyPackages.${system}` from this flake's input | Package set to build with |
| `node` | `pkgs.nodejs` | Node.js placed on `PATH` by the wrapper |
| `pnpm` | `pkgs.pnpm` | pnpm placed on `PATH` by the wrapper |
| `withRuntime` | `true` | Wrap `node`/`pnpm` onto `PATH`; `false` gives the bare binary |

You can also read the pinned values from your flake: `vp.lib.version` (e.g.
`"1.2.0"`), `vp.lib.hashes`, and `vp.lib.platformSuffix`.

## Updating the pin in this repo

Maintainers of *this* flake bump the default version here:

1. Pick the new tag from the [releases page](https://github.com/voidzero-dev/vite-plus/releases)
   (e.g. `v1.2.0` → version `1.2.0`).
2. Update `pinnedVersion` in `flake.nix`.
3. Refresh the per-system SRI hashes in `pinnedHashes`:

   ```bash
   nix store prefetch-file --json \
     https://registry.npmjs.org/@voidzero-dev/vite-plus-cli-<platform>/-/vite-plus-cli-<platform>-<version>.tgz
   ```

   Platforms are `linux-x64-gnu`, `linux-arm64-gnu`, and `darwin-arm64`
   (the `platformSuffix` map in `flake.nix`).
