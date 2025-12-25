# Agent package - Elixir release for agent mode
{ lib, beamPackages, stdenv }:

let
  pname = "mxc-agent";
  version = "0.1.0";
  src = lib.cleanSource ../..;

  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "${pname}-deps";
    inherit src version;
    hash = "sha256-XdR5DRfY+Jdjm2G3uuwBSUCigGU4DKT+y0VSjxN0/08=";
  };

in beamPackages.mixRelease {
  inherit pname version src mixFodDeps;

  # erlexec needs C compiler
  nativeBuildInputs = [ stdenv.cc ];

  # Remove devDependencies
  removeCookie = false;

  postBuild = ''
    # Build the agent release (no assets needed)
    mix release agent --overwrite
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp -r _build/prod/rel/agent/* $out/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Mxc agent - workload execution service";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
