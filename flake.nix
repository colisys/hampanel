{
  description = "Hampanel — CleanRoom server panel (Zig daemon + Flutter client)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in {
      packages = forAll (pkgs:
        let
          zig = pkgs.zig_0_17 or pkgs.zig;
        in {
          default = pkgs.stdenv.mkDerivation {
            pname = "hampaneld";
            version = "0.1.0";
            src = self;
            nativeBuildInputs = [ zig pkgs.pkg-config ];
            buildInputs = [ pkgs.openssl ];
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              export HOME=$TMPDIR
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global
              export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local
              cd daemon
              zig build -Doptimize=ReleaseSafe -Dcommit=${self.shortRev or "unknown"} \
                -Dopenssl-include=${pkgs.openssl.dev}/include \
                -Dopenssl-lib-dir=${pkgs.openssl.out}/lib \
                --prefix $out
              runHook postBuild
            '';
            dontInstall = true;
          };
        });
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [
            (pkgs.zig_0_17 or pkgs.zig)
            pkgs.openssl
            pkgs.pkg-config
            pkgs.git
            pkgs.docker-client
          ];
        };
      });
      apps = forAll (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.default}/bin/hampaneld";
        };
      });
    };
}
