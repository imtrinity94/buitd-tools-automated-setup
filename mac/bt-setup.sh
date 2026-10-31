#!/usr/bin/env bash
# =============================================================================
# bt-setup.sh - Build Tools for VMware Aria: workstation setup for macOS
#
# Commands (all re-runnable; anything already in place is skipped):
#   install                 Tools, shell env, VS Code extension, signing cert,
#                           Maven master password, settings.xml
#   add-profile             Add / update a connection profile (vRA 8 or VCFA 9)
#   refresh-token <id>      Re-fetch the refresh token for an existing profile
#   new-project             Scaffold a Build Tools project from an archetype
#   doctor                  Show versions, files, profiles and host reachability
#
# Any prompt can be pre-answered with an environment variable, e.g.
#   P_ID=lab-vcfa P_HOST=vcfa.vmw.lab ./bt-setup.sh add-profile
# Override the Build Tools version with BT_VERSION=x.y.z (default: latest
# release on Maven Central). BT_GEN_KEYPASS=1 generates the signing-key
# password; BT_SKIP_PROFILE=1 skips the "add a profile now?" question.
#
# Written for the macOS default bash 3.2 - no bash 4+ features.
# =============================================================================
set -euo pipefail

BT_HOME="${BT_HOME:-$HOME/.buildtools}"
PROFILE_DIR="$BT_HOME/profiles"
CERT_DIR="$BT_HOME/certs"
PACKAGING_ENV="$BT_HOME/packaging.env"
M2="$HOME/.m2"
SETTINGS="$M2/settings.xml"
SETTINGS_SEC="$M2/settings-security.xml"
ZPROFILE="$HOME/.zprofile"
MARK_BEGIN="# >>> build-tools-for-aria >>>"
MARK_END="# <<< build-tools-for-aria <<<"
SETTINGS_MARK="managed-by: bt-setup.sh"
ARCHETYPE_GROUP="com.vmware.pscoe.o11n.archetypes"
MAVEN_VERSION="${MAVEN_VERSION:-3.9.16}"   # Build Tools supports Maven 3.9.x
MAVEN_HOME="$BT_HOME/apache-maven-$MAVEN_VERSION"
VSCODE_EXT="vmware-pscoe.vrealize-developer-tools"
CENTRAL="https://repo1.maven.org/maven2"
VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"

