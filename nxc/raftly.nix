{
  src,
  vendorHash,
  buildGoModule,
  buildNpmPackage,
}:
let
  ui = buildNpmPackage {
    pname = "raftly-ui";
    version = "0.1.0";
    src = src + "/ui";

    npmDepsHash = "sha256-Rrh5ZnzSBWjlzmjBk4Rk7p0Q423xkju8vaxvxQoC3+8=";

    installPhase = ''
      runHook preInstall
      mkdir -p $out/dist
      cp -r dist/. $out/dist/
      runHook postInstall
    '';
  };
in
buildGoModule {
  pname = "raftly-server";
  version = "0.1.0";

  inherit src vendorHash;

  preBuild = ''
    rm -rf web/dist
    mkdir -p web/dist
    cp -r ${ui}/dist/. web/dist/
  '';

  env.CGO_ENABLED = "0";

  ldflags = [
    "-s"
    "-w"
  ];

  subPackages = [ "cmd/server" ];

  postInstall = ''
    mv "$out/bin/server" "$out/bin/raftly-server"
  '';
}
