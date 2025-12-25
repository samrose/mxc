# Base microVM configuration
# Can be used standalone for testing or with Mxc agent for production
{ self, pkgs, lib, config, nixpkgs, ... }:

{
  # MicroVM hypervisor configuration
  microvm = {
    # Use qemu for broader compatibility
    hypervisor = "qemu";

    vcpu = 2;
    mem = 512;

    # Shared /nix/store from host - use 9p for qemu compatibility
    shares = [{
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "9p";
    }];

    # Network interface with user-mode networking (no root required)
    interfaces = [{
      type = "user";
      id = "qemu";
      mac = "02:00:00:01:01:01";
    }];

    # Port forwarding for SSH access
    forwardPorts = [{
      host.port = 2222;
      guest.port = 22;
    }];
  };

  # NixOS configuration for the microVM
  networking.hostName = lib.mkDefault "mxc-vm";
  networking.useDHCP = lib.mkDefault true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # Auto-login for easy console access
  services.getty.autologinUser = "root";

  # SSH for remote access
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  # Set a simple root password for testing (change in production!)
  users.users.root.initialPassword = "mxc";

  # Basic packages for debugging
  environment.systemPackages = with pkgs; [
    htop
    curl
    jq
  ];

  # Disable unnecessary services for faster boot
  documentation.enable = false;
  services.udisks2.enable = false;

  system.stateVersion = "24.05";
}
