{
  lib,
  glibc,
  gnused,
  buildEnv,
  writeClosure,
  writeTextFile,
  runCommand,
}:

let
  inherit (lib.strings) concatStrings concatStringsSep escapeShellArg;
  inherit (lib.attrsets) mapAttrsToList;

  # Generate a bwrap command line arguments given a set OCI-like config parameters.
  mkBwrapRunScript =
    {
      process,
      hostname,
      mounts,
    }:
    let
      bwrapExePath = "bwrap";
      envArgs = mapAttrsToList (k: v: "--setenv ${escapeShellArg k} ${escapeShellArg v}") process.env;
      mountsArgs = mapAttrsToList (
        dst: desc:
        if desc.type == "tmpfs" then
          "--tmpfs ${dst}"
        else if desc.type == "proc" then
          "--proc ${dst}"
        else if desc.type == "bind" then
          "--bind ${desc.source} ${dst}"
        else
          throw "unknown mount type"
      ) mounts;
      cmd = [
        bwrapExePath
        "--as-pid-1"
        "--die-with-parent"
        "--uid ${toString process.user.uid}"
        "--gid ${toString process.user.gid}"
        "--hostname ${hostname}"
        "--unshare-cgroup"
        "--unshare-pid"
        "--unshare-net"
        "--unshare-ipc"
        "--unshare-uts"
        "--unshare-user"
        "--clearenv"
        "--cap-drop ALL"
        "--chdir ${escapeShellArg process.cwd}"
        "--dev-bind /dev /dev"
        "--ro-bind /dev/pts /dev/pts"
        "--ro-bind /sys /sys"
        "--mqueue /dev/mqueue"
      ] ++ mountsArgs ++ envArgs ++ [ (escapeShellArg process.args) ];
    in
    writeTextFile {
      name = "bwrap-run";
      text = ''
        #!/bin/sh
        DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        cd "$DIR"
        ${concatStringsSep " \\\n  " cmd}
      '';
    };

  defaultPathsToLink = ["/bin" "/etc" "/lib" "/lib64" "/opt" "/usr" "/srv" "/sbin" "/share"];

  # Generate a standalone bundle
  mkBundle =
    {
      root,
      process,
      hostname,
      mounts,
    }:
    let
      rootfsLinks = buildEnv {
        name = "rootfs";
        paths = root.paths;
        pathsToLink = root.links or defaultPathsToLink;
      };
      rootfsMounts = lib.attrsets.mapAttrs' (dir: _fileType: {
        name = "/${dir}";
        value = {
          type = "bind";
          source = "rootfs/${dir}";
        };
      }) (builtins.readDir rootfsLinks);
      nixDirMount = {
        "/nix" = {
          type = "bind";
          source = "rootfs/nix";
        };
      };
      bwrapRunScript = mkBwrapRunScript {
        mounts = rootfsMounts // nixDirMount // mounts;
        inherit process hostname;
      };
      nixStoreFiles = writeClosure root.paths;
    in
    runCommand "bundle" { } ''
      mkdir -p $out/rootfs
      tar c -C ${rootfsLinks} . -T ${nixStoreFiles} | tar -xC $out/rootfs/
      cp ${bwrapRunScript} $out/run && chmod +x $out/run
    '';
in
{
  bundle = mkBundle;
}

