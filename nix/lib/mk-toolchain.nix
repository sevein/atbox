{
  system,
  pkgs,
  toolDefinitions,
}:
let
  toolManifest = (builtins.fromTOML (builtins.readFile ../tools.toml)).tools;

  addSource =
    acc: tool:
    let
      source = tool.source;
    in
      if acc ? ${source.name} then
        acc
      else
        acc
        // builtins.listToAttrs [
          {
            name = source.name;
            value = import (builtins.fetchTree source.fetchTree) { inherit system; };
          }
        ];

  sourcePackageSets = builtins.foldl' addSource {} (builtins.attrValues toolDefinitions);

  resolveTool =
    tool:
    let
      packageSet =
        sourcePackageSets.${tool.source.name}
        or (throw "Unknown tool source: ${tool.source.name}");
      package = tool.package packageSet;
      manifestEntry =
        toolManifest.${tool.name}
        or (throw "Missing tools.toml entry for tool: ${tool.name}");
    in
      tool
      // {
        inherit package;
        groups = manifestEntry.groups or [ ];
      };

  tools = builtins.mapAttrs (_: resolveTool) toolDefinitions;

  toolPackages = builtins.mapAttrs (_: tool: tool.package) tools;

  filterToolsByGroup = group:
    pkgs.lib.filterAttrs (_: tool: builtins.elem group tool.groups) tools;

  mkVersionManifest = fileName: selectedTools:
    pkgs.writeText fileName (
      builtins.concatStringsSep "\n" (
        builtins.map (
          tool:
            "${tool.name} ${tool.expectedVersion}"
        ) (builtins.attrValues selectedTools)
      )
      + "\n"
    );

  mkVersionReport = versionManifest:
    pkgs.writeShellApplication {
      name = "version-report";
      text = ''
        cat ${versionManifest}
      '';
    };

  mkAggregate = packageName: group:
    let
      selectedTools = filterToolsByGroup group;
      versionManifest = mkVersionManifest "${packageName}-versions.txt" selectedTools;
      versionReport = mkVersionReport versionManifest;
      selectedPackages = builtins.attrValues (
        builtins.mapAttrs (_: tool: tool.package) selectedTools
      );
    in {
      inherit selectedTools versionManifest versionReport;
      package = pkgs.buildEnv {
        name = packageName;
        paths = selectedPackages ++ [ versionReport ];
      };
    };

  aggregates = {
    atbox-toolchain = mkAggregate "atbox-toolchain" "atbox";
    atbox-admin-toolchain = mkAggregate "atbox-admin-toolchain" "admin";
    atbox-cli-toolchain = mkAggregate "atbox-cli-toolchain" "cli";
    atbox-worker-toolchain = mkAggregate "atbox-worker-toolchain" "worker";
  };

  versionManifest = aggregates.atbox-toolchain.versionManifest;
  versionReport = aggregates.atbox-toolchain.versionReport;

  mkApp = binary: {
    type = "app";
    program = "${tools.${binary.toolName}.package}/bin/${binary.binaryName}";
  };

  toolAppEntries = builtins.concatLists (
    builtins.map (
      tool:
        [
          {
            name = tool.name;
            value = mkApp {
              toolName = tool.name;
              binaryName = tool.binary;
            };
          }
        ]
        ++ builtins.map (binaryName: {
          name = binaryName;
          value = mkApp {
            toolName = tool.name;
            inherit binaryName;
          };
        }) (tool.appAliases or [ ])
    ) (builtins.attrValues tools)
  );

  toolApps = builtins.listToAttrs toolAppEntries;
in {
  inherit tools toolPackages versionManifest;

  packages =
    toolPackages
    // {
      atbox-toolchain = aggregates.atbox-toolchain.package;
      atbox-admin-toolchain = aggregates.atbox-admin-toolchain.package;
      atbox-cli-toolchain = aggregates.atbox-cli-toolchain.package;
      atbox-worker-toolchain = aggregates.atbox-worker-toolchain.package;

      tool-versions = versionManifest;
      version-report = versionReport;
      admin-tool-versions = aggregates.atbox-admin-toolchain.versionManifest;
      admin-version-report = aggregates.atbox-admin-toolchain.versionReport;
      cli-tool-versions = aggregates.atbox-cli-toolchain.versionManifest;
      cli-version-report = aggregates.atbox-cli-toolchain.versionReport;
      worker-tool-versions = aggregates.atbox-worker-toolchain.versionManifest;
      worker-version-report = aggregates.atbox-worker-toolchain.versionReport;
    };

  apps =
    toolApps
    // {
      version-report = {
        type = "app";
        program = "${versionReport}/bin/version-report";
      };
    };
}
