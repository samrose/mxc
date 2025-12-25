# Coordinator package - Elixir release for coordinator mode
{ lib, beamPackages, elixir, erlang, nodejs, rebar3, stdenv, fetchMixDeps ? null }:

let
  pname = "mxc-coordinator";
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

  nativeBuildInputs = [ nodejs ];

  # Set release name
  mixEnv = "prod";

  postBuild = ''
    # Build assets
    mix assets.deploy

    # Build the coordinator release
    mix release coordinator --overwrite
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r _build/prod/rel/coordinator/* $out/

    runHook postInstall
  '';

  meta = with lib; {
    description = "Mxc coordinator - cluster orchestration service";
    license = licenses.mit;
    platforms = platforms.unix;
  };
}
