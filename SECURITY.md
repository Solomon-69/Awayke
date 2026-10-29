# Security Policy

Awayke asks for a narrow piece of root privilege, so it owes you a precise account
of what that privilege is and why it is safe. This document is that account. Nothing
here is hand-waved; every claim is something you can verify on your own machine.

## Reporting a vulnerability

If you find a security issue, please **do not open a public issue**. Report it privately
through GitHub: open the repository's **Security** tab and choose **Report a
vulnerability**. Include details and steps to reproduce. Coordinated disclosure is
appreciated.

Supported version: the latest release on the `main` branch.

Awayke is a fork of [Sleepless](https://github.com/Aboudjem/Sleepless) by Adam Boudjemaa.
The security design described here is his, and Awayke keeps it unchanged. If an issue also
affects the original Sleepless, please report it to that project as well.

## What Awayke actually does

Awayke keeps a Mac awake with the lid closed by toggling an undocumented but
long-standing `pmset` setting:

```
sudo pmset -a disablesleep 1   # keep awake, even lid-closed
sudo pmset -a disablesleep 0   # restore normal sleep
```

`disablesleep` is **not** in Apple's `pmset(1)` man page (check: `man pmset`), but it
sets the kernel's `SleepDisabled` flag, which you can observe yourself:

```
pmset -g | grep SleepDisabled   # 1 = on, 0/absent = off
```

Because it is undocumented, Apple could change or remove it in a future macOS. Awayke
reads the live value back after every toggle, so the menu-bar state always reflects
reality rather than assuming the command worked.

## The passwordless grant: exactly what it permits

A GUI app has no terminal to type a password into, so Awayke runs `pmset` through a
tightly scoped `/etc/sudoers.d` drop-in. It is installed once, either by the app itself
(the first time you switch it on, through the standard macOS Touch ID or password prompt,
which runs the bundled `grant.sh`) or by `install.sh`. Both write this (with your username
substituted for `__USER__`), owned `root:wheel`, mode `0440`:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1
```

**This grant lets one user run, as root, exactly two fully-specified commands and nothing
else.** sudoers matches command arguments *literally*, and this rule contains **no
wildcards**, so the match is total. From the sudoers manual: *"If a Cmnd has associated
command line arguments, then the arguments in the Cmnd must match exactly those given by
the user on the command line (or match the wildcards if there are any)."*

Consequences you can rely on:

- `sudo pmset -a sleep 0`, `sudo pmset restoredefaults`, `sudo pmset -a hibernatemode 0`,
  or any other argument vector **do not match** the rule and will demand a password. The
  grant cannot be widened by appending flags.
- Awayke calls `sudo` with an **argv array**, not a shell string
  (`Process.arguments` in `App.swift`), so there is no `/bin/sh -c`, no command
  substitution, and no word-splitting surface inside the app.
- There is **no helper script**. The classic sudoers footgun is a *user-writable* script
  that root executes (rewrite it, get root). Awayke points the rule directly at Apple's
  `/usr/bin/pmset`, and the sudoers file itself is `root:wheel 0440` (you cannot modify it
  without `sudo`). Both mitigations are exactly what the literature prescribes.

## Honest residual risk

The grant is passwordless **by design**: any process already running as your user can flip
the sleep flag silently. We are not pretending the attack surface is zero. But the worst
case is *"your Mac was kept awake, or allowed to sleep."* It is **not** data exfiltration
and **not** root code execution. The two pinned arguments to one Apple binary do not
provide either.

If that trade is not acceptable to you, build from source, decline the one-time setup and
**don't** run `install.sh`; you can toggle `sudo pmset -a disablesleep 1/0` manually instead and skip the grant.

## Reboot resets it (you can verify it)

`disablesleep` is a **runtime** setting. A reboot restores normal sleep, so there is no way
for Awayke to leave your Mac permanently unable to sleep. Verify it yourself: toggle on,
reboot, then `pmset -g | grep SleepDisabled` should read `0`.

Awayke also offers an optional **battery-floor auto-off** (off by default since 1.5; level 5 to
50%) that flips the flag back to `0` while the Mac is awake and discharging, so a forgotten
"on" state can't drain the battery to empty.

Since 1.5, apps Awayke pauses with the lid closed are written down before they are paused and
resumed when the lid opens, when Awayke switches off or quits, by the crash watchdog, and at the
next start. A process is only resumed if its start time still matches, so a reused process number
is never touched.

## Code signing, notarization, and Gatekeeper

Awayke is **ad-hoc signed and not notarized**, because it has no paid Apple Developer ID. The
trust model is *read the source, build it yourself*. (Notarization is also not a malware
guarantee: signed, notarized macOS stealers have shipped.)

- **Build from source (recommended):** locally compiled apps are **not quarantined**, so
  Gatekeeper does not prompt. It just runs.
- **Download the prebuilt `.app`:** a release zip carries `com.apple.quarantine`, so
  Gatekeeper asks before the first launch. Right-click the app and choose **Open**; if
  macOS does not offer an Open button (macOS 15 and later removed that shortcut), approve
  it via **System Settings > Privacy & Security > Open Anyway**, then confirm.

## Why Awayke can't be on the Mac App Store

Some people trust App Store apps more, so it is worth saying plainly: Awayke can never
ship there, and that is a property of what it does, not an oversight.

App Review **§2.4.5(v)** states apps "may not request escalation to root privileges or use
setuid attributes." The passwordless root `pmset` toggle is exactly that, so it is the
decisive block. Two more rules independently rule it out: **§2.4.5(i)** (apps must be
sandboxed, and the sandbox has no entitlement for root or arbitrary system-file writes) and
**§2.5.2 / §2.4.5(ii)** (apps must be self-contained in their bundle and may not write
outside their container, which the `/etc/sudoers.d` drop-in does). A privileged-helper
workaround does not rescue it either: a helper installed from a sandboxed app must itself be
sandboxed, so it still cannot write `/etc/sudoers.d` or run arbitrary root commands.

The practical consequence: Awayke is **direct-download only**, by design. The
verification steps below, plus building from source, are how trust is established instead.

## Verifying a download

If you grab a prebuilt release instead of building it, you can confirm it is genuinely this
project's build, with no Apple account and no shared secret:

```sh
shasum -a 256 -c SHA256SUMS                                  # bytes match what was published
gh attestation verify Awayke-<version>.zip -R Solomon-69/Awayke   # built by this repo's release workflow
```

The full walkthrough (what each check proves, how to reproduce the build, and a VirusTotal
scan) is in **[docs/AUDIT.md](docs/AUDIT.md)**.

## Completely removing the privilege

`./uninstall.sh` (also bundled at `Awayke.app/Contents/Resources/uninstall.sh`) restores normal sleep, removes the app and login item, deletes the
sudoers drop-in, and then **proves** revocation by showing that `sudo -n pmset …` prompts
for a password again. The single file to audit or delete by hand is
`/etc/sudoers.d/sleepless-disablesleep` (the name is kept from Sleepless so existing
installs keep working).

## Primary sources

- Apple `pmset(1)` man page (no `disablesleep`): https://keith.github.io/xcode-man-pages/pmset.1.html
- sudoers manual (exact-arg match, includedir filename rules): https://www.sudo.ws/docs/man/1.9.0/sudoers.man/
- Passwordless sudo for programs (scope / root-own / revoke): https://jozefcipa.com/blog/how-to-use-sudo-without-a-password-in-your-programs/
- Apple: Safely open apps / Open Anyway flow: https://support.apple.com/en-us/102445
- Apple Developer: Sequoia removes Control-click Gatekeeper bypass: https://developer.apple.com/news/?id=saqachfa
- Living without notarization (ad-hoc + quarantine behavior): https://eclecticlight.co/2024/10/01/living-without-notarization/
- App Store Review Guidelines (§2.4.5 root escalation, sandbox, self-contained): https://developer.apple.com/app-store/review/guidelines/
- GitHub artifact attestations (build provenance, SLSA): https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds
