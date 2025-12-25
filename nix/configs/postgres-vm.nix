# PostgreSQL VM configuration
{ config, pkgs, self, ... }:

{
  networking.hostName = "mxc-postgres";
  networking.interfaces.eth0.ipv4.addresses = [{
    address = "10.0.0.10";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.0.1";
  networking.nameservers = [ "8.8.8.8" "8.8.4.4" ];

  services.mxc.postgres = {
    enable = true;
    port = 5432;
    databases = [ "mxc" ];

    users = {
      mxc = {
        passwordFile = "/run/secrets/mxc-db-password";
        databases = [ "mxc" ];
      };
    };

    # Allow coordinator and agents to connect
    allowedNetworks = [
      "10.0.0.0/24"  # Internal network
    ];
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
    allowedTCPPorts = [ 22 5432 ];
  };

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
  ];

  system.stateVersion = "24.05";
}
