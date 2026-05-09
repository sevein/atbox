let
  mkTool = import ../lib/mk-nixpkgs-tool.nix;
in
mkTool {
  name = "poppler-utils";
  binary = "pdfinfo";
  appAliases = [ "pdftotext" ];
  expectedVersion = "24.02.0";
  package = pkgs: pkgs.poppler_utils;
}
