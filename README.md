# thax – create haskell tags from nix dependencies

This nix expression provides a few functions for the creation of [hasktags]
from a dependency tree of haskell derivations as produced by [cabal2nix].

# Usage

All functions take a list of haskell derivations.
The functions in `individual` produce lists of derivations, each of which
contain the tags file for a package, while those in `combined` produce
a derivation for a merged tag file.

There are three functions in each of those two sets:

* `deps` generates tags for only the dependencies
* `packages` generates tags for only the targets
* `all` combines the above

## Ad-hoc from the shell

```sh
nix-build -A combined.packages --arg targets '[(import <nixpkgs> {}).haskellPackages.aeson]'
```

builds only the tags for `aeson` without dependencies, while `combined.all`
would build its dependencies as well and merge everything into the file `tags`
in the output store path.

## In your project config

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

```sh
cp $(nix-build --no-link -A projectTags)/tags .tags
```

# Relative paths

The tags of the packages you are developing in your project should not be
pointing to the store, but `nix` will copy them over before running the
derivation builder.

Therefore all packages passed into the API functions will be tagged with
relative paths by default, while all dependencies will have absolute paths.

You can override this behaviour by passing `relative = false;` to the
functions, as in:

```nix
tags.combined.all { inherit targets; relative = false; }
```

or more granularly by setting the `relative` attribute on a package, like:

```nix
tags.combined.all { targets = [mypackage // { relative = false; }]; }
```

## Directory prefixes

If the relative path isn't enough, because your local packages are located in
subdirectories, you can set the package's attribute `tagsPrefix` like so:

```nix
tags.combined.all { targets = [mypackage // { tagsPrefix = "packages/mypack"; }]; }
```

## GHC

Since `base` et al. aren't regular dependencies, the `all` function will
include the GHC sources.
If that is not desired, you can deactivate it:

```nix
tags.combined.all { inherit targets; base = false; }
```

[hasktags]: https://hackage.haskell.org/package/hasktags
[cabal2nix]: https://hackage.haskell.org/package/cabal2nix
[obelisk]: https://github.com/obsidiansystems/obelisk
