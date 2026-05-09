let
  mkTool = import ../lib/mk-nixpkgs-tool.nix;
in
mkTool {
  name = "ffmpeg";
  binary = "ffmpeg";
  appAliases = [ "ffprobe" ];
  expectedVersion = "6.1.1";
  package = pkgs: pkgs.ffmpeg_6-headless;
}
