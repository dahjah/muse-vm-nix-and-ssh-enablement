# muse-api-bridge: the OpenAI-compatible bridge server and its
# agent-side tools (bridge-respond, bridge-key, and the bridge-session
# commands bridge-reply / bridge-next / bridge-close), packaged as a
# Nix derivation.
#
# Install (from the directory containing this file and the sources):
#   nix-env -f api-bridge.nix -i
# State (job queue, token) is NOT part of the package; it lives in
# ~/bridge/ at runtime. The token in particular must never enter the
# store, which is world-readable.
let
  pkgs = import <nixpkgs> { };
in
pkgs.stdenv.mkDerivation {
  pname = "muse-api-bridge";
  version = "0.2.1";
  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  # src is a plain directory, not an archive; skip unpacking and
  # copy from $src. Only the code files are installed; runtime
  # state never enters the package.
  dontUnpack = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec $out/bin
    cp $src/server.py $out/libexec/server.py
    cp $src/bridge-respond $out/bin/bridge-respond
    cp $src/bridge-key $out/bin/bridge-key
    cp $src/bridge-session $out/bin/bridge-reply
    cp $src/bridge-session $out/bin/bridge-next
    cp $src/bridge-session $out/bin/bridge-close
    chmod +x $out/bin/bridge-respond $out/bin/bridge-key \
      $out/bin/bridge-reply $out/bin/bridge-next $out/bin/bridge-close
    makeWrapper ${pkgs.python3}/bin/python3 $out/bin/muse-api-bridge-server \
      --add-flags "$out/libexec/server.py"
    runHook postInstall
  '';

  meta.description = "OpenAI-compatible HTTP bridge to a Muse (job files + hook + side chat)";
}
