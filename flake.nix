{
  description = "atbox AtoM external toolchain";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = {
    nixpkgs,
    ...
  }:
    let
      toolDefinitions = import ./nix/lib/tool-definitions.nix;
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      devShellSystems =
        supportedSystems
        ++ [
          "x86_64-darwin"
          "aarch64-darwin"
        ];
      forSystems = systems: f:
        builtins.listToAttrs (map (system: {
            name = system;
            value = f system;
          })
          systems);
      mkDevShell = system:
        let
          pkgs = import nixpkgs { inherit system; };
          linuxToolPackages =
            if pkgs.stdenv.hostPlatform.isLinux
            then
              builtins.attrValues
              (import ./nix/lib/mk-toolchain.nix {
                inherit system pkgs toolDefinitions;
              })
              .toolPackages
            else [];
        in
          pkgs.mkShellNoCC {
            packages =
              linuxToolPackages
              ++ [
                pkgs.kubeconform
                pkgs.kubernetes-helm
              ];
            HELM_PLUGINS = "${pkgs.kubernetes-helmPlugins.helm-unittest}";
          };
      mkSystemOutputs = system:
        let
          pkgs = import nixpkgs { inherit system; };
          toolchain = import ./nix/lib/mk-toolchain.nix {
            inherit system pkgs toolDefinitions;
          };
        in {
          packages = toolchain.packages;
          apps = toolchain.apps;
        };
      systemOutputs = forSystems supportedSystems mkSystemOutputs;
    in {
      packages = builtins.mapAttrs (_: output: output.packages) systemOutputs;
      apps = builtins.mapAttrs (_: output: output.apps) systemOutputs;
      devShells = forSystems devShellSystems (system: {
        default = mkDevShell system;
      });
    };
}
