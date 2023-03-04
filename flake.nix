{
  description = "Hasktags generation for nix dependency trees";

  outputs = { ... }: {
    tags = import ./default.nix;
  };
}
