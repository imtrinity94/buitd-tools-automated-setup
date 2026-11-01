# After the setup script: VS Code, your first push, and what to expect

This picks up after `install` and `add-profile` finished on [macOS](../mac/) or [Windows](../windows/).
Commands are shown for macOS / Linux shells; on Windows run the same in PowerShell
(script name `.\bt-setup.ps1`, parameters `-Cust LAB -Scope demo -ProjectType ts -MavenProfile lab-vcfa`).

- [1. Check the toolchain](#1-check-the-toolchain)
- [2. Set up VS Code](#2-set-up-vs-code)
- [3. Push your first project](#3-push-your-first-project)
- [4. Project types – what you get, where to write code, where it lands](#4-project-types)
- [5. What a push does (and what you will see)](#5-what-a-push-does)
- [6. Where to look on the server](#6-where-to-look-on-the-server)
- [7. First-push errors we have actually hit](#7-first-push-errors)
- [8. References](#8-references)

---

## 1. Check the toolchain

Open a **new** terminal (environment changes only reach new windows), then:

```bash
./bt-setup.sh doctor          # Windows: .\bt-setup.ps1 doctor
```

Expect Java 21, Maven **3.9.x**, Node 22, both signing files `ok`, and every profile reachable.
Optional: `bt-verify.command` (macOS) / `.\bt-setup.ps1 selftest` (Windows) builds and signs a
throwaway package without touching any server – a quick proof that Maven, npm and signing work.

---

## 2. Set up VS Code

The script already installed the **vRealize Developer Tools** extension (`vmware-pscoe.vrealize-developer-tools`)
and set `vrdev.buildTools.defaultVersion` to the Build Tools version it found. Per project you still need:

1. **Open the project folder** – *File → Open Folder…* and pick the folder that contains `pom.xml`
   (e.g. `~/BuildTools/LAB/demo`), not its parent. The extension works per workspace folder.
2. **Pick the Maven profile** the extension should use. Either:
   - `new-project` already wrote it to `.vscode/settings.json` as `"vrdev.maven.profile": "<profile-id>"`, or
   - click the profile indicator in the **bottom-left status bar** and choose one of the profiles from
     `~/.m2/settings.xml`. The status bar then shows the profile and the Orchestrator host.

   Without a profile you get *"There is no currently active maven profile. Set the 'vrdev.maven.profile' setting"*
   and the Orchestrator Explorer stays empty.
3. **Reload** – *Developer: Reload Window* (`Ctrl/Cmd+Shift+P`) after changing the profile.

What you then have in VS Code:

| Feature | How |
|---|---|
| **Orchestrator Explorer** | Activity bar icon → browse actions, workflows, configurations, resources, packages and plug-in inventory of the server in the profile; open any element read-only; fetch a workflow schema; delete packages |
| **IntelliSense** | Completion for the vRO scripting API, plug-in objects and server-side actions, e.g. after `System.getModule("com.vmware.library.` |
| **Run an action** | Open an action `.js` file → `Ctrl/Cmd+Shift+P` → **vRealize: Run Action** – runs it on the server, logs in the *Output* panel |
| **Push / pull** | `Ctrl/Cmd+Shift+B` (build tasks) lists push and pull for the open project – same as the `mvn` commands below |
| **New project** | `Ctrl/Cmd+Shift+P` → **vRealize: New Project** (or `bt-setup … new-project`, which also follows the naming conventions and writes the profile setting) |

Tips:

- The extension reads `vro.*` properties from the profile. If the Explorer can't connect to an *embedded*
  Orchestrator but `mvn … vrealize:push` works, add `<vro.authHost>` (same host) to the profile.
- Inventory may be cached per session – reload the window after changing things on the server.
- It is a VS Code Marketplace extension. Cursor, VSCodium and other editors that use Open VSX may not offer it.

---

## 3. Push your first project

Pick a project type ([details below](#4-project-types)) and a profile created with `add-profile`.
The example uses the code `LAB`, scope `demo` and profile `lab-vcfa`.

```bash
# 1. scaffold
CUST=LAB SCOPE=demo PTYPE=js PROFILE=lab-vcfa ./bt-setup.sh new-project
#   Windows: .\bt-setup.ps1 new-project -Cust LAB -Scope demo -ProjectType js -MavenProfile lab-vcfa

# 2. build only (no server) – proves the project compiles, tests pass and the package is signed
cd ~/BuildTools/LAB/demo
mvn clean package

# 3. push
mvn clean package vrealize:push -Plab-vcfa
```

A successful push ends with `BUILD SUCCESS`. Then open the server and find the content –
[section 6](#6-where-to-look-on-the-server) says where.

Before the first push, **look at `src`**: every archetype ships sample content, and *everything under `src` is pushed*.
That's fine for a first test in a lab. For real work, delete or move the samples first (for VM Apps projects it matters
more – see below).

---

## 4. Project types

`new-project` → `PTYPE` / `-ProjectType`:

| Type | Archetype | Language | Pull back from server? | Best for |
|---|---|---|---|---|
| `js` | `package-actions-archetype` | vRO JavaScript (ES5) | **Yes** – `mvn vro:pull` | Action libraries with unit tests |
| `xml` | `package-xml-archetype` | Workflow XML as exported by vRO | **Yes** – `mvn vro:pull` | Versioning workflows, config/resource elements built in the vRO client |
| `mixed` | `package-mixed-archetype` | JS actions module + XML workflows module | **Yes** – per module | Typical vRO content: code-first actions + UI-built workflows |
| `ts` | `package-typescript-archetype` | TypeScript → compiled to ES5 | **No** – one-way | Code-first actions *and* workflows with types, decorators and tests |
| `vra` | `package-vra-ng-archetype` | YAML / JSON | **Yes** – `mvn vra-ng:pull` | Aria Automation 8.x / VCF Automation VM Apps: cloud templates, catalog, policies, subscriptions … |

### `js` – vRO actions

- Write actions in `src/main/resources/<group path>/<artifact path>/<actionName>.js`,
  e.g. `src/main/resources/com/lab/demo/getVmName.js` → action `getVmName` in module **`com.lab.demo`**.
- Each file is one action in the classic IIFE form; inputs and return type come from JSDoc:

  ```js
  /**
   * @param {string} name - VM name
   * @return {string}
   */
  (function (name) {
      return name.toUpperCase();
  });
  ```
- Unit tests (Jasmine) go in `src/test/resources/...` and run on every `mvn clean package`. Files named
  `*.helper.js` / `*_helper.js` are test helpers – never actions.
- Changed an action in the vRO client? `mvn vro:pull -Plab-vcfa` brings the package content back (overwrites local files – commit first).
- Expect in vRO: package `com.lab.demo` and the actions under module `com.lab.demo` (plus the sample action).

### `xml` – vRO workflows and elements

- Content is the vRO export format: each element is a pair `<Name>.xml` + `<Name>.element_info.xml` under
  `src/main/resources/` (workflows under `Workflow/<folder path>/…`). The workflow folder is set when the project is
  generated and can be changed later.
- **The vRO package is the content descriptor.** Usual loop: push once (creates package `com.lab.demo`), build or
  change workflows in the vRO client, add them to that package, then `mvn vro:pull -Plab-vcfa` to bring them into Git.
  Pull overwrites local files – commit first.
- Pull config element *values* too: `mvn vro:pull -Plab-vcfa -Dvro.packageExportConfigurationAttributeValues=true`.
  (PowerShell: quote it – `"-Dvro.packageExportConfigurationAttributeValues=true"`.)
- Expect in vRO: package `com.lab.demo` and the sample workflow under the folder from the archetype.

### `mixed` – actions + workflows

- Two Maven modules: `actions` (works like `js`) and `workflows` (works like `xml`).
- Push both from the project root: `mvn clean package vrealize:push -Plab-vcfa`.
- Pull per module: `mvn vro:pull -Plab-vcfa -pl workflows` (or `-pl actions`).
- Expect in vRO: a package for each module (check *Assets → Packages* for the names) plus their actions and workflows.

### `ts` – TypeScript

- Code lives under `src/` – actions as `.ts` (or plain `.js`), workflows as `*.wf.ts`, custom forms `*.wf.form.json`,
  configuration elements `*.conf.ts` / `*.conf.yaml`, policies `*.pl.ts`, unit tests `*.test.ts`.
- `mvn clean package` compiles to **ES5** with *vrotsc*, runs the unit tests, then builds and signs the package.
  The first build also creates `LICENSE`, `package.json`, `node_modules` and adds licence headers to source files – normal.
- **There is no pull.** Git is the source of truth; anything edited in the vRO client is overwritten on the next push.
- ES5 gotcha: type arrays explicitly (`const vms: Array<VcVirtualMachine> = …`) or helpers like `find()` aren't
  transpiled and fail at runtime in vRO.
- The sample content is a "Create Integration" workflow (under `PSCoE/my-project/…`) with a custom form,
  sample actions and one passing test – replace it with your own before real work.
- Expect in vRO: package `com.lab.demo`, its actions, and the workflows in the folders set in the decorators.
- Full layout and decorator example: [macOS guide → section 5](../mac/README.md#5-working-on-typescript-vro-projects).

### `vra` – Aria Automation 8.x / VCF Automation VM Apps

- Content lives in `src/main/resources/`: `blueprints/<Name>/content.yaml` + `details.json`, `catalog-items/`,
  `custom-resources/`, `resource-actions/`, `subscriptions/`, `property-groups/`, `content-sources/`,
  `policies/{approval,content-sharing,day2-actions,deployment-limit,lease,resource-quota}/`.
- **The archetype's sample content refers to things that don't exist in your environment** (`vra8-db-mssql`
  policies, a subscription, an `Orchestrator_Development` content source…). Move everything you don't want out of
  `src` (e.g. into `samples/`) before the first push – *all* of `src` is imported.
- Target = the **project and org in the profile** (`vrang.project.name`, `vrang.org.name`). The project must already
  exist (names are case-sensitive). One Maven project = one VCFA/vRA project.
- Push with **`vrealize:push`** – the vra-ng plugin itself only has `package` and `pull` (some docs show
  `vra-ng:push`, which fails with *"Could not find goal 'push'"*).
- Pull with `mvn vra-ng:pull -Plab-vcfa`. What is pulled is controlled by the project-level `content.yaml`
  (a list of names per type; `[]` = nothing of that type; leaving a type empty/null = everything). Push ignores it.
- Cloud templates are matched **by name**: same name → updated, and a new version is released when the content
  changed (`1.0.0` → `1.0.1`, `1` → `2`); new name → created.
- If templates or catalog items use vRO workflows, give VCFA time to collect them:
  `-Dvrang.data.collection.delay.seconds=600`.
- Expect in VCF Automation: the cloud template(s) in the project, released as a version.

---

## 5. What a push does

`mvn clean package vrealize:push -P<profile>`:

1. **Build** – downloads Build Tools plugins and libraries (only the first time, can take a few minutes),
   runs `npm install` for the build tooling, compiles TypeScript if any, runs unit tests, and writes a signed
   `target/<groupId>.<artifactId>-<version>.package` (vRO) or `.vrang` (VM Apps).
2. **Connect** – logs in with the profile (VCFA 9: `user@org` + password; vRA 8: refresh token).
   `Auth port is not a number … Proceeding with default value: 443` is harmless.
3. **Import** – vRO packages are imported into Orchestrator. **Dependencies are pushed too** (default
   `-DincludeDependencies=true`), so expect extra packages such as `com.vmware.pscoe.library.*` in vRO after the
   first push. Use `-DincludeDependencies=false` once they're there.
   VM Apps content is imported type by type (property groups, blueprints, catalog items, policies …).
4. **Versions** – the version in `pom.xml` is the package version (`1.0.0-SNAPSHOT` by default). Bump it for a
   release; `-Dvro.importOldVersions=true` allows pushing an older version than the server has.

Logs: the console, plus `vrbt.log` / `vrbt-debug.log` / `vrbt-error.log` in the project folder.
Need more detail: add `-e` (stack trace) or `-X` (debug).

---

## 6. Where to look on the server

### Orchestrator (vRO) client

| You pushed | Look in |
|---|---|
| The package itself | **Assets → Packages** → `com.<cust>.<scope>` (and `com.vmware.pscoe.library.*` dependencies) |
| Actions | **Library → Actions** → module `com.<cust>.<scope>` (search by name) |
| Workflows | **Library → Workflows** → folder path from the XML export or the TypeScript decorator `path` |
| Configuration elements | **Assets → Configurations** |
| Resource elements | **Assets → Resources** |
| Policies | **Library → Policies** |

Test it: open a workflow → **Run**, then check the run's **Logs** tab; or run an action from VS Code
(**vRealize: Run Action**).

For VCF Automation 9, the embedded Orchestrator is opened from the VCF Automation UI; it is the same client.

### VCF Automation / Aria Automation

Everything lands in the **project from the profile** (`vrang.project.name`) of the **org** in the profile:

| You pushed | Look for |
|---|---|
| `blueprints/` | Cloud templates of the project – check the template and its released version |
| `catalog-items/`, `content-sources/` | Content sources and catalog items (with custom forms and icons) |
| `custom-resources/`, `resource-actions/` | Custom resources and custom resource actions |
| `subscriptions/` | Extensibility subscriptions |
| `policies/…` | Approval, content-sharing, day-2, deployment-limit, lease, resource-quota policies |
| `property-groups/` | Property groups |

Menu names differ between Aria Automation 8.x (Assembler / Service Broker) and the VCF Automation 9 VM Apps org
portal; search for the object name in the project.

---

## 7. First-push errors

All of these came up while building this repo:

| Error | Cause / fix |
|---|---|
| `Port is not a number: Cannot parse null string` + `The requested profile "x" could not be activated` | `-P` names a profile that doesn't exist – check `doctor` for the right id |
| `Project id for project 'X' could not be found on target system` | The project in the profile doesn't exist in that org (case-sensitive) – create it or fix the profile |
| `Could not find goal 'push' in plugin …vra-ng-package-maven-plugin` | Use `vrealize:push` |
| `install-node-deps … failed with code 1`, npm `EACCES` | npm cache owned by another user (old `sudo npm`) – the macOS script switches cache; fix with `sudo chown -R $(id -u):$(id -g) ~/.npm` |
| VS Code: *no currently active maven profile* | Set `vrdev.maven.profile` (see [section 2](#2-set-up-vs-code)) |
| 401 / login failure on VCFA 9 | Login must be `user@<vm-apps-org>`; re-enter with `refresh-token <id>`. SSO-only accounts have no password – use a local account |
| Maven warns about `maven-install-plugin:4.0.0-beta-*` | Harmless – Maven 3.9 picks the compatible 3.x plugin |

---

## 8. References

- Build Tools for VMware Aria – source and releases: <https://github.com/vmware/build-tools-for-vmware-aria>
- Build Tools documentation: <https://vmware.github.io/build-tools-for-vmware-aria/>
  - Getting started: <https://vmware.github.io/build-tools-for-vmware-aria/getting-started>
  - vRO TypeScript projects: <https://vmware.github.io/build-tools-for-vmware-aria/usage/products/vro/typescript/>
  - vRO actions (JS) projects: <https://vmware.github.io/build-tools-for-vmware-aria/usage/products/vro/actions/>
  - vRO XML projects: <https://vmware.github.io/build-tools-for-vmware-aria/usage/products/vro/xml/>
  - VCF Automation VM Apps: <https://vmware.github.io/build-tools-for-vmware-aria/usage/products/vcfa/vm-apps/>
  - Blueprints / versioning: <https://vmware.github.io/build-tools-for-vmware-aria/usage/products/vcfa/vm-apps/Blueprints/>
  - VS Code extension: <https://vmware.github.io/build-tools-for-vmware-aria/usage/vrdt/>
  - Changelog: <https://vmware.github.io/build-tools-for-vmware-aria/CHANGELOG/>
- vRealize Developer Tools (VS Code extension): <https://github.com/vmware/vrealize-developer-tools> ·
  [Marketplace](https://marketplace.visualstudio.com/items?itemName=vmware-pscoe.vrealize-developer-tools)
- Blogs
  - Kristof Asaert – *Configure your Windows workstation for Aria Build Tools*:
    <https://vkasaert.com/2025/05/27/configure-your-windows-workstation-for-aria-build-tools/>
  - Cloudblogger – *Mastering vRA/vRO Development with Visual Studio Code + Build Tools*:
    <https://cloudblogger.co.in/2025/08/08/build-tools-for-aria-challenges-first-rewards-later/>
