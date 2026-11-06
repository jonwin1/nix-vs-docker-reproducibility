{ pkgs, ... }:
{
  users.users.user = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "user";
  };

  environment.systemPackages = with pkgs; [
    git
    gnumake
    python3
    vim
  ];

  security.sudo.wheelNeedsPassword = false;

  virtualisation.docker = {
    enable = true;
    rootless = {
      enable = true;
      setSocketVariable = true;
    };
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  virtualisation.vmVariant = {
    virtualisation = {
      memorySize = 16384;
      cores = 6;
      diskImage = null;

      sharedDirectories.experiment = {
        source = builtins.getEnv "PWD";
        target = "/home/user/experiment";
      };
    };
  };

  system.stateVersion = "25.05";
}
