# Evaluate package metadata without building foreign-architecture executables.
let
  root = toString ../.;
  flake = builtins.getFlake root;
  definitions = import ../nix/lib/tool-definitions.nix;
  manifest = (builtins.fromTOML (builtins.readFile ../nix/tools.toml)).tools;
  systems = [ "x86_64-linux" "aarch64-linux" ];
  report = system:
    builtins.mapAttrs (name: tool:
      let
        package = flake.packages.${system}.${name};
        # Wrappers must expose their underlying package version; their names
        # are not reliable evidence of the binary version.
        version = package.version or null;
        entry = manifest.${name};
      in {
        packageName = package.name;
        packageVersion = version;
        manifestVersion = entry.version;
        reportedVersion = tool.expectedVersion;
        versionsMatch = version != null
          && version == entry.version
          && version == tool.expectedVersion;
        sourceRevision = tool.source.fetchTree.rev;
        inherit (entry) binaries groups;
      }) definitions;
in
assert builtins.attrNames definitions == builtins.attrNames manifest;
builtins.listToAttrs (map (system: {
  name = system;
  value = report system;
}) systems)
