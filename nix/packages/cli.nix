# CLI package - escript for command-line interaction
{ lib, beamPackages, elixir, erlang, fetchMixDeps ? null }:

let
  pname = "mxc-cli";
  version = "0.1.0";
  src = ../..;

  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "${pname}-deps";
    inherit src version;
    hash = lib.fakeHash; # Update after first build attempt
  };

in beamPackages.mixRelease {
  inherit pname version src;

  mixFodDeps = if fetchMixDeps != null then fetchMixDeps else mixFodDeps;

  mixEnv = "prod";

  postBuild = ''
    # Build the escript
    mix escript.build
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp mxc $out/bin/

    runHook postInstall
  '';

  meta = with lib; {
    description = "Mxc CLI - command-line interface for cluster management";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "mxc";
  };
}
