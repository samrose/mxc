# Coordinator VM configuration
{ config, pkgs, self, ... }:

{
  imports = [];

  networking.hostName = "mxc-coordinator";
  networking.interfaces.eth0.ipv4.addresses = [{
    address = "10.0.0.20";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.0.1";
  networking.nameservers = [ "8.8.8.8" "8.8.4.4" ];

  services.mxc.coordinator = {
    enable = true;
    package = self.packages.x86_64-linux.coordinator;
    port = 4000;
    uiEnabled = true;
    clusterStrategy = "postgres";
    schedulerStrategy = "spread";

    database = {
      host = "10.0.0.10";  # postgres-vm IP
      port = 5432;
      name = "mxc";
      user = "mxc";
      passwordFile = "/run/secrets/db-password";
    };

    erlangCookieFile = "/run/secrets/erlang-cookie";
    secretKeyBaseFile = "/run/secrets/secret-key-base";
  };

  # Basic system configuration
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Enable SSH for remote access
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Basic firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 4000 ];
  };

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
  ];

  system.stateVersion = "24.05";
}
