{
  description = "Synthesizer for the STMF103RB";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.11";
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
      rom = {
        start = "0x08000000";
        length = "128K";
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

    bin_name = (lib.trivial.importTOML ./Cargo.toml).package.name;
    cc = pkgs.gcc-arm-embedded;
    toolchain = "${cc}/bin/arm-none-eabi";

    build_script = let
      triple_env_var = builtins.replaceStrings ["-"] ["_"] (lib.strings.toUpper target.triple);
      linker_flags = [
        "-Wl,-Tlink.x"
        "-nostartfiles"
      ];
      rustflags = builtins.concatStringsSep " " ([
        "-C target-feature=+crt-static"
        "-C linker=${toolchain}-gcc"
      ] ++ (builtins.map (arg: "-C link-arg=${arg}") linker_flags));
    in ''
      mkdir -p ./build
      export CARGO_BUILD_TARGET="${target.triple}"
      export CARGO_TARGET_DIR=./build
      export RUSTFLAGS="${rustflags}"

      rm -f ./memory.x
      cat << EOF > memory.x
      MEMORY
      {
        FLASH : ORIGIN = ${target.rom.start}, LENGTH = ${target.rom.length}
        RAM : ORIGIN = ${target.ram.start}, LENGTH = ${target.ram.length}
      }
      EOF

      cargo build --release
    '';

    flash_script = ''
      rm -f ./build/${bin_name}*

      ${toolchain}-objcopy -O binary \
        ./build/${target.triple}/release/${bin_name} \
        ./build/${bin_name}.bin

      sudo ${pkgs.stlink}/bin/st-flash write ./build/${bin_name}.bin 0x8000000
      echo "OK"
    '';
  in {
    devShells.default = pkgs.mkShell {
      packages = [
        rustpkg
        cc
      ];
      shellHook = ''
        build() {
          ${build_script}
        }
        check() {
          cargo-watch -c -x "check --target=${target.triple}"
        }
        flash() {
          ${flash_script}
        }
      '';
    };

    apps = {
      build = script_wdeps "build_bluepill" [] build_script;
      flash = script_wdeps "flash_bluepill" [] flash_script;
    };
  });
}
