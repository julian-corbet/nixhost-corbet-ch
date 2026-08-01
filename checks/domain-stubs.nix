# checks/domain-stubs.nix
#
# THE OPTION SURFACES nixhost MIRRORS, declared here and nowhere else in this repo.
#
# Every level-1 resource in `modules/nixhost.nix` is a `readOnly` mirror whose default is a
# defensive read of the repository that owns the fact -- `nixcpu`, `nixram`, `nixgpu`, `nixnet`,
# `nixstorage`, `nixaudio`. Testing those mirrors needs those option paths to EXIST during a check,
# and this repo deliberately cannot get them the obvious way: nixhost takes no flake input on any of
# the six (see the module's own header), because the whole point of a defensive read is that the
# dependency only ever points this way, weakly, and a domain repo stays usable by someone who has
# never heard of nixhost. Adding six checks-only inputs would put six flake inputs on a repo whose
# central claim is that it needs none, and would tie this repo's CI to six other repos' revisions.
#
# So the checks supply the surface themselves. What this file has to be faithful about is not the
# domains' BEHAVIOUR -- none of their assertions, generators or units are here, and none are
# exercised -- but their SHAPE at exactly the paths the mirrors read, including which fields have no
# default:
#
#   `nixcpu.arch`/`cores`/`threads` have NO default upstream, and that is not a detail to smooth
#   over. It is what makes the harder absence testable at all: "domain imported, fact never stated"
#   reaches nixhost's mirror as a value the module system aborts on, which is a different ROUTE from
#   "domain not imported", where the defensive `or` simply finds no attribute -- and `lib.probeFact`
#   (`../lib/facts.nix`), which every level-1 mirror in `modules/nixhost.nix` reads through, exists
#   to give both routes the same answer. Tests for the second route evaluate WITHOUT this file (see
#   `nixosBuildFailsBare` in default.nix); a stub that handed these fields a default would leave the
#   first route unexercised.
#
# THE DRIFT THIS LEAVES is real and deliberately not papered over: nothing here notices if an
# upstream option is renamed or retyped, so a green check here means "the mirror reads the shape this
# file describes", not "the mirror reads nixcpu". That gap is logged as an open question in
# `experiments/README.md` rather than hidden behind a passing test.
{ lib }:

{
  options = {
    # nixcpu -- modules/nixcpu.nix. `microarch` is a closed enum upstream (its own
    # lib/catalogue.nix keys) and `coreTypes` a two-group submodule; both are widened here, since
    # what is under test is nixhost's read of the path, never nixcpu's own validation of the value.
    nixcpu = {
      arch = lib.mkOption {
        type = lib.types.enum [ "x86_64" "aarch64" ];
        description = "Stub of nixcpu.arch. No default, exactly as upstream.";
      };
      microarch = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Stub of nixcpu.microarch.";
      };
      cores = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Stub of nixcpu.cores. No default, exactly as upstream -- see this file's header.";
      };
      threads = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Stub of nixcpu.threads. No default, exactly as upstream.";
      };
      coreTypes = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        default = null;
        description = "Stub of nixcpu.coreTypes.";
      };
      scheduler = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Stub of nixcpu.scheduler.";
      };
    };

    # nixram -- modules/default.nix. A FACT under `hardware.`, kept away from nixram's own policy
    # tree on purpose; optional there, because nixram's own tuning never divides against it.
    nixram.hardware.totalMiB = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Stub of nixram.hardware.totalMiB.";
    };

    # nixgpu -- modules/stable-device-paths/options.nix. Upstream is an attrsOf submodule with
    # required vendor/pciId/vramMiB; nixhost mirrors it opaquely, so the stub is opaque too.
    nixgpu.stableDevicePaths.devices = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Stub of nixgpu.stableDevicePaths.devices.";
    };

    # nixnet -- modules/core.nix. Note the path: `interfaces`, not `resources.net`. A mirror reads
    # the owner at the owner's own address.
    nixnet.interfaces = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Stub of nixnet.interfaces.";
    };

    # nixstorage -- modules/disks.nix. The oldest of the five original mirrors, and until now the
    # only one this repo's checks could not exercise against a populated table at all
    # (experiments/ 003).
    nixstorage.disks = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Stub of nixstorage.disks.";
    };

    # nixaudio -- fabric module (sink catalogue). Upstream entries carry
    # origin/peer/device/description/known; nixhost mirrors the table opaquely (see
    # `resources.audio`'s own description for why), so the stub is opaque too, matching nixgpu's.
    nixaudio.fabric.catalogue = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Stub of nixaudio.fabric.catalogue.";
    };
  };
}
