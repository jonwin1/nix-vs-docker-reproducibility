{
  description = "nixos-compose - raftly";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/26.05";
    nxc.url = "git+https://gitlab.inria.fr/nixos-compose/nixos-compose.git?ref=25.05";
    self.submodules = true;
  };

  outputs =
    {
      self,
      nixpkgs,
      nxc,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      packages.${system} =
        nxc.lib.compose {
          inherit nixpkgs system;
          composition = ./composition.nix;
        }
        // {
          raftly = pkgs.callPackage ./raftly.nix {
            src = ../raftly;
            vendorHash = "sha256-9xWI1wtlm2H/pQIbFeJ0dtqhqJXL4f3OSgi70dXrNys=";
          };
        };

      defaultPackage.${system} = self.packages.${system}."composition::docker";

      devShell.${system} = nxc.devShells.${system}.nxcShell;
    };
}
