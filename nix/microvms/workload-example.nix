# Example workload microVM
# Shows how to create a specialized workload VM with nginx
{ self, pkgs, lib, config, ... }:

{
  # Override base configuration
  microvm = {
    vcpu = 4;
    mem = 1024;  # 1GB
  };

  networking.hostName = "mxc-workload";

  # Example: Run nginx as a workload
  services.nginx = {
    enable = true;
    virtualHosts."default" = {
      root = "/var/www";
      locations."/" = {
        extraConfig = ''
          autoindex on;
        '';
      };
    };
  };

  # Create sample content
  systemd.tmpfiles.rules = [
    "d /var/www 0755 nginx nginx -"
    "f /var/www/index.html 0644 nginx nginx - '<h1>Mxc Workload Example</h1>'"
  ];

  # Open port 80
  networking.firewall.allowedTCPPorts = [ 80 ];
}
