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
#
# ── WHY THE HARDWARE FACTS ARE NOT UNDER `nixhost` ───────────────────────────────────────────
#
# Every level-1 resource -- CPU, RAM total, GPU inventory, interfaces, disks -- is stated below in
# the namespace of the repository that OWNS it, because `nixhost.resources.*` is `readOnly`: it
# mirrors those facts and cannot be set. That is the whole point of this module's level-1 half (see
# `modules/nixhost.nix`'s header): if you want to know what CPU a host has, that lives in exactly
# one spot, and this file would be the second spot.
#
# A real host gets those option paths by importing `nixcpu`, `nixram`, `nixgpu`, `nixnet` and
# `nixstorage` alongside nixhost. This repo takes no flake input on any of them -- deliberately, so
# the dependency only ever points the other way -- so the check that evaluates this file supplies
# the same option surface from `checks/domain-stubs.nix` instead. What you would add to make this a
# real configuration is the imports, not the facts.
{ ... }:
{
  # ── Level 1, stated at each fact's owner. nixhost mirrors all of it, read-only. ────────────
  nixcpu = {
    arch = "x86_64";
    microarch = "x86_64-v3";
    cores = 16;
    threads = 32;
    scheduler = "bore";
    # `coreTypes` left unset: every core on this fictional host is interchangeable, which is the
    # ordinary case and a real answer rather than a gap.
  };

  nixram.hardware.totalMiB = 65536;

  nixgpu.stableDevicePaths.devices.gpu0 = {
    vendor = "amd";
    pciId = "0x1002";
    vramMiB = 16384;
  };

  nixnet.interfaces.lan0 = {
    mac = "aa:bb:cc:dd:ee:ff";
    addresses.lan = "192.0.2.10";
  };

  nixhost = {
    name = "example-gpu-node";

    stance = {
      backend = "nixos";
      flavour = null;
      provider = "metal";
    };

    # Two environments standing on this same host, sharing the one card declared above by
    # name -- neither claims "exclusive", so both co-resident "shared" claims are consistent.
    # Their RAM and CPU claims are what make the mirrored ceilings load-bearing here: remove the
    # `nixram.hardware.totalMiB` above and this file no longer evaluates, because the
    # oversubscription check would otherwise have nothing to compare 8192 + 49152 against.
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
