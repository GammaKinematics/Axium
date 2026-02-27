{ pkgs }:
{
  sources = [ ./sodium.odin ./proto.odin ./keepass.odin ];
  buildInputs = [ pkgs.libsodium ];
  linkFlags = "-lsodium";
}
