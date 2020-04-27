{
  pkgs ? import <nixpkgs> {},
  hasktagsOptions ? "--ctags --follow-symlinks --extendedctag --tags-absolute",
  suffixes ? ["hs" "lhs" "hsc"],
}:
with pkgs.lib.lists;
let

  # format rsync filter rules for haskell files with the desired `suffixes`.
  suffixesFilter = builtins.concatStringsSep "\n" (map (s: "+ *.${s}") suffixes);

  # rsync filter rule file that leaves only haskell library sources, selected by the global parameter `suffixes`.
  rsyncFilter = pkgs.writeText "tags-rsync-filter" ''
    - examples/
    - benchmarks/
    - test/
    - tests/
    - Setup.hs
    + */
    ${suffixesFilter}
    - *
  '';

  # hasktags takes a haskell list for the --suffixes option for some reason
  suffixesOption = builtins.concatStringsSep ", " (map (s: ''".${s}"'') suffixes);

  # Takes a haskell derivation and produces another derivation that reuses the `src` attribute to create tags.
  # The sources are unpacked and filtered so only non-test etc. haskell files (selecteed by the global parameter
  # `suffixes`) are present.
  # The remaining files are processed by `hasktags` and stored in the file `tags`.
  # The sources need to remain in the derivation's output for editors to find the tags' locations.
  packageTags = { name, src, ... }:
  pkgs.stdenv.mkDerivation {
    name = "${name}-tags";
    inherit src;
    buildInputs = [pkgs.haskellPackages.hasktags pkgs.rsync];
    phases = ["unpackPhase" "buildPhase"];
    buildPhase = ''
      fail() {
        echo "tags failed for ${name}"
        rm -f $out/tags
        touch $out/tags
      }
      mkdir -p $out/package
      rsync --recursive --prune-empty-dirs --filter='. ${rsyncFilter}' . $out/package/
      hasktags ${hasktagsOptions} --suffixes '[${toString suffixesOption}]' --output $out/tags $out/package || fail
    '';
  };

  # Takes a list of haskell derivations and produces a list of tag derivations.
  packageTagss = packages: (map packageTags packages);

  # Obtain the dependencies of a haskell derivation.
  inputs = p: p.getBuildInputs.haskellBuildInputs;

  # recursion delegate for `subTree`.
  accumulatePackage = z: p:
  let
    sub = subTree z.seen p;
  in
    { inherit (sub) seen; result = z.result ++ sub.result; };

  # recursion delegate for `subTree`.
  depTags = seen: package:
  builtins.foldl' accumulatePackage { inherit seen; result = []; } (inputs package);

  # Takes a list of package names and a package and produces a list of tag derivations.
  # The `seen` list is used to skip packages that have been processed before, since packages may occur multiple times
  # in a dependency tree.
  # Folds over the dependencies, accumulating the `seen` list.
  subTree = seen: package:
  let
    this = packageTags package;
    deps = depTags ([this] ++ seen) package;
    result = [this] ++ deps.result;
  in
    if builtins.elem package seen
    then { inherit seen; result = []; }
    else { seen = [package] ++ deps.seen; inherit result; };

  # Takes a haskell derivation and creates tags for all of its dependencies, including for the argument.
  # Returns a list of derivations.
  packageTree = package:
  (subTree [] package).result;

  # Takes a list of haskell derivations and creates tags for all of their dependencies.
  # Returns a list of derivations.
  packageTrees = packages:
  concatMap packageTree packages;

  # Takes a list of haskell derivations and produces a list of tag derivations for only the dependencies of the
  # arguments.
  depTagss = packages:
  concatMap (p: (depTags [] p).result) packages;

  header = pkgs.writeText "tags-header" ''
    !_TAG_FILE_FORMAT       2
    !_TAG_FILE_SORTED       1
    !_TAG_PROGRAM_NAME      hasktags
  '';

  # cat all package tags into one file.
  # Removes individual files' headers and adds a global one.
  merge = packages:
  let
    tags = map (p: "${p}/tags") packages;
  in
    pkgs.stdenv.mkDerivation {
      name = "project-tags";
      phases = ["buildPhase"];
      buildPhase = ''
        mkdir -p $out
        cat ${header} > $out/tags
        sort --unique ${toString tags} | grep -v '^!_TAG' > $out/tags
      '';
    };

  # cat all package tags into one file, splitting the argument list so that the shell's argument list length limit
  # isn't triggered.
  safeMerge = packages:
  let
    limit = 1024;
    mergePart = ps:
      if (builtins.length ps > limit)
      then [(merge (take limit ps))] ++ (mergePart (drop limit ps))
      else [(merge ps)];
  in
    merge (mergePart packages);

in rec {
  # Produce lists of single-package tag file derivations.
  # Each derivation's output contains a directory named `package` for the sources and a file named `tags`.
  individual = {
    # Tag only dependencies of the derivation argument.
    deps = { targets }: (depTagss targets).result;

    # Tag only the derivation argument's sources.
    packages = { targets }: packageTagss targets;

    # Tag the arguments' sources and their dependencies.
    all = { targets }: packageTrees targets;
  };

  # Produces a derivation of a combined tag file.
  # The output of the derivation contains one file named `tags`.
  combined = {
    # Tag only dependencies of the derivation argument.
    deps = { targets }: safeMerge (individual.deps { inherit targets; });

    # Tag only the derivation argument's sources.
    packages = { targets }: safeMerge (individual.packages { inherit targets; });

    # Tag the arguments' sources and their dependencies.
    all = { targets }: safeMerge (individual.all { inherit targets; });
  };
}
