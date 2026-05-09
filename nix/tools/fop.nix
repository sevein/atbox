let
  mkTool = import ../lib/mk-nixpkgs-tool.nix;
in
mkTool {
  name = "fop";
  binary = "fop";
  expectedVersion = "2.8";
  package = pkgs: pkgs.fop;
}
