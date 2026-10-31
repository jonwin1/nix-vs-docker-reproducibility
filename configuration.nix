{ config, lib, pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/vda";

  networking.hostName = "sc-experiment";
  networking.networkmanager.enable = true;
  networking.firewall.enable = false;

  time.timeZone = "Europe/Stockholm";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "sv-latin1";

  users.users.sc = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    initialPassword = "sc";
  };

  environment.systemPackages = with pkgs; [
    git
    gnumake
    trivy
    vim
  ];

  services.openssh.enable = true;
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
 
  programs.direnv.enable = true;

  system.stateVersion = "25.05";
}

