{
  description = "open-jai (community Jai compiler) packaged with Nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    open-jai = {
      url = "github:withlang-dev/open-jai";
      flake = false;
    };
  };

  outputs =
    inputs@{ self, ... }:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.devshell.flakeModule ];

      systems = [ "x86_64-linux" ];

      perSystem =
        { pkgs, lib, ... }:
        let
          llvm = pkgs.llvmPackages_latest;
          cxxlib = pkgs.stdenv.cc.cc.lib;

          openjai = pkgs.stdenv.mkDerivation {
            pname = "openjai";
            version = "0-unstable-2026-06-01";

            src = inputs.open-jai;

            # The bootstrap is wired to a macOS/Homebrew toolchain: it includes
            # <ffi/ffi.h> (nixpkgs ships ffi.h at the top of libffi's include dir)
            # and names its output "openjai-macos". The patch makes the include
            # portable, reads the libffi include dir from $OPENJAI_FFI_INCLUDE
            # (zig's @cImport ignores CPATH), and names the binary "openjai".
            patches = [ ./open-jai-linux.patch ];

            nativeBuildInputs = [
              pkgs.zig
              llvm.clang
              llvm.lld
              pkgs.makeWrapper
            ];
            buildInputs = [
              llvm.llvm
              pkgs.libffi
            ];

            env = {
              LLVM_CONFIG = "${llvm.llvm.dev}/bin/llvm-config";
              OPENJAI_CXX = "${llvm.clang}/bin/clang++";
              OPENJAI_FFI_INCLUDE = "${pkgs.libffi.dev}/include";
              LIBRARY_PATH = "${pkgs.libffi}/lib";
            };

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild
              export HOME=$TMPDIR
              zig build --build-file bootstrap/build.zig \
                -Dllvm-config="$LLVM_CONFIG" \
                -Dcxx="$OPENJAI_CXX" \
                --cache-dir "$TMPDIR/zig-cache" \
                --global-cache-dir "$TMPDIR/zig-global" \
                --prefix "$TMPDIR/install"
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin $out/lib $out/libexec $out/share/openjai
              cp "$TMPDIR/install/lib/"* $out/lib/
              cp "$TMPDIR/install/bin/openjai" $out/libexec/openjai
              cp -r modules $out/share/openjai/modules

              # The compiler shells out to `cc` to link the final executable and
              # resolves #import against a modules dir; pin both so it works from
              # any cwd, and auto-supply the runtime object so plain `openjai
              # foo.jai -o foo` just works.
              makeWrapper $out/libexec/openjai $out/bin/openjai \
                --prefix PATH : "${lib.makeBinPath [ llvm.clang llvm.lld ]}" \
                --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ pkgs.libffi llvm.llvm.lib cxxlib ]}" \
                --append-flags "-import_dir $out/share/openjai/modules" \
                --append-flags "--runtime $out/lib/openjai_runtime.o"
              ln -s openjai $out/bin/jai
              runHook postInstall
            '';

            meta = {
              description = "Community open-source bootstrap compiler for the Jai language";
              homepage = "https://github.com/withlang-dev/open-jai";
              license = lib.licenses.mit;
              platforms = [ "x86_64-linux" ];
              mainProgram = "openjai";
            };
          };
        in
        {
          packages.default = openjai;
          packages.openjai = openjai;

          devshells.default = {
            packages = [
              openjai
              pkgs.tokei
            ];
          };
        };
    };

  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org?priority=1"
      "https://numtide.cachix.org?priority=2"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
    ];
  };
}
