let
  mkTool = import ../lib/mk-nixpkgs-tool.nix;
in
mkTool {
  name = "which";
  binary = "which";
  expectedVersion = "2.21";
  package = pkgs: pkgs.which;
}
