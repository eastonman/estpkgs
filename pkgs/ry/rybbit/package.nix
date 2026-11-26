# Rybbit 2.9.3 -- self-hostable web analytics, built from source.
#
# Derived from 74k1/tixpkgs (MIT) `pkgs/ry/rybbit/package.nix`; the accepted
# changes follow the downstream deployment's own runbook (§6.1 there):
#   * the real Inter font is shipped and wired through next/font/local, instead
#     of deleting the font import and losing the typeface
#   * `node dist/index.js` runs the server, not bun
#   * no `async rewrites()` injection: the reverse proxy splits /api/ instead
#   * both MaxMind databases ship -- upstream reads GeoLite2-ASN.mmdb from the
#     working directory too (server/src/db/geolocation/asn.ts)
#   * Chromium ships for the PDF report export, as upstream's own Dockerfile
#     does; the self-hosted UI shows that button (canExportPdf is false only for
#     a paid-cloud free/AppSumo plan, and a self-hosted install has no
#     subscription at all, so the button is visible)
#
# The three hashes are inherited from that package at the same tag and all three
# were confirmed by a build on nixos-26.05: npmDepsFetcherVersion is 1 on both
# branches, so the hash does not depend on which one computed it. Re-check when
# the pin moves -- a mismatch prints the expected hash; paste it, never commit
# lib.fakeHash.
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchFromGitHub,
  buildNpmPackage,
  makeWrapper,
  chromium,
  inter,
  node-gyp,
  nodejs,
  python3,
  typescript,
  # nixos-26.05 ships TypeScript 5.9.3 as `typescript`; unstable ships 7 as
  # `typescript` and 5 as `typescript_5`. shared/tsconfig.json still sets
  # moduleResolution=node10, which TypeScript 7 removed, so take whichever 5.x
  # the consuming tree provides.
  typescript_5 ? null,
  zstd,
  nix-update-script,
  # Deployment-specific: the public origin this instance is served from.
  # Empty means "same origin" -- right for the browser, but Node has no
  # document to resolve "/api" against, so any server-rendered page that
  # touches the API throws ERR_INVALID_URL at render time. Upstream's own
  # docker-compose passes its BASE_URL here for exactly that reason; a
  # deployment behind a reverse proxy that splits /api/ should pass its
  # own origin.
  backendUrl ? "",
}:

