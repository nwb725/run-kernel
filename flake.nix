{
  description = "Tool for running kernel images";
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-24.11";
    systems.url = "github:nix-systems/default";
    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    claudebox.url = "github:numtide/claudebox";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = inputs:
    with inputs;
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ rust-overlay.overlays.default ];
        pkgs = import nixpkgs { inherit system overlays; };
        toolchainStatic = pkgs.rust-bin.stable.latest.minimal.override {
          targets = [ "x86_64-unknown-linux-musl" ];
        };
        rustPlatformStatic = pkgs.makeRustPlatform {
          cargo = toolchainStatic;
          rustc = toolchainStatic;
        };
        runtimeDeps = [
          pkgs.qemu # qemu-system-<arch>, spawned to run the kernel
          pkgs.virtiofsd # backs the virtiofs shares exposed to the guest
          pkgs.util-linux # `unshare`, used to enter a user+mount ns for virtiofsd
          pkgs.nix # `nix build` evaluates the NixOS config for the guest
          pkgs.openssh # `ssh` client used to ping and shut down the guest
        ];
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.gnumake
            pkgs.pkg-config
            pkgs.rust-bin.stable.latest.complete
            llm-agents.packages.${system}.claude-code
            claudebox.packages.${system}.claudebox
          ] ++ runtimeDeps;
          # Expose the NixOS setuid wrappers (newuidmap/newgidmap) so that
          # `cargo run` -invoked `unshare --map-auto` can find them. A pure
          # devshell scrubs them from PATH otherwise.
          shellHook = ''
            export PATH="$PATH:/run/wrappers/bin"
          '';
        };
        packages.default = let
          runKernelInit = rustPlatformStatic.buildRustPackage {
            pname = "run-kernel-init";
            version = "0.1.0";
            src = ./init;
            cargoLock = { lockFile = ./init/Cargo.lock; };
            doCheck = false;
            nativeBuildInputs = [ pkgs.gnumake pkgs.pkg-config pkgs.perl ];
            buildPhase = ''
              cargo build --target x86_64-unknown-linux-musl --release
            '';
            installPhase = ''
              mkdir -p $out/bin
              cp target/x86_64-unknown-linux-musl/release/init $out/bin/init
            '';
          };
        in pkgs.rustPlatform.buildRustPackage {
          pname = "run-kernel";
          version = "0.1.0";
          src = ./.;
          #buildType = "debug";
          #dontStrip = true;
          cargoLock = { lockFile = ./Cargo.lock; };
          doCheck = false;
          nativeBuildInputs =
            [ pkgs.gnumake pkgs.pkg-config pkgs.perl pkgs.makeWrapper ];
          postInstall = ''
            # /run/wrappers/bin hosts NixOS's setuid newuidmap/newgidmap, which
            # `unshare --map-auto` execvp's by name. A pure `nix develop` shell
            # doesn't keep it on PATH, so suffix it here: the wrapper has to
            # contribute it, but must NOT override any host-provided path.
            wrapProgram $out/bin/run-kernel \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps} \
              --suffix PATH : /run/wrappers/bin
          '';
          RUN_KERNEL_INIT_PATH = runKernelInit + /bin/init;
        };
      });
}
