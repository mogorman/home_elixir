{ lib
, stdenvNoCC
, elixir
, erlang
, hexDeps
, hermetic
}:

stdenvNoCC.mkDerivation rec {
  pname = "home-elixir";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ elixir erlang ];

  # Hermetic offline mix build. The nix sandbox has no network and the build
  # user can't disable it, so we seed hex's package cache (the 17 locked
  # tarballs), the registry snapshot (cache.ets), the hex archive and rebar3
  # into a private MIX_HOME/HEX_HOME, then run mix with HEX_OFFLINE=1. No
  # network is touched at build time; everything is pinned.
  buildPhase = ''
    runHook preBuild
    export HE_SRC=$PWD
    export MIX_ENV=prod
    export MIX_HOME=$PWD/.mix-home
    export HEX_HOME=$PWD/.hex-home
    export HEX_OFFLINE=1
    export LC_ALL=C.UTF-8 LANG=C.UTF-8
    export ELIXIR_ERL_OPTIONS="+fnu"
    mkdir -p $MIX_HOME/archives $MIX_HOME/elixir/1-20-otp-28 $HEX_HOME/packages/hexpm
    cp -a ${hermetic}/hex-archive/hex-2.5.2 $MIX_HOME/archives/
    cp -a ${hermetic}/cache.ets $HEX_HOME/cache.ets
    # rebar3 is an escript with a "#!/usr/bin/env escript" shebang, but the
    # sandbox has no /usr/bin/env. Wrap it in /bin/sh that calls escript (on
    # PATH) directly.
    rebar_dir=$MIX_HOME/elixir/1-20-otp-28
    cp -a ${hermetic}/rebar3 $rebar_dir/rebar3.escript
    printf '#!/bin/sh\nexec escript "%s" "$@"\n' "$rebar_dir/rebar3.escript" > $rebar_dir/rebar3
    chmod +x $rebar_dir/rebar3
    # fetchurl store paths are "<32-char-hash>-<name>"; hex needs the bare
    # "<name>" (e.g. mint_web_socket-1.0.6.tar), so strip the hash prefix.
    for f in ${lib.concatStringsSep " " (lib.attrValues hexDeps)}; do
      cp -a "$f" "$HEX_HOME/packages/hexpm/$(basename "$f" | cut -c34-)"
    done
    mix deps.get
    mix release --path rel
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cd "$HE_SRC"
    cp -a rel $out
    cp -a flows $out/flows
    runHook postInstall
  '';
}
