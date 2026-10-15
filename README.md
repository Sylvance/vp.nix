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
dependencies) into `~/.vite-plus` on first use, exactly as it does with the
official installer. The Nix package only provides the `vp` binary itself; the
state it manages lives in your home directory, outside the Nix store.

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