let
  version = "2.9.3";

  tsc = if typescript_5 != null then typescript_5 else typescript;

  src = fetchFromGitHub {
    owner = "rybbit-io";
    repo = "rybbit";
    rev = "v${version}";
    hash = "sha256-fSzLnODHKU187G52reT2JvcDztd02a8McUMvQTTP+AY=";
  };

  # `@rybbit/shared` is a `file:../shared` dependency of both workspace roots and
  # only its dist/ is importable. Build it once, copy it into both node_modules.
  #
  # tsc must be 5.x: shared/tsconfig.json still sets moduleResolution=node10,
  # which TypeScript 7 removed.
  rybbit-shared = stdenvNoCC.mkDerivation {
    pname = "rybbit-shared";
    inherit version src;

    sourceRoot = "source/shared";
    nativeBuildInputs = [
      nodejs
      tsc
    ];

    buildPhase = ''
      runHook preBuild
      tsc
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r dist $out/
      cp package.json $out/
      runHook postInstall
    '';
  };

  rybbit-client = buildNpmPackage {
    pname = "rybbit-client";
    inherit version src;

    sourceRoot = "source/client";

    npmDepsHash = "sha256-NySYpAOjGIIuyn4FBxbsup67kMLsEB65mquedJz5bYA=";
    npmFlags = [ "--legacy-peer-deps" ];

    # Pages + Performance tabs (and the Web Vitals toggle that feeds the latter)
    # for self-hosted installs. Deliberately leaves Bots, Search Console, Query,
    # dashboards and every billing path on the cloud side. See README.md.
    patches = [ ./decloud.patch ];
    # The patch is rooted at the repository, so it also applies with plain
    # `git apply` against the upstream tag; that is one directory above
    # sourceRoot (`source/client`), hence -p2.
    patchFlags = [ "-p2" ];

    # next/font/google downloads fonts at build time. Inter becomes a real font
    # from nixpkgs; Tilt_Warp (a decorative display face used for one heading)
    # becomes a stub with the same call shape, so the call site upstream stays
    # untouched -- a single-line substitution is also immune to the formatter,
    # which reindents the contents of multi-line Nix strings.
    postPatch = ''
      substituteInPlace src/app/layout.tsx \
        --replace-fail 'import { Inter } from "next/font/google";' \
                       'import localFont from "next/font/local";' \
        --replace-fail 'const inter = Inter({ subsets: ["latin"] });' \
                       'const inter = localFont({ src: "./Inter.ttf" });'
      cp ${inter}/share/fonts/truetype/InterVariable.ttf src/app/Inter.ttf

      substituteInPlace 'src/app/[site]/main/components/MainSection/MainSection.tsx' \
        --replace-fail 'import { Tilt_Warp } from "next/font/google";' \
                       'const Tilt_Warp = (_options: Record<string, unknown>) => ({ className: "" });'
    '';

    postConfigure = ''
      rm -rf node_modules/@rybbit/shared
      mkdir -p node_modules/@rybbit/shared
      cp -r ${rybbit-shared}/dist node_modules/@rybbit/shared/
      cp ${rybbit-shared}/package.json node_modules/@rybbit/shared/
    '';

    # NEXT_PUBLIC_* is baked into the bundle at build time, so the backend URL
    # is an argument rather than something a service can set at start-up.
    env = {
      NEXT_TELEMETRY_DISABLED = "1";
      NEXT_PUBLIC_BACKEND_URL = backendUrl;
    };

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/rybbit-client
      cp -r .next/standalone/. $out/share/rybbit-client/
      cp -r .next/static $out/share/rybbit-client/.next/static
      cp -r public $out/share/rybbit-client/public

      runHook postInstall
    '';
  };
