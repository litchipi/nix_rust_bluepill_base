{
  description = "Synthesizer for the STMF103RB";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/22.11";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };


  outputs = inputs: with inputs; flake-utils.lib.eachDefaultSystem (system: let
    pkgs = import nixpkgs {
      inherit system;
      overlays = [
        rust-overlay.overlays.default
      ];
    };
    lib = pkgs.lib;

    target = {
      triple = "thumbv7m-none-eabi";
      flash = {
        start = "0x08000000";
        length = "64K";
      };
      ram = {
        start = "0x20000000";
        length = "20K";
      };
    };

    rustpkg = pkgs.rust-bin.nightly.latest.default.override {
      extensions = [ "rust-src" ];
      targets = [ target.triple ];
    };

    script_wdeps = name: deps: text: let
      exec = pkgs.writeShellApplication {
        inherit name text;
        runtimeInputs = deps ++ [ rustpkg pkgs.pkg-config ];
      };
    in { type = "app"; program = "${exec}/bin/${name}"; };

    memory_script = ''
      MEMORY
      {
        /* NOTE 1 K = 1 KiBi = 1024 bytes */
        FLASH : ORIGIN = ${target.flash.start}, LENGTH = ${target.flash.length}
        RAM : ORIGIN = ${target.ram.start}, LENGTH = ${target.ram.length}
      }
    '';

    bin_name = (lib.trivial.importTOML ./Cargo.toml).package.name;
    build_script = let
      triple_env_var = builtins.replaceStrings ["-"] ["_"] (lib.strings.toUpper target.triple);
      rustflags = builtins.concatStringsSep " " [
        "-C target-feature=+crt-static"
        "-C link-arg=-Tlink.x"
      ];
      toolchain = "${pkgs.gcc-arm-embedded}/bin/arm-none-eabi";
    in ''
      mkdir -p ./build
      export CARGO_BUILD_TARGET="${target.triple}"
      export CARGO_TARGET_${triple_env_var}_LINKER=${toolchain}-ld
      export CARGO_TARGET_DIR=./build

      cat << EOF > memory.x
      ${memory_script}
      EOF

      cargo build --release

      ${toolchain}-objcopy -O binary \
        ./build/${target.triple}/release/${bin_name} \
        ./build/${bin_name}.bin
    '';

    openocd_cmd = "program ./build/${bin_name}.bin verify reset exit";
  in {
    devShells.default = pkgs.mkShell {
      packages = [
        rustpkg
      ];
      shellHook = ''
        build() {
          ${build_script}
        }
        check() {
          cargo-watch -c -x "check --target=${target.triple}"
        }
      '';
    };

    apps = {
      build = script_wdeps "build_bluepill_synth" [] build_script;
      flash = script_wdeps "flash_bluepill" [ pkgs.openocd ] ''
        sudo openocd -f ./openocd.cfg -c "${openocd_cmd}"
      '';
    };
  });
}
