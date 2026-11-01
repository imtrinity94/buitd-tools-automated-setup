# Build Tools for VMware Aria / VCF Automation – Windows setup

One PowerShell script that sets up a Windows 10/11 workstation for
[Build Tools for VMware Aria](https://github.com/vmware/build-tools-for-vmware-aria) and pushes vRO
(JavaScript / TypeScript) and VCF Automation VM Apps (vRA) projects. Same commands as the [macOS version](../mac/).

| File | What it is |
|---|---|
| `bt-setup.ps1` | The script: `install`, `add-profile`, `refresh-token`, `new-project`, `selftest`, `doctor` |
| `bt-install.cmd` | Double-click launcher for `install` (logs to `bt-setup.log`) |
| `bt-selftest.cmd` | Double-click: scaffolds a throwaway project, builds and signs it, deletes it |

- Works in **Windows PowerShell 5.1** (built in) and PowerShell 7.
- **No administrator rights needed.** JDK, Node and Maven are downloaded as zips into your profile and
  verified against their published checksums. Only Git and VS Code are installed with `winget`, per-user, if missing.
- Everything is re-runnable – steps that are already done are skipped.

---

> After installing, continue with **[Getting started](../docs/getting-started.md)**: VS Code setup, your first push, all project types and where to find pushed content.

## 1. Install the toolchain

```powershell
git clone https://github.com/imtrinity94/buitd-tools-automated-setup.git
cd buitd-tools-automated-setup\windows
powershell -ExecutionPolicy Bypass -File .\bt-setup.ps1 install
```

No Git yet? Download the repo as a ZIP from GitHub, extract it, and double-click `windows\bt-install.cmd`.

What `install` does:

| Step | Result |
|---|---|
| Git for Windows | Needed for `openssl.exe` (signing cert). Installed with `winget --scope user` if missing |
| JDK | **Temurin 21** zip from Adoptium, SHA-256 verified → `%USERPROFILE%\.buildtools\tools\jdk-21…` |
| Node.js | **Node 22** zip from nodejs.org, SHA-256 verified → `…\tools\node-v22…` |
| Maven | **3.9.16** zip from apache.org, SHA-512 verified → `…\tools\apache-maven-3.9.16` (Build Tools supports 3.9.x) |
| Environment | User variables: `JAVA_HOME`, and Maven / JDK / Node first on the user `PATH` |
| VS Code | Installed per-user with winget if missing; extension `vmware-pscoe.vrealize-developer-tools`; `vrdev.buildTools.defaultVersion` = latest Build Tools on Maven Central |
| Signing | Self-signed package-signing cert in `%USERPROFILE%\.buildtools\certs`; key password DPAPI-encrypted in `packaging.json` |
| Maven | `%USERPROFILE%\.m2\settings-security.xml` (random master password) and `settings.xml` with the `packaging` profile |

Open a **new** terminal afterwards so `JAVA_HOME` / `PATH` apply, then:

```powershell
.\bt-setup.ps1 doctor
.\bt-setup.ps1 selftest      # or double-click bt-selftest.cmd – expect "Self-test passed - BUILD SUCCESS"
```

> If PowerShell refuses to run the script ("running scripts is disabled"), either always start it with
> `powershell -ExecutionPolicy Bypass -File .\bt-setup.ps1 …`, or allow local scripts once for your user:
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` (and `Unblock-File .\bt-setup.ps1` for a downloaded ZIP).

---

## 2. Add a connection profile

```powershell
.\bt-setup.ps1 add-profile
```

Same answers as on macOS. For **VCF Automation 9 – VM Apps org**:

| Prompt | Example |
|---|---|
| Profile id | `lab-vcfa` (used as `-Plab-vcfa`) |
| Target type | `vcfa9` (`vra8` for Aria Automation / vRA 8.x) |
| Automation host | `vcfa.example.local` |
| Org name | `my-vmapps-org` |
| Default project | `LAB-BuildTools` – must already exist, case-sensitive |
| vRO host / integration | defaults (embedded Orchestrator, `embedded-VRO`) |
| Ignore self-signed certs | `true` in a lab |
| Username | `admin` → login `admin@my-vmapps-org` |
| Password | typed, hidden |

Non-interactive (only the password is asked):

```powershell
.\bt-setup.ps1 add-profile -ProfileId lab-vcfa -Type vcfa9 -HostName vcfa.example.local -Port 443 `
  -Org my-vmapps-org -Project LAB-BuildTools -VroHost vcfa.example.local -VroIntegration embedded-VRO `
  -IgnoreCert true -User admin
```

Where credentials live:

- `%USERPROFILE%\.buildtools\profiles\<id>.json` – password / token **DPAPI-encrypted** (only your Windows account can decrypt it).
- `%USERPROFILE%\.m2\settings.xml` – plain text, because that is how Build Tools reads it. The script removes
  inherited permissions so only your account and SYSTEM can open it.
- `vra8` profiles log in once and store a refresh token, not the password.

Change a password later: `.\bt-setup.ps1 refresh-token lab-vcfa`.

---

## 3. Create a project

```powershell
.\bt-setup.ps1 new-project -Cust LAB -Scope bttest -ProjectType ts -MavenProfile lab-vcfa
```

| Parameter | Meaning |
|---|---|
| `-Cust` | Customer code (`LAB`, `MBCOM`, a customer code) → groupId `com.<cust>` |
| `-Scope` | e.g. `core`, `network` → artifactId; package/module `com.<cust>.<scope>` |
| `-ProjectType` | `ts` TypeScript vRO · `js` ES5 actions · `xml` workflows · `mixed` · `vra` VCFA VM Apps |
| `-MavenProfile` | Written to `.vscode\settings.json` as `vrdev.maven.profile` (VS Code Explorer / pull / push need it) |
| `-ProjectRoot` | Default `%USERPROFILE%\BuildTools\<CUST>` |

The `vra` archetype generates sample content (Small VM blueprint, `vra8-db-mssql` policies, subscription,
catalog item…). **Everything under `src` is pushed** – move what you don't want out of `src` first.

---

## 4. Build and push

Run inside the project folder. Same goals as on macOS:

```powershell
mvn clean package                              # build + sign (+ unit tests)
mvn clean package vrealize:push -Plab-vcfa     # push vRO AND VM Apps projects (there is no vra-ng:push)
mvn vra-ng:pull -Plab-vcfa                     # pull VM Apps content listed in content.yaml (overwrites local files)
```

> **PowerShell gotcha:** quote any `-D` property that contains a dot, otherwise PowerShell splits it:
> `mvn clean package vrealize:push -Plab-vcfa "-Dvrang.data.collection.delay.seconds=600"`
> (`cmd.exe` doesn't need the quotes.)

The full usage guide – push flags, cleaning old versions, versioning, where to find pushed content,
TypeScript project layout, decorators, gotchas – is in the [macOS README](../mac/README.md#4-build-and-push);
everything there applies to Windows except the install steps.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `running scripts is disabled on this system` | Use `powershell -ExecutionPolicy Bypass -File .\bt-setup.ps1 …` or the `.cmd` launchers |
| `mvn` / `java` not found after install | Open a new terminal (user `PATH` changes only reach new windows) |
| `openssl.exe not found` | Install Git for Windows (`winget install Git.Git`), open a new terminal, re-run `install` |
| `winget` not found | Install "App Installer" from the Microsoft Store, or install Git / VS Code manually, then re-run |
| `Could not find goal 'push' in plugin …vra-ng…` | Use `vrealize:push` – the vra-ng plugin only has `package` and `pull` |
| `Project id for project 'X' could not be found` | The project in the profile doesn't exist in that org (case-sensitive) – fix with `add-profile` |
| `Port is not a number: Cannot parse null string` | The `-P<id>` you used doesn't exist – check `.\bt-setup.ps1 doctor` |
| VS Code: "There is no currently active maven profile" | Set `vrdev.maven.profile` in the project's `.vscode\settings.json` (`new-project -MavenProfile` does it), reload the window |
| Behind a corporate proxy | Proxy support isn't built in yet. Set `HTTPS_PROXY` for the downloads; `settings.xml` is regenerated on every run, so re-add your `<proxies>` section after `install` / `add-profile` |
| Self-test fails | Full Maven output: `%USERPROFILE%\.buildtools\selftest-mvn.log` |

## Files this touches

```
%USERPROFILE%\.buildtools\          tools (jdk, node, maven), certs, profiles, packaging.json
%USERPROFILE%\.m2\settings.xml      regenerated on every run (an unmanaged one is backed up first)
%USERPROFILE%\.m2\settings-security.xml
%APPDATA%\Code\User\settings.json   vrdev.buildTools.defaultVersion
User environment                    JAVA_HOME, PATH
```