in
buildNpmPackage {
  pname = "rybbit";
  inherit version src;

  sourceRoot = "source/server";

  npmDepsHash = "sha256-+ACbNzC20Lu4GjJrXWUaXe4VZUtPpCAgky8jn30yUog=";
  npmFlags = [ "--legacy-peer-deps" ];
  # The default, spelled out: install scripts stay off, so puppeteer does not
  # download a browser and @mongodb-js/zstd is not built twice. The one native
  # addon the server needs is rebuilt by hand below.
  npmRebuildFlags = [ "--ignore-scripts" ];

  nativeBuildInputs = [
    node-gyp
    python3
    makeWrapper
  ];
  buildInputs = [
    zstd.dev
    (lib.getLib zstd)
  ];

  postConfigure = ''
    rm -rf node_modules/@rybbit/shared
    mkdir -p node_modules/@rybbit/shared
    cp -r ${rybbit-shared}/dist node_modules/@rybbit/shared/
    cp ${rybbit-shared}/package.json node_modules/@rybbit/shared/

    # @mongodb-js/zstd vendors its own zstd; point it at nixpkgs' instead of
    # compiling a second copy, then build just that one native addon.
    substituteInPlace node_modules/@mongodb-js/zstd/binding.gyp \
      --replace-fail "<(module_root_dir)/deps/zstd/lib" "${zstd.dev}/include" \
      --replace-fail "<(module_root_dir)/deps/zstd/out/lib/libzstd.a" \
                     "${lib.getLib zstd}/lib/libzstd${stdenv.hostPlatform.extensions.sharedLibrary}"

    pushd node_modules/@mongodb-js/zstd
    node-gyp rebuild --nodedir=${nodejs}
    popd

    # Upstream hardcodes the listen port; make it configurable without a patch.
    sed -i "s/port: 3001/port: parseInt(process.env.PORT || '3001')/g" src/index.ts
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/rybbit-server $out/share/rybbit-client $out/bin

    cp -r ${rybbit-client}/share/rybbit-client/. $out/share/rybbit-client/

    # The server runs from its own directory: every path it opens (drizzle/,
    # public/, the MaxMind files, ./GeoLite2-*.mmdb via cwd) is relative.
    cp -r dist public drizzle src $out/share/rybbit-server/
    cp drizzle.config.ts package.json $out/share/rybbit-server/
    cp GeoLite2-City.mmdb GeoLite2-ASN.mmdb $out/share/rybbit-server/
    cp -r node_modules $out/share/rybbit-server/

    # AGPL-3.0 (modified build), GeoLite2 (CC BY-SA) and Inter (OFL) travel
    # with the artifact, not just with the repository. Named explicitly: `cp` of
    # a store path into a directory keeps the hash prefix in the file name.
    mkdir -p $out/share/doc/rybbit
    cp ${./NOTICE} $out/share/doc/rybbit/NOTICE
    cp ${./LICENSE-inter} $out/share/doc/rybbit/LICENSE-inter

    # The database schema is not created by the server at boot (upstream runs
    # this from docker-entrypoint.sh), so a deployment gets an ordered
    # ExecStartPre instead of a service that looks healthy and is not.
    makeWrapper ${lib.getExe nodejs} $out/bin/rybbit-migrate \
      --chdir $out/share/rybbit-server \
      --set-default NODE_ENV production \
      --add-flags $out/share/rybbit-server/node_modules/drizzle-kit/bin.cjs \
      --add-flags migrate \
      --add-flags --config=drizzle.config.ts

    makeWrapper ${lib.getExe nodejs} $out/bin/rybbit-server \
      --chdir $out/share/rybbit-server \
      --set-default NODE_ENV production \
      --set NEXT_TELEMETRY_DISABLED 1 \
      --set-default PORT 3001 \
      --set PUPPETEER_EXECUTABLE_PATH ${lib.getExe chromium} \
      --add-flags $out/share/rybbit-server/dist/index.js

    makeWrapper ${lib.getExe nodejs} $out/bin/rybbit-server-cluster \
      --chdir $out/share/rybbit-server \
      --set-default NODE_ENV production \
      --set NEXT_TELEMETRY_DISABLED 1 \
      --set-default PORT 3001 \
      --set PUPPETEER_EXECUTABLE_PATH ${lib.getExe chromium} \
      --add-flags $out/share/rybbit-server/dist/cluster.js

    makeWrapper ${lib.getExe nodejs} $out/bin/rybbit-client \
      --chdir $out/share/rybbit-client \
      --set-default NODE_ENV production \
      --set NEXT_TELEMETRY_DISABLED 1 \
      --set-default PORT 3002 \
      --set-default HOSTNAME 127.0.0.1 \
      --add-flags $out/share/rybbit-client/server.js

    runHook postInstall
  '';

  passthru = {
    inherit rybbit-client rybbit-shared;
    updateScript = nix-update-script { extraArgs = [ "--subpackage=rybbit-client" ]; };
  };

  meta = {
    description = "Self-hostable web analytics with pages, performance and session replay";
    homepage = "https://rybbit.com/";
    changelog = "https://github.com/rybbit-io/rybbit/releases/tag/v${version}";
    license = lib.licenses.agpl3Only;
    # Not source-only: the client's node_modules carries npm-distributed native
    # addons (e.g. @img/sharp-linux-x64 for Next image optimization), copied as
    # published. The zstd addon is the only native code this recipe compiles.
    sourceProvenance = [
      lib.sourceTypes.fromSource
      lib.sourceTypes.binaryNativeCode
    ];
    mainProgram = "rybbit-server";
    platforms = lib.platforms.linux;
    # Not in nixpkgs' maintainer list on purpose: this repository's own entry.
    maintainers = [
      {
        name = "EastonMan";
        email = "me@eastonman.com";
      }
    ];
  };
}
