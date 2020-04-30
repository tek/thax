{
  pkgs ? import <nixpkgs> {},
  hasktagsOptions ? "--ctags --follow-symlinks --extendedctag",
  suffixes ? ["hs" "lhs" "hsc"],
}:
with pkgs.lib.lists;
let
  hasktagsSrc = pkgs.fetchFromGitHub {
    owner = "tek";
    repo = "hasktags";
    rev = "force-utf8";
    sha256 = "140hjvgxyiqczjnssnasi1bv74sam6gfpvd5aazz0xsf4id7nqvv";
  };

  hasktags = pkgs.haskellPackages.callCabal2nix "name" hasktagsSrc {};

  # Create a string from the suffixes.
  concatSuffixes =
    sep: f:
    builtins.concatStringsSep sep (map f suffixes);

  # Format rsync filter rules for haskell files with the desired `suffixes`.
  suffixesFilter = concatSuffixes "\n" (s: "+ *.${s}");

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

  # hasktags takes a haskell list for the --suffixes option for some reason.
  suffixesOption =
    let sxs = toString (concatSuffixes ", " (s: ''".${s}"''));
    in  "'[${sxs}]'";

  # Takes a haskell derivation and produces another derivation that reuses the `src` attribute to create tags.
  # The sources are unpacked and filtered so only non-test etc. haskell files (selected by the global parameter
  # `suffixes`) are present.
  # The remaining files are processed by `hasktags` and stored in the file `tags`.
  # The sources need to remain in the derivation's output for editors to find the tags' locations.
  # If `hasktags` fails, we don't want want the whole process to be unusable just because there is some weird code in
  # one of the dependencies, so we just print an error message and output an empty tag file.
  # If the flag `relative` is true, the package is treated as being in `cwd`. When developing a project, it wouldn't be
  # very ergonomical to have the tags pointing to the store, so we use relative paths in the tag file.
  packageTags = { relative ? false, tagsPrefix ? "", name, src, ... }:
  let
    absoluteOption = if relative then "" else "--tags-absolute";
    options = "${hasktagsOptions} ${absoluteOption}";
    hasktagsCmd = "${hasktags}/bin/hasktags ${options} --suffixes ${suffixesOption} --output $out/tags .";
  in
    pkgs.stdenv.mkDerivation {
      name = "${name}-tags";
      inherit src;
      buildInputs = [hasktags pkgs.rsync];
      phases = ["unpackPhase" "buildPhase"];
      buildPhase = ''
        fail() {
          echo "tags failed for ${name}"
          rm -f $out/tags
          touch $out/tags
        }
        package=$out/package/${tagsPrefix}
        mkdir -p $package
        rsync --recursive --prune-empty-dirs --filter='. ${rsyncFilter}' . $package/
        echo '${hasktagsCmd}' > $out/hasktags-cmd
        cd $out/package
        ${hasktagsCmd} &> $out/hasktagsLog || fail
      '';
    };

  # Takes a list of haskell derivations and produces a list of tag derivations.
  packageTagss =
    { relative ? true, targets }:
    map (p: packageTags ({ inherit relative; } // p)) targets;

  # Obtain the dependencies of a haskell derivation.
  inputs = p: p.getBuildInputs.haskellBuildInputs;

  # Call a function propagating seen elements and merge its results with the accumulator.
  accumulateSeen = f: z: a:
  let
    sub = f z.seen a;
  in
    { inherit (sub) seen; result = z.result ++ sub.result; };

  # Call a function propagating seen elements for each element in the list and accumulate all results.
  foldSeen = f: seen: as:
  builtins.foldl' (accumulateSeen f) { inherit seen; result = []; } as;

  # recursion delegate for `subTree`.
  depTree = seen: package:
  foldSeen subTree seen (inputs package);

  # Takes a list of package names and a package and produces a list of tag derivations.
  # The `seen` list is used to skip packages that have been processed before, since packages may occur multiple times
  # in a dependency tree.
  # Folds over the dependencies, accumulating the `seen` list.
  subTree = seen: package:
  let
    this = packageTags package;
    deps = depTree ([this] ++ seen) package;
    result = [this] ++ deps.result;
  in
    if builtins.elem package seen
    then { inherit seen; result = []; }
    else { seen = [package] ++ deps.seen; inherit result; };

  # Takes a haskell derivation and creates tags for all of its dependencies, including for the argument.
  # Returns a list of tag file derivations.
  packageTree = relative: target:
  let
    targetTags = packageTags ({ inherit relative; } // target);
    depTags = (depTree subTree [target.name] package).result;
  in
    [targetTags] ++ depTags;

  # Takes a list of haskell derivations and creates tags for them and all of their dependencies.
  # Returns a list of tag file derivations.
  packageTrees = args@{ targets, relative ? true }:
  let
    targetTags = packageTagss args;
    subTags = foldSeen depTree targets targets;
  in
    targetTags ++ subTags.result;

  # Takes a list of haskell derivations and produces a list of tag derivations for only the dependencies of the
  # arguments.
  depTagss =
    foldSeen depTree [];

  header = pkgs.writeText "tags-header" ''
    !_TAG_FILE_FORMAT       2
    !_TAG_FILE_SORTED       1
    !_TAG_PROGRAM_NAME      hasktags
    !_TAG_STORE_PATH        '';

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
        echo $out >> $out/tags
        sort --unique ${toString tags} | grep -v '^!_TAG' >> $out/tags
        echo "${builtins.concatStringsSep "\n" tags}" > $out/parts
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
      else if (builtins.length ps == 1)
      then ps
      else [(merge ps)];
    merged = mergePart packages;
  in
  if (builtins.length merged == 1)
  then builtins.head merged
  else merge (mergePart packages);

in rec {
  # Produce lists of single-package tag file derivations.
  # Each derivation's output contains a directory named `package` for the sources and a file named `tags`.
  individual = {
    # Tag only dependencies of the derivation argument.
    deps = { targets }: (depTagss targets).result;

    # Tag only the derivation arguments' sources.
    # `relative` determines whether the targets should be tagged with relative paths.
    packages = args@{ targets, relative ? true }: packageTagss args;

    # Tag the arguments' sources and their dependencies.
    # `relative` determines whether the targets should be tagged with relative paths.
    all = args@{ targets, relative ? true }: packageTrees args;
  };

  # Produces a derivation of a combined tag file.
  # The output of the derivation contains one file named `tags`.
  combined = {
    # Tag only dependencies of the derivation argument.
    deps = { targets }: safeMerge (individual.deps { inherit targets; });

    # Tag only the derivation arguments' sources.
    # `relative` determines whether the targets should be tagged with relative paths.
    packages = args@{ targets, relative ? true }: safeMerge (individual.packages args);

    # Tag the arguments' sources and their dependencies.
    # `relative` determines whether the targets should be tagged with relative paths.
    all = args@{ targets, relative ? true }: safeMerge (individual.all args);
  };
}