# ----------------------------------------------------------------- helpers ---
c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_ok" "$c_off" "$*"; }
skip() { printf '%s    %s%s\n' "$c_dim" "$*" "$c_off"; }
warn() { printf '%s!!  %s%s\n' "$c_warn" "$*" "$c_off" >&2; }
die()  { printf '%sERROR:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

# ask VAR "Prompt" [default]  - skipped when VAR is already set in the env
ask() {
  local __var="$1" __prompt="$2" __def="${3:-}" __val=""
  eval "__val=\${$__var:-}"
  if [ -z "$__val" ]; then
    if [ -n "$__def" ]; then
      read -r -p "    $__prompt [$__def]: " __val
      __val="${__val:-$__def}"
    else
      while [ -z "$__val" ]; do read -r -p "    $__prompt: " __val; done
    fi
  fi
  printf -v "$__var" '%s' "$__val"
}

# ask_secret VAR "Prompt" [confirm]
ask_secret() {
  local __var="$1" __prompt="$2" __confirm="${3:-}" __a="" __b=""
  eval "__a=\${$__var:-}"
  if [ -z "$__a" ]; then
    while :; do
      read -r -s -p "    $__prompt: " __a; echo
      [ -z "$__a" ] && continue
      [ -z "$__confirm" ] && break
      read -r -s -p "    Confirm: " __b; echo
      [ "$__a" = "$__b" ] && break
      warn "Did not match, try again."
    done
  fi
  printf -v "$__var" '%s' "$__a"
}

yesno() { # yesno "Question" default(y|n)
  local a=""; read -r -p "    $1 [$2]: " a; a="${a:-$2}"
  case "$a" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Write KEY=value lines safely (values are shell-quoted, file is chmod 600)
write_env() { # write_env file VAR1 VAR2 ...
  local f="$1"; shift; local tmp="$f.tmp" v val
  umask 077; : > "$tmp"
  for v in "$@"; do eval "val=\${$v:-}"; printf '%s=%q\n' "$v" "$val" >> "$tmp"; done
  mv "$tmp" "$f"; chmod 600 "$f"
}

find_vscode_app() {
  local a
  for a in "/Applications/Visual Studio Code.app" "$HOME/Applications/Visual Studio Code.app"; do
    [ -d "$a" ] && { echo "$a"; return 0; }
  done
  return 1
}

require_macos() { [ "$(uname -s)" = "Darwin" ] || die "This script is for macOS."; }

ensure_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    local p
    for p in "$HOME/.homebrew/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [ -x "$p" ] && eval "$("$p" shellenv)" && break
    done
  fi
  command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install it first (needs your admin password):
  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
}

load_env() { # puts JDK/Node/OpenSSL from Homebrew on PATH for this run
  ensure_brew
  local jdk node
  jdk="$(brew --prefix openjdk@21 2>/dev/null)/libexec/openjdk.jdk/Contents/Home"
  node="$(brew --prefix node@22 2>/dev/null)/bin"
  [ -d "$jdk" ] && export JAVA_HOME="$jdk" && PATH="$JAVA_HOME/bin:$PATH"
  [ -d "$node" ] && PATH="$node:$PATH"
  [ -d "$MAVEN_HOME/bin" ] && PATH="$MAVEN_HOME/bin:$PATH"
  export PATH
  if [ -z "${npm_config_cache:-}" ] && [ -d "$BT_HOME/npm-cache" ]; then export npm_config_cache="$BT_HOME/npm-cache"; fi
  OPENSSL="$(brew --prefix openssl@3 2>/dev/null)/bin/openssl"
  [ -x "$OPENSSL" ] || OPENSSL="openssl"
}

resolve_bt_version() { # latest archetype release on Maven Central
  if [ -n "${BT_VERSION:-}" ]; then echo "$BT_VERSION"; return; fi
  local v
  v="$(curl -fsS "$CENTRAL/${ARCHETYPE_GROUP//.//}/package-typescript-archetype/maven-metadata.xml" 2>/dev/null \
       | sed -n 's:.*<release>\(.*\)</release>.*:\1:p' | head -1)"
  [ -n "$v" ] || die "Could not look up the latest Build Tools version on Maven Central. Re-run with BT_VERSION=x.y.z"
  echo "$v"
}

# ----------------------------------------------------------------- install ---
install_tools() {
  log "Homebrew packages"
  ensure_brew
  local f
  for f in openjdk@21 node@22 openssl@3; do
    if brew list --versions "$f" >/dev/null 2>&1; then skip "$f already installed"
    else brew install "$f"; fi
  done
  if find_vscode_app >/dev/null; then skip "VS Code already installed ($(find_vscode_app))"
  elif [ -w /Applications ]; then brew install --cask visual-studio-code
  else
    mkdir -p "$HOME/Applications"
    skip "/Applications not writable - installing VS Code into ~/Applications"
    brew install --cask --appdir="$HOME/Applications" visual-studio-code
  fi
}

install_maven() {
  log "Apache Maven $MAVEN_VERSION ($MAVEN_HOME)"
  if [ -x "$MAVEN_HOME/bin/mvn" ]; then skip "already installed"; return; fi
  local f="apache-maven-$MAVEN_VERSION-bin.tar.gz" tmp base want got ok=""
  tmp="$(mktemp -d)"
  for base in "https://dlcdn.apache.org/maven/maven-3/$MAVEN_VERSION/binaries" \
              "https://archive.apache.org/dist/maven/maven-3/$MAVEN_VERSION/binaries"; do
    if curl -fsSL -o "$tmp/$f" "$base/$f" && curl -fsSL -o "$tmp/$f.sha512" "$base/$f.sha512"; then ok=1; break; fi
  done
  [ -n "$ok" ] || die "Could not download Maven $MAVEN_VERSION from apache.org"
  want="$(awk '{print $1}' "$tmp/$f.sha512")"
  got="$(shasum -a 512 "$tmp/$f" | awk '{print $1}')"
  [ "$want" = "$got" ] || die "Maven download checksum mismatch - not installing."
  mkdir -p "$BT_HOME"
  tar -xzf "$tmp/$f" -C "$BT_HOME"
  rm -rf "$tmp"
  [ -x "$MAVEN_HOME/bin/mvn" ] || die "Maven extract failed"
  skip "installed (checksum verified)"
  if brew list --versions maven >/dev/null 2>&1; then
    skip "Homebrew 'maven' is also installed; the pinned $MAVEN_VERSION comes first on PATH"
  fi
}

write_shell_block() {
  log "Shell environment (~/.zprofile)"
  local jdk node block tmp npmline=""
  jdk="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
  node="$(brew --prefix node@22)/bin"
  if [ -d "$HOME/.npm" ] && [ -n "$(find "$HOME/.npm" ! -user "$(id -un)" -print -quit 2>/dev/null)" ]; then
    warn "~/.npm contains files owned by another user (usually from an old 'sudo npm')."
    warn "Build Tools will use $BT_HOME/npm-cache instead. Permanent fix (needs admin):"
    warn "  sudo chown -R \$(id -u):\$(id -g) ~/.npm"
    mkdir -p "$BT_HOME/npm-cache"
    npmline="
export npm_config_cache=\"$BT_HOME/npm-cache\""
  fi
  block="$MARK_BEGIN
export JAVA_HOME=\"$jdk\"
export PATH=\"$MAVEN_HOME/bin:\$JAVA_HOME/bin:$node:\$PATH\"$npmline
$MARK_END"
  touch "$ZPROFILE"
  tmp="$(mktemp)"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{s=1;next} $0==e{s=0;next} !s' "$ZPROFILE" > "$tmp"
  printf '%s\n' "$block" >> "$tmp"
  if cmp -s "$tmp" "$ZPROFILE"; then skip "already up to date"; rm -f "$tmp"
  else cp "$ZPROFILE" "$ZPROFILE.bak-bt"; mv "$tmp" "$ZPROFILE"; skip "updated (backup: ~/.zprofile.bak-bt)"; fi
  load_env
}

check_versions() {
  log "Checking versions"
  local mv
  java -version 2>&1 | head -1 | sed 's/^/    /'
  mv="$(mvn -v 2>/dev/null | head -1)"; echo "    $mv"
  case "$mv" in *"Maven 3.9"*) ;; *) warn "Expected Maven 3.9.x but got: $mv - open a new terminal or check PATH" ;; esac
  echo "    node $(node -v)   npm $(npm -v)"
}

