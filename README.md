# thax – create haskell tags from nix dependencies

This nix expression provides a few functions for the creation of [hasktags]
from a dependency tree of haskell derivations as produced by [cabal2nix].

All functions take a list of haskell derivations.
The functions in `individual` produce lists of derivations, each of which
contain the tags file for a package, while those in `combined` produce
a derivation for a merged tag file.

For example:

```shell
nix-build -A combined.packages --arg targets '[(import <nixpkgs> {}).haskellPackages.aeson]'
```

builds only the tags for `aeson` without dependencies, while `combined.all`
would build its dependencies as well and merge everything into the file `tags`
in the output store path.

Using it in your project config:

```nix
let
  pkgs = import <nixpkgs> {};
  tags = import (fetchTarball "https://github.com/tek/thax/tarball/master") { inherit pkgs; };
  packages = "???"; # however your project is set up
in {
  projectTags = tags.combined.all { targets = packages; };
}
```

For example, in an [obelisk] project:

```nix
let
  pkgs = import <nixpkgs> {};
  obelisk = (import ./.obelisk/impl {}).project ./. ({ ... }: {});
  targets = [obelisk.ghc.frontend obelisk.ghc.backend obelisk.ghc.common];
  tags = import (fetchTarball "https://github.com/tek/thax/tarball/master") { inherit pkgs; };
in
  obelisk // {
    projectTags = tags.combined.all { inherit targets; };
  }
```

Now you can generate all project dependencies' tags with:

```shell
cp $(nix-build --no-link -A projectTags)/tags .tags
```

[hasktags]: https://hackage.haskell.org/package/hasktags
[cabal2nix]: https://hackage.haskell.org/package/cabal2nix
[obelisk]: https://github.com/obsidiansystems/obelisk
