# Build Tools for VMware Aria / VCF Automation – macOS setup

One script that sets up a Mac for [Build Tools for VMware Aria](https://github.com/vmware/build-tools-for-vmware-aria)
and pushes vRO (JavaScript / TypeScript) and VCF Automation VM Apps (vRA) projects.
Tested on Apple Silicon, macOS 26, with Build Tools 4.25.1 and VCF Automation 9 (VM Apps org).

| File | What it is |
|---|---|
| `bt-setup.sh` | The script: `install`, `add-profile`, `refresh-token`, `new-project`, `doctor` |
| `bt-install.command` | Double-click launcher for `bt-setup.sh install` (logs to `bt-setup.log`) |
| `bt-verify.command` | Double-click self-test: scaffolds a throwaway project, builds and signs it, deletes it |

Everything is re-runnable – steps that are already done are skipped.

---

> After installing, continue with **[Getting started](../docs/getting-started.md)**: VS Code setup, your first push, all project types and where to find pushed content.

## 1. Install the toolchain

Prerequisite: [Homebrew](https://brew.sh) (the script finds it in `/opt/homebrew`, `/usr/local` or `~/.homebrew`).

```bash
git clone https://github.com/imtrinity94/buitd-tools-automated-setup.git
cd buitd-tools-automated-setup/mac
chmod +x bt-setup.sh *.command
./bt-setup.sh install          # or double-click bt-install.command in Finder
```

What `install` does:

| Step | Result |
|---|---|
| Homebrew | `openjdk@21`, `node@22`, `openssl@3`, VS Code (into `~/Applications` if `/Applications` isn't writable) |
| Maven | **3.9.16** downloaded from apache.org, SHA-512 verified, into `~/.buildtools/apache-maven-3.9.16` (Homebrew's `maven` is now 3.10 – Build Tools supports 3.9.x) |
| Shell | A managed block in `~/.zprofile` sets `JAVA_HOME` and `PATH` (backup: `~/.zprofile.bak-bt`) |
| npm cache | If `~/.npm` has files you don't own (old `sudo npm`), Build Tools uses `~/.buildtools/npm-cache` instead |
| VS Code | Extension `vmware-pscoe.vrealize-developer-tools`; `vrdev.buildTools.defaultVersion` = latest Build Tools on Maven Central |
| Signing | Self-signed package-signing cert in `~/.buildtools/certs`, key password in `~/.buildtools/packaging.env` |
| Maven | `~/.m2/settings-security.xml` (random master password) and `~/.m2/settings.xml` with the `packaging` profile |

Open a **new** Terminal afterwards (or `source ~/.zprofile`), then check:

```bash
./bt-setup.sh doctor
```

Optional self-test (no server needed): double-click `bt-verify.command` → expect `BUILD SUCCESS` and a signed `.package`.

---

## 2. Add a connection profile

Each target environment is one Maven profile, used as `-P<profile-id>`.

```bash
./bt-setup.sh add-profile
```

Answers for **VCF Automation 9 – VM Apps org**:

| Prompt | Example | Notes |
|---|---|---|
| Profile id | `lab-vcfa` | lower case, used as `-Plab-vcfa` |
| Target type | `vcfa9` | `vra8` for Aria Automation / vRA 8.x |
| Automation host | `vcfa.example.local` | the VCF Automation FQDN |
| Org name | `my-vmapps-org` | the **VM Apps** organization |
| Default project | `LAB-BuildTools` | the VCFA project vRA content is pushed into |
| vRO host | same as Automation host | embedded Orchestrator |
| vRO integration | `embedded-VRO` | default |
| Ignore self-signed certs | `true` | lab only – use proper CA certs in production |
| Username | `admin` | login becomes `admin@my-vmapps-org` |
| Password | (typed, hidden) | stored only in `~/.m2/settings.xml` and `~/.buildtools/profiles/<id>.env`, both mode 600 |

For **vra8** targets the script logs in once with your password (never stored) and saves a refresh token instead.

Change a password / token later: `./bt-setup.sh refresh-token lab-vcfa`.

What gets written for a `vcfa9` profile (VM Apps auth is `user@org` + password):

```xml
<vrang.host>vcfa.example.local</vrang.host>
<vrang.csp.host>vcfa.example.local</vrang.csp.host>
<vrang.org.name>my-vmapps-org</vrang.org.name>
<vrang.project.name>LAB-BuildTools</vrang.project.name>
<vrang.username>admin@my-vmapps-org</vrang.username>
<vrang.password>…</vrang.password>
<vro.host>vcfa.example.local</vro.host>
<vro.auth>vra</vro.auth>
<vro.username>admin@my-vmapps-org</vro.username>
<vro.password>…</vro.password>
```

The account needs rights to the VCFA project (org/project admin) and to write content in the embedded Orchestrator.

---

## 3. Create a project

```bash
./bt-setup.sh new-project
```

| Prompt | Meaning |
|---|---|
| Customer code | 2–5 letters (`LAB`, `MBCOM`, a customer code) → Maven groupId `com.<cust>` |
| Package scope | e.g. `core`, `network` → artifactId; package/module `com.<cust>.<scope>` |
| Type | `ts` TypeScript vRO · `js` ES5 actions · `xml` workflows · `mixed` · `vra` VCFA VM Apps |

Projects are created in `~/BuildTools/<CUST>/<scope>` (override with `PROJECT_ROOT=/path`).
Non-interactive: `CUST=LAB SCOPE=bttest PTYPE=ts PROFILE=lab-vcfa ./bt-setup.sh new-project`.
`PROFILE` is written to the project's `.vscode/settings.json` as `vrdev.maven.profile`, which the
vRealize Developer Tools extension needs for its Explorer and for pull/push from VS Code.

---

## 4. Build and push

Run these **inside the project folder**.

### vRO projects (`ts`, `js`, `xml`, `mixed`)

```bash
mvn clean package                                              # build + sign, runs unit tests
mvn clean package vrealize:push -Plab-vcfa                     # build + push (dependencies included by default)
mvn clean package vrealize:push -Plab-vcfa -DincludeDependencies=false   # only this package
mvn clean package -DskipTests vrealize:push -Plab-vcfa         # skip unit tests
```

Useful push flags:

| Flag | Effect |
|---|---|
| `-Dvro.packageImportConfigurationAttributeValues=true` | also push configuration element values (not SecureStrings) |
| `-Dvro.packageImportConfigSecureStringAttributeValues=true` | also push SecureString values |
| `-Dvro.importOldVersions=true` | allow pushing a lower version than the server has |
| `-Dvro.forceImportLatestVersions=true` | fail unless the version is same or newer |

Clean old package versions from the server (dry run first):

```bash
mvn vrealize:clean -DincludeDependencies=true -DcleanUpOldVersions=true -DcleanUpLastVersion=false -Ddryrun=true -Plab-vcfa
```

### VCF Automation VM Apps projects (`vra`)

```bash
mvn clean package vrealize:push -Plab-vcfa
mvn vra-ng:pull -Plab-vcfa                                     # pull content from the project into ./src
mvn clean package vrealize:push -Plab-vcfa -Dvrang.data.collection.delay.seconds=600   # if content uses vRO workflows
```

> The `vra-ng` plugin only has `package` and `pull` goals – pushing VM Apps projects uses the same
> `vrealize:push` goal as vRO projects (some docs pages still show `vra-ng:push`, which fails with
> "Could not find goal 'push'").

The archetype generates sample content (a `Small VM` blueprint, `vra8-db-mssql` policies, a subscription,
a catalog item, a content source…). **Everything under `./src` is pushed**, so move what you don't want
out of `src` (e.g. to `samples/`) before the first push. Content goes to the project/org in the profile. One Maven project = one VCFA project + org;
for another project, create another Maven project (or another profile with a different `vrang.project.name`).

### Where to see the result

| Pushed | Where |
|---|---|
| vRO package | Orchestrator client → **Assets → Packages** → `com.<cust>.<scope>` |
| vRO actions | Orchestrator client → **Library → Actions** → module `com.<cust>.<scope>…` (+ `com.vmware.pscoe.library.*` dependencies) |
| vRO workflows / config elements / resources | **Library → Workflows / Configurations / Resources** under the folder paths set in code |
| VM Apps content | VCF Automation → the VM Apps org → the project in the profile: cloud templates, custom forms, custom resources, subscriptions, policies |

### Versioning

The version in `pom.xml` is the package version. To release a new version, bump `<version>` (e.g. `1.0.1`),
update any dependency on it in other `pom.xml` files of the same repo, then push.

---

## 5. Working on TypeScript vRO projects

### How it works

TypeScript in `src/` is compiled by **vrotsc** to **ES5 Orchestrator JavaScript** at build time and packed into a
native, signed vRO package. It is one-way: **there is no pull for TypeScript projects** – the Git repo is the source of
truth, Orchestrator is only a deployment target. Don't edit pushed content in the vRO client; it will be overwritten.

### Layout

```
pom.xml
tsconfig.json            # editor only – vrotsc uses its own ES5 config
src/
  actions/               # actions (.ts or plain .js)
  workflows/             # *.wf.ts (+ *.wf.form.json custom forms)
  configs/               # *.conf.ts / *.conf.yaml configuration elements
  policies/              # *.pl.ts
  resources/             # resource elements + *.element_info.json
  types/                 # *.d.ts declarations
  **/*.test.ts           # unit tests
```

The exact folders come from the archetype – look at the sample content it generates first.

| Suffix | Becomes |
|---|---|
| `.ts` / `.js` in actions | vRO action |
| `.wf.ts` | workflow |
| `.wf.form.json` | workflow custom form |
| `.conf.ts` / `.conf.yaml` | configuration element |
| `.pl.ts` | policy |
| `.test.ts` | unit test (not packaged) |
| `*.helper.ts`, `*_helper.js` | test helper (not packaged; can't be used as action names) |

### Action

```ts
/**
 * @param {string} name - VM name
 * @returns {string} Name with timestamp
 */
(function (name: string): string {
    return `${name} ${System.formatDate(new Date(), "dd.MM.yyyy HH:mm:ss")}`;
})
```

Inputs and return type come from the TypeScript type hints. Not supported: optional parameters, union types,
`...rest` parameters. Action names: letters, digits, `_`, `$`; not starting with a digit.

### Workflow

```ts
import { Workflow, RootItem, Item, In, Out } from "vrotsc-annotations";

@Workflow({
  name: "LAB - Demo - Say Hello",
  path: "LAB/05 Utilities/Demo",
  attributes: { message: { type: "string" } }
})
export class SayHello {
  @RootItem({ target: "setMessage" })
  public start() {
    System.log("Starting");
  }

  @Item({ target: "printMessage" })
  public setMessage(@Out @In message: string) {
    message = "Hello";
  }

  @Item({ target: "end" })
  public printMessage(@In message: string) {
    System.log(`Message: ${message}`);
  }
}
```

### Day-to-day loop

```bash
code .                                            # VS Code with vRealize Developer Tools
mvn clean package                                 # compile + unit tests
mvn clean package vrealize:push -Plab-vcfa        # deploy to the lab
```

Then run the workflow / action in Orchestrator and check the logs.

### Gotchas

- Output is ES5. Array helpers like `find()` are only transpiled when the type is known –
  declare `const items: Array<Vm> = …` instead of relying on inference, or you get a runtime error in vRO.
- `tsconfig.json` changes only affect editor IntelliSense, not the compiled output.
- Keep secrets out of code and out of `src/configs` values; push SecureStrings only with the flag above.

### Docs

- TypeScript projects: <https://vmware.github.io/build-tools-for-vmware-aria/usage/products/vro/typescript/>
- Workflows: <https://vmware.github.io/build-tools-for-vmware-aria/usage/products/vro/typescript/Workflows/>
- Actions: <https://vmware.github.io/build-tools-for-vmware-aria/usage/products/vro/typescript/Actions/>
- VCFA VM Apps: <https://vmware.github.io/build-tools-for-vmware-aria/usage/products/vcfa/vm-apps/>

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `install-node-deps … failed with code 1`, npm `EACCES` in `~/.npm/_cacache` | `~/.npm` has root-owned files. The script already switches to `~/.buildtools/npm-cache`; permanent fix: `sudo chown -R $(id -u):$(id -g) ~/.npm` |
| `Extension 'vmware-pscoe.vrdev' not found` | Old ID – the extension is `vmware-pscoe.vrealize-developer-tools` (fixed in the script) |
| `mvn -v` shows 3.10 | New terminal / `source ~/.zprofile` – the pinned 3.9.16 must come first on `PATH` |
| SSL / PKIX errors on push | Lab: profile with "ignore self-signed certs = true". Production: import the CA into the JDK `cacerts` |
| 401 on push to VCFA 9 | Username must be `user@<vm-apps-org>`; re-enter with `./bt-setup.sh refresh-token <id>` |
| `.command` won't open ("unidentified developer") | Right-click → Open once, or run it from Terminal |
| VS Code: "There is no currently active maven profile. Set the 'vrdev.maven.profile' setting" (Explorer empty, pull fails) | Add `{"vrdev.maven.profile": "<profile-id>"}` to the project's `.vscode/settings.json` (`new-project` now does this), then reload the window |
| Need full Maven output | `mvn -e -X …` ; the self-test saves `bt-verify-mvn.log` next to itself |

## Files this touches

```
~/.zprofile                         managed block between "build-tools-for-aria" markers
~/.m2/settings.xml                  regenerated on every run (an unmanaged one is backed up first)
~/.m2/settings-security.xml
~/.buildtools/                      maven, certs, profiles, npm-cache, selftest
~/Library/Application Support/Code/User/settings.json   vrdev.buildTools.defaultVersion
```