setup_vscode() {
  log "VS Code extension (vRealize Developer Tools)"
  local code ver app
  app="$(find_vscode_app || true)"
  code="$app/Contents/Resources/app/bin/code"
  [ -n "$app" ] && [ -x "$code" ] || code="$(command -v code || true)"
  [ -n "$code" ] && [ -x "$code" ] || { warn "VS Code CLI not found - skipping extension"; return; }
  if "$code" --list-extensions 2>/dev/null | grep -qix "$VSCODE_EXT"; then skip "already installed"
  else
    local out
    if out="$("$code" --install-extension "$VSCODE_EXT" 2>&1)"; then skip "installed $VSCODE_EXT"
    else printf '%s\n' "$out" | grep -v -i deprecation >&2; die "Could not install VS Code extension $VSCODE_EXT"; fi
  fi

  ver="$(resolve_bt_version)"
  mkdir -p "$(dirname "$VSCODE_SETTINGS")"
  [ -f "$VSCODE_SETTINGS" ] || echo '{}' > "$VSCODE_SETTINGS"
  if F="$VSCODE_SETTINGS" V="$ver" node -e '
      const fs=require("fs"); const f=process.env.F;
      const o=JSON.parse(fs.readFileSync(f,"utf8")||"{}");
      if (o["vrdev.buildTools.defaultVersion"]===process.env.V) process.exit(2);
      o["vrdev.buildTools.defaultVersion"]=process.env.V;
      fs.writeFileSync(f, JSON.stringify(o,null,4)+"\n");' 2>/dev/null; then
    skip "set vrdev.buildTools.defaultVersion = $ver"
  elif [ $? -eq 2 ]; then skip "vrdev.buildTools.defaultVersion already $ver"
  else warn "settings.json has comments or is not plain JSON - set 'Vrdev > Build Tools: Default Version' to $ver by hand"; fi
}

