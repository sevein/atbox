let
  mkTool = import ../lib/mk-nixpkgs-tool.nix;
in
mkTool {
  name = "unzip";
  binary = "unzip";
  expectedVersion = "6.0";
  package = pkgs: pkgs.unzip;
}
