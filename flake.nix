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
      forAllSystems = f:
        builtins.listToAttrs (map (system: {
            name = system;
            value = f system;
          })
          supportedSystems);
      mkSystemOutputs = system:
        let
          pkgs = import nixpkgs { inherit system; };
          toolchain = import ./nix/lib/mk-toolchain.nix {
            inherit system pkgs toolDefinitions;
          };
        in {
          packages = toolchain.packages;
          apps = toolchain.apps;
          devShells.default = pkgs.mkShellNoCC {
            packages = builtins.attrValues toolchain.toolPackages;
          };
        };
      systemOutputs = forAllSystems mkSystemOutputs;
    in {
      packages = builtins.mapAttrs (_: output: output.packages) systemOutputs;
      apps = builtins.mapAttrs (_: output: output.apps) systemOutputs;
      devShells = builtins.mapAttrs (_: output: output.devShells) systemOutputs;
    };
}
