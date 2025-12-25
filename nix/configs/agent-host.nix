# Agent host VM configuration (runs microVMs)
{ config, pkgs, self, microvm, ... }:

{
  networking.hostName = "mxc-agent-host";
  networking.interfaces.eth0.ipv4.addresses = [{
    address = "10.0.0.30";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.0.1";
  networking.nameservers = [ "8.8.8.8" "8.8.4.4" ];

  services.mxc.agent = {
    enable = true;
    package = self.packages.x86_64-linux.agent;
    clusterStrategy = "postgres";

    database = {
      host = "10.0.0.10";  # postgres-vm IP
      port = 5432;
      name = "mxc";
      user = "mxc";
      passwordFile = "/run/secrets/db-password";
    };

    erlangCookieFile = "/run/secrets/erlang-cookie";

    hypervisor = "cloud-hypervisor";

    resources = {
      cpuCores = 4;
      memoryMB = 8192;
    };
  };

  # MicroVM host configuration
  microvm.host.enable = true;

  # Bridge network for microVMs
  networking.bridges.br0.interfaces = [];
  networking.interfaces.br0.ipv4.addresses = [{
    address = "10.0.1.1";
    prefixLength = 24;
  }];

  # NAT for microVMs to reach internet
  networking.nat = {
    enable = true;
    internalInterfaces = [ "br0" ];
    externalInterface = "eth0";
  };

  # Enable IP forwarding
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
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
    allowedTCPPorts = [ 22 ];
    trustedInterfaces = [ "br0" ];
  };

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
    cloud-hypervisor
    qemu
  ];

  system.stateVersion = "24.05";
}
