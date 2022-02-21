{ pkgs

, lib

, compiler-version ? "ghc8107"

, compiler ? pkgs.haskell.packages."${compiler-version}"

, extra-build-tools ? []               # extra tools available for nix develop
}:
let
  haskell = compiler.extend (_: _: {
    inherit (pkgs) theta;
  });

  rust-executable = import ./rust { inherit pkgs lib; };

  python-executable = import ./python { inherit pkgs lib; };

  build-tools =
    [ haskell.stylish-haskell
      haskell.cabal-install
      haskell.haskell-language-server
      haskell.hlint
      pkgs.stack
      pkgs.time-ghc-modules

      rust-executable
      python-executable
    ] ++ extra-build-tools;

  excluded = [
    "dist"
    "dist-newstyle"
    "stack.yaml"
    ".stack-work"
    "stack.yaml.lock"
    "stack-shell.nix"
  ];

  add-build-tools = p:
    pkgs.haskell.lib.addBuildTools p build-tools;
in
haskell.developPackage {
  name = "theta-tests";
  root = (pkgs.lib.cleanSourceWith
    {
      src = ./.;
      filter = path: type:
        !(pkgs.lib.elem (baseNameOf (toString path)) excluded)
        && !pkgs.lib.hasPrefix ".ghc.environment." (baseNameOf (toString path))
        && pkgs.lib.cleanSourceFilter path type;
    }).outPath;

  modifier = add-build-tools;

  # explicitly disable "smart" detection of nix-shell status
  #
  # The default value of returnShellEnv is impure: it checks the
  # value of the IN_NIX_SHELL environment variable.
  returnShellEnv = false;
}
