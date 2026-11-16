# Ubuntu native PAM activation guard

Enable `programs.hp-os-fleet.nativePam.enable` for Ubuntu ARM64 profiles.
Package every installed lock-capable shell with `package.nix`: standalone
Quickshell for HP-OS and `libdux-qt-base.so.0` before embedding it in Dux 2. The activation gate validates
package metadata, final ELF dependencies, the real Ubuntu password conversation,
and child loader environment before Home Manager writes live files.

Ubuntu owns PAM policy, modules and its privileged helper. Keep native libraries
local to the shell RPATH. Preserve this gate during package and launcher updates.
A prompt probe submits no password; successful interactive unlock is a separate
acceptance step. Preserve compositor and application processes during recovery.

The original November 1 repair was lost during later source consolidation.
The November 16 repair adds a shared activation gate that rejects packages
without native PAM metadata, including newly embedded shell executables.
