# Desktop fleet guardrails

## Ubuntu authentication ownership

Ubuntu owns PAM policy, modules, libraries and privileged helpers. Every Ubuntu
lock-screen executable must use the host PAM stack. Keep host libraries scoped
to that executable and preserve the child application's normal loader environment.

Goran uses `fleet/native-pam/` through `fleet/home.nix`, with
`programs.hp-os-fleet.nativePam.enable = true` in its consumer configuration.
Preserve this activation gate and the native package overrides during input
updates, source consolidation and launcher refactors. Dux 2 embeds Quickshell as
`libdux-qt-base.so.0` inside `.dms-wrapped`; standalone Quickshell patches alone leave that executable unchanged.

Validate the exact candidate ELF and its actual runner before activation. Require
a real Ubuntu PAM password conversation, a host PAM mapping in `/proc/PID/maps`,
and an unchanged child loader environment. Missing package metadata or failed
probes stop activation before Home Manager's `writeBoundary`. A helper symlink or
the presence of Ubuntu PAM libraries provides only partial evidence.

Preserve Ubuntu `/etc/pam.d`; do not rewrite it for Nix PAM. Preserve compositors
and application sessions during shell recovery. Record prompt-probe acceptance
separately from a user-confirmed successful unlock. Regression evidence and
maintenance instructions live in `fleet/native-pam/README.md`.
