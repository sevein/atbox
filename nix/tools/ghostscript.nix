let
  mkTool = import ../lib/mk-nixpkgs-tool.nix;
in
mkTool {
  name = "ghostscript";
  binary = "gs";
  appAliases = [ "ps2pdf" ];
  expectedVersion = "10.03.1";
  package =
    pkgs:
    let
      ghostscript = pkgs.ghostscript_headless;
    in
    pkgs.symlinkJoin {
      name = "ghostscript-atbox";
      paths = [ ghostscript ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        rm "$out/bin/ps2pdf"
        makeWrapper ${ghostscript}/bin/ps2pdf "$out/bin/ps2pdf" \
          --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.coreutils ]}
      '';
    };
}
