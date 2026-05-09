let
  mkTool = import ../lib/mk-nixpkgs-tool.nix;
in
mkTool {
  name = "java";
  binary = "java";
  expectedVersion = "17.0.10";
  package = pkgs: pkgs.jdk17_headless;
}
