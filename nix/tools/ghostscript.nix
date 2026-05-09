let
  mkTool = import ../lib/mk-nixpkgs-tool.nix;
in
mkTool {
  name = "ghostscript";
  binary = "gs";
  appAliases = [ "ps2pdf" ];
  expectedVersion = "10.03.1";
  package = pkgs: pkgs.ghostscript_headless;
}
