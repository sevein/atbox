{
  name,
  binary,
  expectedVersion,
  package,
  appAliases ? [ ],
}:
{
  inherit name binary expectedVersion package;
  source = import ./nixpkgs-source.nix;
}
// (
  if appAliases == [ ] then
    { }
  else
    { inherit appAliases; }
)
