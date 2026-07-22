{
  description = "Atlas is a simple package cloner tool. It manages an isolated project.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nim2nix.url = "github:daylinmorgan/nim2nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nim2nix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ nim2nix.overlays.default ];
        };
        version = "0.14.5";
      in
      {
        packages.default = pkgs.buildNimblePackage {
          pname = "atlas";
          version = version;
          src = ./.;

          buildInputs = with pkgs; [
            openssl
          ];

          nativeBuildInputs = with pkgs; [
            pkg-config
          ];

          nimbleLockFile = ./nimble.lock;
          nimbleDepsHash = "sha256-f+YwcZDaINXG3O8v877jjkM6RHYKc4nllJAv9nxplLw=";

          nimFlags = [
            "--define:release"
            "--opt:speed"
            "--define:lto"
            "--define:NimblePkgVersion=${version}"
          ];

          meta = with pkgs.lib; {
            description = "Atlas is a simple package cloner tool. It manages an isolated project.";
            platforms = platforms.unix;
            license = licenses.mit;
          };

          doCheck = false;
        };

        devShells.default = pkgs.mkShell {
          buildInputs =
            self.packages.${system}.default.buildInputs
            ++ (with pkgs; [
              nim
              nimble
              pkg-config
            ]);
        };
      }
    );
}
