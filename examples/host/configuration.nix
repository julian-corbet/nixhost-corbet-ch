# A generic single-GPU host, used by the `example/modules-evaluate` check.
#
# This is not a real machine -- see the repo README for why a public schema ships with an
# invented example instead of one operator's actual inventory. The name, addresses, and every
# quantity below are fictional, chosen only to exercise the module's real shape:
#
#   - a GPU with TWO consumers: a bare-metal podman workload and a k3s node standing on the
#     SAME host, each with its own stance on the SAME named device (`gpu0`) -- the concrete
#     shape of "a GPU has two parents" the README's graph section describes;
#   - environment RAM/CPU claims that fit comfortably under the host total, so the
#     oversubscription assertions stay silent, exactly as they should for a well-formed host;
#   - a `flavour`/`provider` pair shown as free-form strings, not a fixed catalogue.
{ ... }:
{
  nixhost = {
    name = "example-gpu-node";

    stance = {
      backend = "nixos";
      flavour = null;
      provider = "metal";
    };

    resources = {
      cpu = {
        arch = "x86_64";
        microarch = "x86_64-v3";
        cores = 16;
        threads = 32;
        scheduler = "bore";
      };

      ram.totalMiB = 65536;

      gpu.gpu0 = {
        vendor = "amd";
        pciId = "0x1002";
        vramMiB = 16384;
      };

      net.lan0 = {
        mac = "aa:bb:cc:dd:ee:ff";
        addresses.lan = "192.0.2.10";
      };
    };

    # Two environments standing on this same host, sharing the one card declared above by
    # name -- neither claims "exclusive", so both co-resident "shared" claims are consistent.
    environments = {
      desktop-workload = {
        kind = "podman";
        resources = {
          ram.limitMiB = 8192;
          cpu.quotaCores = 4;
          gpu.gpu0.access = "shared";
        };
      };

      cluster-node = {
        kind = "k3s";
        resources = {
          ram.limitMiB = 49152;
          cpu.quotaCores = 10;
          gpu.gpu0.access = "shared";
        };
      };
    };
  };

  # ── Stubs NixOS demands of any bootable system ───────────────────────────
  # tmpfs on / could never boot a real machine, which is the point: this exists to type-check
  # the module against a real evaluation, not to describe hardware.
  fileSystems."/" = {
    device = "nodev";
    fsType = "tmpfs";
  };

  boot.loader.grub = {
    enable = true;
    devices = [ "nodev" ];
  };

  networking.hostName = "example-gpu-node";
  system.stateVersion = "25.05";
}