setup_cert() {
  log "Package signing certificate ($CERT_DIR)"
  if [ -f "$CERT_DIR/private_key.pem" ] && [ -f "$CERT_DIR/certificate.pem" ] && [ -f "$PACKAGING_ENV" ]; then
    skip "already present"; return
  fi
  mkdir -p "$CERT_DIR"; chmod 700 "$BT_HOME" "$CERT_DIR"
  local cn="${CERT_CN:-$(whoami) Build Tools Signing}"
  if [ "${BT_GEN_KEYPASS:-}" = "1" ] && [ -z "${KEY_PASS:-}" ]; then
    KEY_PASS="$("$OPENSSL" rand -hex 16)"; skip "generated a random signing-key password (kept in $PACKAGING_ENV)"
  fi
  ask_secret KEY_PASS "Password to protect the signing key" confirm
  cat > "$CERT_DIR/certificate.cfg" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
prompt             = no
string_mask        = nombstr
req_extensions     = v3_req
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, nonRepudiation
[ req_distinguished_name ]
CN = $cn
EOF
  (
    cd "$CERT_DIR"
    "$OPENSSL" genrsa -out private_key.key 2048 2>/dev/null
    "$OPENSSL" req -new -x509 -sha256 -days 3650 -key private_key.key -out certificate.crt -config certificate.cfg
    "$OPENSSL" pkcs12 -export -name "BuildTools-Signing" -out certificate.pfx -inkey private_key.key -in certificate.crt -passout "pass:$KEY_PASS"
    "$OPENSSL" pkcs12 -in certificate.pfx -nocerts -passin "pass:$KEY_PASS" -passout "pass:$KEY_PASS" -out private_key.pem 2>/dev/null
    "$OPENSSL" pkcs12 -in certificate.pfx -nokeys -clcerts -passin "pass:$KEY_PASS" -out certificate.pem 2>/dev/null
    rm -f private_key.key            # unencrypted copy no longer needed
    chmod 600 ./*
  )
  write_env "$PACKAGING_ENV" KEY_PASS
  skip "created (CN = $cn)"
}

setup_master_password() {
  log "Maven master password (~/.m2/settings-security.xml)"
  mkdir -p "$M2"
  if [ -f "$SETTINGS_SEC" ]; then skip "already present"; return; fi
  local pw enc
  pw="$("$OPENSSL" rand -base64 24)"
  enc="$(mvn --encrypt-master-password "$pw" 2>/dev/null | grep -o '{.*}' | tail -1)"
  [ -n "$enc" ] || { warn "mvn --encrypt-master-password failed - skipping"; return; }
  umask 077
  printf '<settingsSecurity>\n  <master>%s</master>\n</settingsSecurity>\n' "$enc" > "$SETTINGS_SEC"
  chmod 600 "$SETTINGS_SEC"; skip "created (random master password)"
}

# ---------------------------------------------------------- settings.xml ---
render_profile() { # emits one <profile> from the currently sourced profile env
  local ign="" auth="" login
  if [ "$P_TYPE" = "vcfa9" ]; then
    # VCF Automation 9 VM Apps: user@org + password (Build Tools VM Apps docs)
    login="$P_USER@$P_ORG"
    auth="
        <vrang.csp.host>$(xml_escape "$P_HOST")</vrang.csp.host>
        <vrang.username>$(xml_escape "$login")</vrang.username>
        <vrang.password>$(xml_escape "${P_PASSWORD:-}")</vrang.password>
        <vro.username>$(xml_escape "$login")</vro.username>
        <vro.password>$(xml_escape "${P_PASSWORD:-}")</vro.password>"
    if [ "$P_VRO_HOST" != "$P_HOST" ]; then
      auth="$auth
        <vro.authHost>$(xml_escape "$P_HOST")</vro.authHost>
        <vro.authPort>$(xml_escape "$P_PORT")</vro.authPort>"
    fi
  else
    auth="
        <vrang.refresh.token>$(xml_escape "$P_TOKEN")</vrang.refresh.token>
        <vro.refresh.token>$(xml_escape "$P_TOKEN")</vro.refresh.token>"
  fi
  [ "$P_IGNORE_CERT" = "true" ] && ign="
        <vrealize.ssl.ignore.certificate>true</vrealize.ssl.ignore.certificate>
        <vrealize.ssl.ignore.hostname>true</vrealize.ssl.ignore.hostname>"
  cat <<EOF
    <profile>
      <!-- $(xml_escape "$P_TYPE") | added $(xml_escape "$P_UPDATED") -->
      <id>$(xml_escape "$P_ID")</id>
      <properties>
        <vrang.host>$(xml_escape "$P_HOST")</vrang.host>
        <vrang.port>$(xml_escape "$P_PORT")</vrang.port>
        <vrang.org.name>$(xml_escape "$P_ORG")</vrang.org.name>
        <vrang.project.name>$(xml_escape "$P_PROJECT")</vrang.project.name>
        <vrang.vro.integration>$(xml_escape "$P_VRO_INTEGRATION")</vrang.vro.integration>
        <vrang.bp.release>true</vrang.bp.release>
        <vro.host>$(xml_escape "$P_VRO_HOST")</vro.host>
        <vro.port>$(xml_escape "$P_PORT")</vro.port>
        <vro.auth>vra</vro.auth>$auth$ign
      </properties>
    </profile>
EOF
}

render_settings() {
  log "Writing ~/.m2/settings.xml"
  mkdir -p "$M2" "$PROFILE_DIR"
  if [ -f "$SETTINGS" ] && ! grep -q "$SETTINGS_MARK" "$SETTINGS"; then
    local bak; bak="$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS" "$bak"
    warn "Existing settings.xml was not created by this script - backed up to $bak"
    warn "Mirrors / servers / proxies in it are NOT carried over; copy them back in if you need them."
  fi
  local KEY_PASS="" tmp f
  [ -f "$PACKAGING_ENV" ] && . "$PACKAGING_ENV"
  tmp="$(mktemp)"
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- $SETTINGS_MARK - regenerated on every run; edit profiles with: bt-setup.sh add-profile -->
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 http://maven.apache.org/xsd/settings-1.0.0.xsd">
  <profiles>
    <profile>
      <id>packaging</id>
      <properties>
        <vroPrivateKeyPem>$CERT_DIR/private_key.pem</vroPrivateKeyPem>
        <vroCertificatePem>$CERT_DIR/certificate.pem</vroCertificatePem>
        <vroKeyPass>$(xml_escape "$KEY_PASS")</vroKeyPass>
      </properties>
    </profile>
EOF
    for f in "$PROFILE_DIR"/*.env; do
      [ -f "$f" ] || continue
      ( . "$f"; render_profile )
    done
    cat <<EOF
  </profiles>
  <activeProfiles>
    <activeProfile>packaging</activeProfile>
  </activeProfiles>
</settings>
EOF
  } > "$tmp"
  mv "$tmp" "$SETTINGS"; chmod 600 "$SETTINGS"
  skip "profiles: packaging$(for f in "$PROFILE_DIR"/*.env; do [ -f "$f" ] && printf ', %s' "$(basename "$f" .env)"; done)"
}

# ------------------------------------------------------------------ tokens ---
fetch_token_vra8() { # sets P_TOKEN using the vRA 8 / Aria Automation 8.x login API
  local k="" pass="" resp
  [ "$P_IGNORE_CERT" = "true" ] && k="-k"
  ask_secret pass "Password for $P_USER (used once, never stored)"
  resp="$(U="$P_USER" P="$pass" D="$P_DOMAIN" node -e \
          'process.stdout.write(JSON.stringify({username:process.env.U,password:process.env.P,domain:process.env.D}))' \
        | curl -sS $k -X POST "https://$P_HOST/csp/gateway/am/api/login?access_token" \
               -H 'Content-Type: application/json' --data-binary @-)" || die "Could not reach https://$P_HOST"
  P_TOKEN="$(printf '%s' "$resp" | node -e \
      'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).refresh_token||"")}catch(e){}})')"
  [ -n "$P_TOKEN" ] || die "Login failed. Response: $(printf '%s' "$resp" | head -c 300)"
  skip "refresh token obtained"
}

get_token() {
  if [ "$P_TYPE" = "vra8" ] && [ -n "${P_TOKEN:-}" ]; then skip "using supplied token"; return; fi
  if [ "$P_TYPE" = "vcfa9" ] && [ -n "${P_PASSWORD:-}" ]; then skip "using supplied password"; return; fi
  case "$P_TYPE" in
    vra8)  fetch_token_vra8 ;;
    vcfa9) ask_secret P_PASSWORD "Password for $P_USER@$P_ORG (stored only in ~/.m2/settings.xml, mode 600)"
           P_TOKEN="" ;;
  esac
}

# ---------------------------------------------------------------- profiles ---
cmd_add_profile() {
  require_macos; load_env
  command -v node >/dev/null || die "Run './bt-setup.sh install' first."
  log "Connection profile"
  ask P_ID "Profile id (use with mvn -P<id>), e.g. lab-vcfa, cib-prod"
  P_ID="$(lower "$P_ID")"
  local existing="$PROFILE_DIR/$P_ID.env" v
  local D_P_TYPE="vra8" D_P_HOST="" D_P_PORT="443" D_P_ORG="vidm" D_P_PROJECT="" D_P_VRO_HOST=""
  local D_P_VRO_INTEGRATION="embedded-VRO" D_P_IGNORE_CERT="true" D_P_USER="configadmin" D_P_DOMAIN="System Domain"
  if [ -f "$existing" ]; then
    warn "Profile '$P_ID' exists - its current values are offered as defaults."
    eval "$( . "$existing"
             for v in P_TYPE P_HOST P_PORT P_ORG P_PROJECT P_VRO_HOST P_VRO_INTEGRATION P_IGNORE_CERT P_USER P_DOMAIN; do
               eval "printf 'D_%s=%q\n' \"$v\" \"\${$v}\""
             done )"
  fi
  ask P_TYPE "Target type: vra8 (Aria/vRA 8.x) or vcfa9 (VCF Automation 9)" "$D_P_TYPE"
  case "$P_TYPE" in vra8|vcfa9) ;; *) die "Type must be vra8 or vcfa9" ;; esac
  ask P_HOST "Automation host (FQDN)" "$D_P_HOST"
  ask P_PORT "Port" "$D_P_PORT"
  ask P_ORG "Org name (VM Apps org for vcfa9)" "$D_P_ORG"
  ask P_PROJECT "Default project" "$D_P_PROJECT"
  ask P_VRO_HOST "vRO host (same as Automation host for embedded vRO)" "${D_P_VRO_HOST:-$P_HOST}"
  ask P_VRO_INTEGRATION "vRO integration name in Automation" "$D_P_VRO_INTEGRATION"
  ask P_IGNORE_CERT "Ignore self-signed certificates? (true/false)" "$D_P_IGNORE_CERT"
  P_USER="${P_USER:-}"; P_DOMAIN="${P_DOMAIN:-}"; P_PASSWORD="${P_PASSWORD:-}"
  if [ "$P_TYPE" = "vcfa9" ]; then
    ask P_USER "Username without @org (login becomes user@$P_ORG)" "$D_P_USER"
  else
    ask P_USER "Username" "$D_P_USER"; ask P_DOMAIN "Domain (System Domain for local users)" "$D_P_DOMAIN"
  fi
  get_token
  P_UPDATED="$(date +%Y-%m-%d)"
  mkdir -p "$PROFILE_DIR"; chmod 700 "$BT_HOME" "$PROFILE_DIR"
  write_env "$existing" P_ID P_TYPE P_HOST P_PORT P_ORG P_PROJECT P_VRO_HOST P_VRO_INTEGRATION \
                        P_IGNORE_CERT P_USER P_DOMAIN P_TOKEN P_PASSWORD P_UPDATED
  render_settings
  log "Done. Push from a project folder with:"
  skip "vRO (js/ts/xml/mixed):  mvn clean package vrealize:push -DincludeDependencies=true -P$P_ID"
  skip "vRA / VM Apps:          mvn clean package vrealize:push -P$P_ID"
}

cmd_refresh_token() {
  require_macos; load_env
  local id; id="$(lower "${1:-}")"
  [ -n "$id" ] || die "Usage: bt-setup.sh refresh-token <profile-id>"
  local f="$PROFILE_DIR/$id.env"
  [ -f "$f" ] || die "No profile '$id'. Existing: $(ls "$PROFILE_DIR" 2>/dev/null | sed 's/\.env$//' | tr '\n' ' ')"
  # shellcheck disable=SC1090
  . "$f"
  log "Refreshing token for $P_ID ($P_HOST)"
  P_TOKEN=""; P_PASSWORD=""
  get_token
  P_UPDATED="$(date +%Y-%m-%d)"
  write_env "$f" P_ID P_TYPE P_HOST P_PORT P_ORG P_PROJECT P_VRO_HOST P_VRO_INTEGRATION \
                 P_IGNORE_CERT P_USER P_DOMAIN P_TOKEN P_PASSWORD P_UPDATED
  render_settings
}

# ------------------------------------------------------------- new-project ---
cmd_new_project() {
  require_macos; load_env
  command -v mvn >/dev/null || die "Run './bt-setup.sh install' first."
  log "New Build Tools project"
  ask CUST "Customer code (2-5 letters, LAB for lab, MBCOM for shared)"
  ask SCOPE "Package scope, e.g. core, network, vm (lower case)"
  ask PTYPE "Type: js (ES5 actions) | xml (workflows) | mixed | ts (TypeScript) | vra" "${PTYPE:-mixed}"
  local cust scope arch ver dir
  cust="$(lower "$CUST")"; scope="$(lower "$SCOPE")"
  local group="$ARCHETYPE_GROUP"
  case "$PTYPE" in
    js)    arch="package-actions-archetype" ;;
    xml)   arch="package-xml-archetype" ;;
    mixed) arch="package-mixed-archetype" ;;
    ts)    arch="package-typescript-archetype" ;;
    vra)   arch="package-vra-ng-archetype"; group="com.vmware.pscoe.vra-ng.archetypes" ;;
    *) die "Unknown type '$PTYPE'" ;;
  esac
  ver="$(resolve_bt_version)"
  curl -fsS -o /dev/null "$CENTRAL/${group//.//}/$arch/$ver/" 2>/dev/null \
    || die "Archetype $arch $ver not found on Maven Central."
  dir="${PROJECT_ROOT:-$HOME/BuildTools/$(printf '%s' "$CUST" | tr '[:lower:]' '[:upper:]')}"
  mkdir -p "$dir"
  [ -e "$dir/$scope" ] && die "$dir/$scope already exists."
  skip "package com.$cust.$scope  |  $arch $ver  |  $dir/$scope"
  ( cd "$dir" && mvn -B -q archetype:generate \
      -DarchetypeGroupId="$group" -DarchetypeArtifactId="$arch" -DarchetypeVersion="$ver" \
      -DgroupId="com.$cust" -DartifactId="$scope" )
  log "Created $dir/$scope"
}

# ------------------------------------------------------------------ doctor ---
cmd_doctor() {
  require_macos; load_env
  check_versions
  log "Files"
  local f
  for f in "$SETTINGS" "$SETTINGS_SEC" "$CERT_DIR/private_key.pem" "$CERT_DIR/certificate.pem"; do
    [ -f "$f" ] && echo "    ok       $f" || echo "    MISSING  $f"
  done
  if [ -f "$CERT_DIR/certificate.pem" ]; then
    echo "    cert expires: $("$OPENSSL" x509 -in "$CERT_DIR/certificate.pem" -noout -enddate | cut -d= -f2)"
  fi
  log "npm cache: ${npm_config_cache:-$HOME/.npm (default)}"
  if [ -n "$(find "$HOME/.npm" ! -user "$(id -un)" -print -quit 2>/dev/null)" ]; then
    warn "~/.npm has files you don't own - fix with: sudo chown -R \$(id -u):\$(id -g) ~/.npm"
  fi
  log "Latest Build Tools on Maven Central: $(resolve_bt_version 2>/dev/null || echo unknown)"
  log "Profiles"
  for f in "$PROFILE_DIR"/*.env; do
    [ -f "$f" ] || { skip "none - run: bt-setup.sh add-profile"; break; }
    ( . "$f"
      code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$P_HOST/" || true)"
      printf '    %-16s %-6s %-30s token %s  reach %s\n' "$P_ID" "$P_TYPE" "$P_HOST" "$P_UPDATED" "${code:-fail}" )
  done
}

# ----------------------------------------------------------------- install ---
cmd_install() {
  require_macos
  install_tools
  install_maven
  write_shell_block
  check_versions
  setup_vscode
  setup_cert
  setup_master_password
  render_settings
  if [ -z "${BT_SKIP_PROFILE:-}" ] && [ -z "$(ls "$PROFILE_DIR" 2>/dev/null)" ] && yesno "Add a connection profile now?" y; then
    cmd_add_profile
  fi
  log "All set. Open a NEW terminal (or run: source ~/.zprofile) so JAVA_HOME/PATH apply."
}

usage() { sed -n "2,21p" "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  install)        cmd_install ;;
  add-profile)    cmd_add_profile ;;
  refresh-token)  shift; cmd_refresh_token "${1:-}" ;;
  new-project)    cmd_new_project ;;
  doctor)         cmd_doctor ;;
  *)              usage ;;
esac
