# estpkgs

EastonMan's own Nix packages: the things [nixpkgs](https://github.com/NixOS/nixpkgs)
does not carry. Not a fork, not a collection of other people's patches.

Packages only, deliberately: no NixOS or Home Manager modules are exported here.
Anything that encodes host state stays with the configuration that owns it.

Current contents are linux-only (`rybbit`): building it takes ~7 minutes cold
and produces a 2.7 GiB closure, most of it Chromium, so a Darwin machine needs a
Linux builder before `nix build` is interesting.

## Packages

| Package | Version | Upstream | Platforms |
| ------- | ------- | -------- | --------- |
| `rybbit` | `2.9.3` | [rybbit-io/rybbit](https://github.com/rybbit-io/rybbit) | linux |

`packages.<system>` lists only what can build on that system (`meta.platforms`
filter); `overlays.default` is unfiltered, because a consumer's own nixpkgs is
the judge of what it can build there.

## Use

```nix
{
  inputs.estpkgs = {
    url = "github:eastonman/estpkgs";
    inputs.nixpkgs.follows = "nixpkgs"; # otherwise you carry a second nixpkgs
  };
}
```

```nix
nixpkgs.overlays = [ inputs.estpkgs.overlays.default ];
# or: inputs.estpkgs.packages.${pkgs.stdenv.hostPlatform.system}.rybbit
```

The overlay is a pure `final: prev:` -- no pinned nixpkgs, no extra arguments.

Following your own nixpkgs also makes *your* tree the one that has to agree with
the two `npmDepsHash` constants in the recipes. If a build stops on a hash
mismatch, that is what happened: re-pin estpkgs (or refresh its hash) rather than
assuming the package is broken.

## Layout and conventions

```text
pkgs/<two letters>/<name>/package.nix    # one directory per package
pkgs/<two letters>/<name>.nix            # allowed, for a single self-contained file
```

Discovery is `lib.filesystem.listFilesRecursive ./pkgs`, restricted to those two
shapes: adding a package means adding a directory, never editing an index, and a
helper file next to a package is not mistaken for one. Two files reducing to the
same attribute name abort evaluation. The layout matches nixpkgs' `pkgs/by-name`,
so moving a package upstream is a `git mv` plus an owner review.

A package may only take nixpkgs-provided arguments -- `rybbit`'s `backendUrl` is
the one documented exception, because a public origin is deployment data that no
nixpkgs tree can supply. And because the overlay is unfiltered, a package named
after an attribute nixpkgs already has would shadow it in the consumer's
fixpoint; nothing here collides today, but check before adding one.

## Why the flake pins nixos-26.05

`npmDepsHash` is a constant in the recipe, so the tree that computes it has to be
the tree that consumes it: a hash verified only on unstable fails at deploy time,
on 26.05, with nothing having changed here. The hashes below were computed
against a different nixpkgs (74k1/tixpkgs, unstable) and still match 26.05 --
`npmDepsFetcherVersion` is 1 on both branches. That is luck, not a guarantee.

## rybbit

Built from source rather than from the project's container images, with a patch
that unlocks the parts of the UI upstream reserves for its cloud product.

| Property | Value |
| -------- | ----- |
| Pinned upstream | `v2.9.3` (`908041772bc6cad14916d182e5bd0c8f0b9cbb32`) |
| Patch | `pkgs/ry/rybbit/decloud.patch`, 3 files, +8/-5, applied with `-p2` from `source/client` |
| Unlocked | sidebar **Pages** and **Performance**, plus the **Web Vitals** toggle that feeds the performance page |
| Still locked | Bots, Google Search Console, Query/SQL, custom dashboards, and every billing path -- those stay behind `IS_CLOUD` |
| Binaries | `rybbit-server`, `rybbit-server-cluster`, `rybbit-client`, `rybbit-migrate` |

Upstream gates cloud-only UI on `IS_CLOUD`, a build-time constant read from
`NEXT_PUBLIC_CLOUD`. Setting that env var would unlock the whole cloud surface,
billing code included; the patch instead adds `IS_UNLOCKED = true` and moves
exactly three gates onto it. That is sufficient for the two tabs: their
`DisabledOverlay` is a no-op when `!IS_CLOUD`, the Web Vitals toggle's `disabled`
state ends in `&& IS_CLOUD`, and the server registers page, performance,
tracking-config and ingestion routes without a cloud guard. It does not backfill:
turning Web Vitals on only affects new events.

## Verified

| Property | Value |
| -------- | ----- |
| Command | `nix build .#packages.x86_64-linux.rybbit` (the shipped default, `backendUrl = ""`) |
| Date | 2026-11-26 |
| Build host | remote x86_64-linux builder, 3 vCPU / 8 GiB |
| Wall time | ~7 min from cold npm caches; rebuilds reuse both npm-deps derivations |
| Closure | 2.7 GiB -- `share/rybbit-client` 114 MB, `share/rybbit-server` 502 MB, the rest Chromium, Node, zstd and friends |
| Hashes | `src` and both `npmDepsHash` matched |
| Patch | applied cleanly; `next build` passed; app routes stay dynamic (`ƒ`), `/_global-error` and `/icon.svg` are prerendered (`○`) |

A second build with `backendUrl = "https://analytics.example.com"` also succeeds;
that run is what showed the SSR `ERR_INVALID_URL` below disappearing once the URL
is absolute.

`aarch64-linux` is in `systems`, so `checks.aarch64-linux` exists, but nothing
has built it. Nothing at all is verified on a running instance: the two tabs, the
performance data and the PDF export are deployment-time checks.

## What a deployment must do

1. **Build the client with the public origin**:
   `pkgs.rybbit.override { backendUrl = "https://analytics.example.com"; }`.
   `NEXT_PUBLIC_BACKEND_URL` is baked in at build time; the default `""` means
   "same origin", which is right in a browser but meaningless in Node, so
   server-rendered pages throw `ERR_INVALID_URL` for `/api/auth/get-session`
   (`client/src/lib/userStore.ts:17` calls `authClient.getSession()` at module
   scope). With a non-empty value the client build fetches that origin during
   static generation, so the build touches the network.
2. **Run the migrations first.** The server does not create its PostgreSQL schema
   at boot (upstream runs this from `docker-entrypoint.sh`), so an empty database
   yields a service that looks healthy and is not. `rybbit-migrate` exists for
   this: run it as an `ExecStartPre` or an ordered oneshot, with the same
   PostgreSQL environment and `WorkingDirectory` as the server.
3. **Provide the environment**: `POSTGRES_{HOST,PORT,DB,USER,PASSWORD}` (only
   host and port have defaults), `CLICKHOUSE_{HOST,DB,PASSWORD}` (host is an HTTP
   URL), `REDIS_{HOST,PORT,PASSWORD}`, a stable `BETTER_AUTH_SECRET`, `BASE_URL`,
   and `DISABLE_SIGNUP=true` once the first account exists. Signup is *not*
   build-time: the client never reads `NEXT_PUBLIC_DISABLE_SIGNUP` (dead config
   in 2.9.3, not passed here); the UI reads `configs.disableSignup` from
   `/api/config` and the server enforces it.
4. **Give it a writable HOME / cache / tmp** for Chromium's profiles and Next's
   image cache, and test PDF export under whatever systemd hardening the unit
   uses: upstream's `--no-sandbox --disable-dev-shm-usage` avoids the Chromium
   sandbox, not the service's filesystem restrictions.
5. **Proxy `/api/*` and the OAuth discovery paths to the server, everything else
   to the client.** The backend binds `0.0.0.0` with `trustProxy`, so firewall
   it; the client wrapper defaults `HOSTNAME=127.0.0.1`.

Acceptance on the instance: the sidebar shows Pages and Performance,
`/sites/<id>/performance` serves data once a site has Web Vitals on, and
`Export as PDF Report` produces a file.

## Known limitations

- **Next's image cache writes under `.next/cache/images` in the read-only
  store.** Next serves the image anyway, but logs a cache-write failure and
  cannot keep optimized images across restarts.
- **The bundled MaxMind databases are as old as the pinned tag.** Upstream
  vendors them in-tree; they do not refresh with the package.
- **Chromium is most of the closure.** The PDF export button is visible on a
  self-hosted install (`canExportPdf` is false only for a paid-cloud
  free/AppSumo plan), so removing Chromium would ship a button that 500s.

## Not here yet

- **Binary cache.** No substituter is configured. When one exists, its
  substituter and public key go into this flake's `nixConfig` *and* into the
  consumers' `nix.settings`: an input's `nixConfig` is honoured only with
  `accept-flake-config`, so the flake alone is not enough.
- **CI.** `checks` mirrors `packages`, so `nix flake check` on x86_64-linux
  builds the package and on Darwin has nothing to build -- and says which systems
  it omitted instead of passing silently. `--all-systems` cannot help from a
  Darwin host. Until a Linux runner exists, the gate is `nix build` against a
  remote builder. Without CI, a pull request that changes `src`
  (`owner`/`repo`/`rev`) and its hash together is internally consistent and will
  build fine, so review such diffs against upstream.

## Licence

Packaging and the flake are MIT (see `LICENSE`); a patch against a copyleft
program is a derivative of that program and carries its licence, not MIT.

`rybbit` is AGPL-3.0, and what this repository builds is a **modified** version:
the modifications are listed in `pkgs/ry/rybbit/NOTICE`, which is installed with
the artifact. The corresponding source is the pinned upstream tag plus this
repository. Not affiliated with rybbit-io; no upstream support implied.

Bundled third-party data and fonts: GeoLite2 (CC BY-SA 4.0, MaxMind) and Inter
(SIL OFL 1.1). See `NOTICE` and `pkgs/ry/rybbit/LICENSE-inter`.

## Attribution

`pkgs/ry/rybbit/package.nix` started from [74k1/tixpkgs](https://github.com/74k1/tixpkgs)
(MIT) at the same upstream tag; copyright stays with its authors. What changed,
and why, is at the top of that file.
