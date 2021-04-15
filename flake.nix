{
  description = "Hasktags Generation for Nix Dependency Trees";

  outputs = { ... }: {
    tags = import ./default.nix;
  };
}
