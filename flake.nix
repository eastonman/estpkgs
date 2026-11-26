{
  description = "EastonMan's own Nix packages: the things nixpkgs does not carry";

  # Deliberately no nixConfig: this flake has no binary cache of its own yet.
  # When one exists, two lines go here -- and in the consumers' own
  # nix.settings, since an input's nixConfig is only honoured with
  # accept-flake-config.

  # Pinned to the branch the consumers actually run, not to unstable; the
  # reason is in README.md ("Why the flake pins nixos-26.05") so it lives in one
  # place and gets updated with the pin.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    {
      self,
      nixpkgs,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = lib.genAttrs systems;

      # Every `pkgs/<xy>/<name>/package.nix` (or `pkgs/<xy>/<name>.nix`) becomes
      # the package `<name>`; no index file to keep in sync. Same convention as
      # nixpkgs' pkgs/by-name, so a package can be moved upstream by `git mv`.
      # Anything else under pkgs/ (a helper next to a package, a per-package
      # default.nix) is not a package and is ignored rather than silently
      # becoming an attribute.
      packageFiles = builtins.filter (
        file:
        let
          parts = lib.path.subpath.components (lib.path.removePrefix ./pkgs file);
        in
        lib.hasSuffix ".nix" file
        && (lib.length parts == 2 || (lib.length parts == 3 && lib.last parts == "package.nix"))
      ) (lib.filesystem.listFilesRecursive ./pkgs);

      nameOf =
        file:
        let
          parts = lib.path.subpath.components (lib.path.removePrefix ./pkgs file);
        in
        # Decided by depth, not by basename: a flat file may legitimately be
        # called `package.nix`, in which case it is the package `package`.
        if lib.length parts == 3 then
          lib.last (lib.init parts)
        else
          lib.removeSuffix ".nix" (lib.last parts);

      packageNames = map nameOf packageFiles;

      # Two files that reduce to the same name would otherwise disappear into
      # each other: listToAttrs keeps the first one and says nothing.
      duplicates = lib.unique (
        lib.filter (name: lib.count (other: other == name) packageNames > 1) packageNames
      );

      packagesFor =
        pkgs:
        if duplicates != [ ] then
          throw "estpkgs: two package files produce the same attribute name: ${lib.concatStringsSep ", " duplicates}"
        else
          lib.listToAttrs (
            map (file: lib.nameValuePair (nameOf file) (pkgs.callPackage file { })) packageFiles
          );

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };

      # What this flake provides *and can build* on `system`, read back out of
      # the overlaid set so a sibling dependency would resolve from that same
      # set. The filter only hides platform mismatches: a package that fails to
      # evaluate fails here too, on every system, which is the point -- `nix
      # flake show` on Darwin must not report an empty set because something
      # broke. `nix build .#rybbit` on Darwin then says "does not provide
      # attribute" instead of a platform error from three phases deep.
      availableFor =
        system:
        let
          pkgs = pkgsFor system;
        in
        lib.filterAttrs (_: p: lib.meta.availableOn pkgs.stdenv.hostPlatform p) (
          lib.genAttrs packageNames (name: pkgs.${name})
        );
    in
    {
      packages = forAllSystems availableFor;

      # Buildable packages are the only thing worth checking here. On Darwin
      # these are empty on purpose; `nix flake check` says so and prints which
      # systems it omitted.
      checks = forAllSystems availableFor;

      # Pure `final: prev:` -- no pinned nixpkgs, no extra arguments. Consumers
      # keep their own nixpkgs (26.05, 26.05-darwin) and just stack this on top.
      # Unfiltered: a consumer's own nixpkgs is the judge of what it can build.
      # Note that an attribute name that nixpkgs already has would shadow it in
      # the consumer's fixpoint; today no name here collides.
      overlays.default = final: _prev: packagesFor final;

      # Same formatter as the fleet configuration, so `nix fmt` means the same
      # thing in both repositories.
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
