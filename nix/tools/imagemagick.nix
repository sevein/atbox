let
  mkTool = import ../lib/mk-nixpkgs-tool.nix;
in
mkTool {
  name = "imagemagick";
  binary = "convert";
  appAliases = [
    "identify"
    "mogrify"
    "composite"
    "magick"
  ];
  expectedVersion = "7.1.1-34";
  package = pkgs: pkgs.imagemagick;
}
