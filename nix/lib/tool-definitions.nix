let
  tools = [
    (import ../tools/ffmpeg.nix)
    (import ../tools/fop.nix)
    (import ../tools/ghostscript.nix)
    (import ../tools/imagemagick.nix)
    (import ../tools/java.nix)
    (import ../tools/poppler-utils.nix)
    (import ../tools/unzip.nix)
    (import ../tools/which.nix)
  ];
in
  builtins.listToAttrs (map (tool: {
      name = tool.name;
      value = tool;
    })
    tools)
