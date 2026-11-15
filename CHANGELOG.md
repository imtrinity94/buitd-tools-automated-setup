# Changelog

All notable changes to the setup scripts, newest first.

## 1.1.0 – 2026-11-15

### Added
- `uninstall` command on macOS (`./bt-setup.sh uninstall`) and Windows (`.\bt-setup.ps1 uninstall`), plus
  double-click launchers `mac/bt-uninstall.command` and `windows/bt-uninstall.cmd`.
  - Shows the full plan (what is removed and what is kept) and asks once before changing anything;
    `--dry-run` / `-DryRun` only shows the plan, `--yes` / `-Yes` skips the question.
  - Backs up the signing certificate, profiles and Maven settings first (`--no-backup` / `-NoBackup` to skip).
  - Puts back the `settings.xml` you had before the first install, and a user `JAVA_HOME` you had before (Windows).
  - Never touches your projects (`~/BuildTools`).
  - Removes JDK / Node / OpenSSL (Homebrew), Git and VS Code only with `--remove-shared` / `-RemoveShared`,
    and only when this script installed them. On macOS, a Homebrew package that another installed package
    still needs is kept.
  - Refuses to run while something is still running from `.buildtools`. If one step fails, it carries on
    with the others and reports what failed at the end.
- `install` now writes an install record (`~/.buildtools/install-manifest`, Windows: `install-manifest.txt`)
  of what it created, so `uninstall` can tell the script's own changes from what was already there.

### Changed
- macOS: `~/.zprofile` is written in place, so a symlinked `~/.zprofile` (dotfile managers) stays a symlink.
- Windows: the user `PATH` is read and written without expanding `%VARIABLES%`, so entries such as
  `%USERPROFILE%\AppData\Local\Microsoft\WindowsApps` keep their original form.

## 1.0.0 – 2026-11-01

### Added
- Windows setup script (`windows/bt-setup.ps1`): user-space JDK 21, Node 22 and Maven 3.9.16 (checksum
  verified), DPAPI-protected credentials, `selftest`, `doctor`.
- Getting-started guide and README with social preview.

### Fixed
- Windows: downloads no longer go through `%TEMP%`, which can be an 8.3 short path that `Remove-Item` fails on.
- `new-project` writes `vrdev.maven.profile` to the project's `.vscode/settings.json`, so the VS Code
  extension finds its Maven profile.
- VM Apps projects push with `vrealize:push` (there is no `vra-ng:push`).

## 0.1.0 – 2026-10-31

### Added
- macOS setup script (`mac/bt-setup.sh`): Homebrew JDK / Node / OpenSSL, pinned Maven 3.9.16, VS Code
  extension, signing certificate, Maven settings, connection profiles for Aria Automation 8 and
  VCF Automation 9.
