# Dispatch to the proper implementation of the gecko build expression.
{
  build = (import ./firefox-env/release.nix {}).build;
  gecko = (import ./nixpkgs-mozilla/release.nix {}).gecko;
}
