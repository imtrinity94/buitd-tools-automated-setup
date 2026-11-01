<#
.SYNOPSIS
  Build Tools for VMware Aria - workstation setup for Windows.

.DESCRIPTION
  Commands (all re-runnable; anything already in place is skipped):
    install                 JDK 21, Node 22, Maven 3.9.x (user-space zips, checksum verified),
                            Git (for OpenSSL), VS Code + vRealize Developer Tools, signing cert,
                            Maven master password, settings.xml, user environment variables
    add-profile             Add / update a connection profile (vra8 or vcfa9)
    refresh-token <id>      Re-enter the password / re-fetch the token for a profile
    new-project             Scaffold a Build Tools project from an archetype
    selftest                Scaffold, build and sign a throwaway project (no server needed)
    doctor                  Show versions, files, profiles and host reachability

  Run it with:
    powershell -ExecutionPolicy Bypass -File .\bt-setup.ps1 install

  Prompts can be pre-answered with parameters, e.g.
    .\bt-setup.ps1 add-profile -ProfileId lab-vcfa -Type vcfa9 -HostName vcfa.example.local `
                   -Org my-vmapps-org -Project LAB-BuildTools -User admin
    .\bt-setup.ps1 new-project -Cust LAB -Scope bttest -ProjectType ts -MavenProfile lab-vcfa

  Works on Windows PowerShell 5.1 and PowerShell 7+. No administrator rights needed
  (only Git / VS Code may be installed through winget if they are missing).
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = '',
  [Parameter(Position = 1)][string]$Target = '',
  # add-profile
  [string]$ProfileId, [string]$Type, [string]$HostName, [string]$Port, [string]$Org,
  [string]$Project, [string]$VroHost, [string]$VroIntegration, [string]$IgnoreCert,
  [string]$User, [string]$Domain,
  # new-project
  [string]$Cust, [string]$Scope, [string]$ProjectType, [string]$MavenProfile, [string]$ProjectRoot,
  # versions
  [string]$BuildToolsVersion = $env:BT_VERSION,
  [string]$MavenVersion = '3.9.16',
  [string]$JdkMajor = '21',
  [string]$NodeMajor = '22',
  [switch]$SkipProfilePrompt
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on 5.1
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# ------------------------------------------------------------------ paths ---
$BtHome       = Join-Path $env:USERPROFILE '.buildtools'
$ToolsDir     = Join-Path $BtHome 'tools'
$ProfileDir   = Join-Path $BtHome 'profiles'
$CertDir      = Join-Path $BtHome 'certs'
$PackagingCfg = Join-Path $BtHome 'packaging.json'
$M2           = Join-Path $env:USERPROFILE '.m2'
$SettingsXml  = Join-Path $M2 'settings.xml'
$SettingsSec  = Join-Path $M2 'settings-security.xml'
$SettingsMark = 'managed-by: bt-setup.ps1'
$Central      = 'https://repo1.maven.org/maven2'
$ArchetypeGroup = 'com.vmware.pscoe.o11n.archetypes'
$VsCodeExt    = 'vmware-pscoe.vrealize-developer-tools'
$VsCodeUserSettings = Join-Path $env:APPDATA 'Code\User\settings.json'
$MavenHome    = Join-Path $ToolsDir "apache-maven-$MavenVersion"
$Arch = 'x64'
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $Arch = 'arm64' }

# ---------------------------------------------------------------- helpers ---
function Log($m)  { Write-Host "==> $m" -ForegroundColor Green }
function Skip($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Warn($m) { Write-Host "!!  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Ask([string]$Value, [string]$Prompt, [string]$Default = '') {
  if ($Value) { return $Value }
  while ($true) {
    if ($Default) { $a = Read-Host "    $Prompt [$Default]"; if (-not $a) { $a = $Default } }
    else          { $a = Read-Host "    $Prompt" }
    if ($a) { return $a }
  }
}

function AskSecret([string]$Prompt, [switch]$Confirm) {
  while ($true) {
    $s = Read-Host "    $Prompt" -AsSecureString
    $p = SecureToPlain $s
    if (-not $p) { continue }
    if (-not $Confirm) { return $p }
    $p2 = SecureToPlain (Read-Host '    Confirm' -AsSecureString)
    if ($p -eq $p2) { return $p }
    Warn 'Did not match, try again.'
  }
}

function SecureToPlain([Security.SecureString]$s) {
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# DPAPI: encrypted for the current Windows user only
function Protect([string]$plain) {
  if (-not $plain) { return '' }
  return (ConvertTo-SecureString $plain -AsPlainText -Force | ConvertFrom-SecureString)
}
function Unprotect([string]$enc) {
  if (-not $enc) { return '' }
  return SecureToPlain (ConvertTo-SecureString $enc)
}

function XmlEsc([string]$s) { return [Security.SecurityElement]::Escape([string]$s) }

function Restrict-ToUser([string]$path) {
  # Remove inherited ACEs; only the current user (and SYSTEM) keep access
  $flags = ':(OI)(CI)F'
  if (Test-Path $path -PathType Leaf) { $flags = ':F' }
  $me = "$env:USERDOMAIN\$env:USERNAME"
  Quiet { & icacls.exe $path /inheritance:r /grant:r "$me$flags" /grant:r "*S-1-5-18$flags" 2>&1 | Out-Null }
  if ($LASTEXITCODE -ne 0) { Warn "Could not restrict permissions on $path" }
}

function Quiet([scriptblock]$__block) {
  # Windows PowerShell 5.1 turns redirected native stderr into errors; with
  # ErrorActionPreference=Stop that aborts the script. Run natives with Continue.
  $ErrorActionPreference = 'Continue'
  & $__block
}

function Random-Hex([int]$bytes) {
  $b = New-Object byte[] $bytes
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($b); $rng.Dispose()
  return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Ensure-Dir([string]$p) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }

function Write-Utf8NoBom([string]$path, [string]$text) {
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

function Download([string]$url, [string]$out) {
  Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
}

function Get-Hash([string]$path, [string]$algo) { return (Get-FileHash -Path $path -Algorithm $algo).Hash.ToLower() }

function Expand-Zip([string]$zip, [string]$dest) {
  # ZipFile is much faster than Expand-Archive on 5.1 (the JDK has thousands of files)
  Ensure-Dir $dest
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
}

function Add-UserPath([string[]]$dirs) {
  $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $cur) { $cur = '' }
  $parts = @($cur -split ';' | Where-Object { $_ -and ($dirs -notcontains $_) })
  # drop older copies managed by this script (other versions under .buildtools\tools)
  $parts = @($parts | Where-Object { $_ -notlike "$ToolsDir*" })
  $new = (@($dirs) + $parts) -join ';'
  if ($new -ne $cur) {
    [Environment]::SetEnvironmentVariable('Path', $new, 'User')
    Skip 'user PATH updated'
  } else { Skip 'user PATH already up to date' }
  # current session too
  $env:Path = ((@($dirs) + @($env:Path -split ';' | Where-Object { $_ -and ($dirs -notcontains $_) })) -join ';')
}

function Find-Dir([string]$parent, [string]$pattern) {
  if (-not (Test-Path $parent)) { return $null }
  $d = Get-ChildItem -Path $parent -Directory -Filter $pattern -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($d) { return $d.FullName } else { return $null }
}

function Jdk-Home  { return (Find-Dir $ToolsDir "jdk-$JdkMajor*") }
function Node-Home { return (Find-Dir $ToolsDir "node-v$NodeMajor*") }

function Load-Env {
  $jdk = Jdk-Home; $node = Node-Home
  $dirs = @()
  if (Test-Path (Join-Path $MavenHome 'bin')) { $dirs += (Join-Path $MavenHome 'bin') }
  if ($jdk)  { $env:JAVA_HOME = $jdk; $dirs += (Join-Path $jdk 'bin') }
  if ($node) { $dirs += $node }
  if ($dirs.Count -gt 0) { $env:Path = ((@($dirs) + @($env:Path -split ';' | Where-Object { $_ -and ($dirs -notcontains $_) })) -join ';') }
}

function Find-OpenSsl {
  $cands = @(
    (Join-Path $env:ProgramFiles 'Git\usr\bin\openssl.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\usr\bin\openssl.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git\usr\bin\openssl.exe')
  )
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
  $cmd = Get-Command openssl.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Find-Code {
  $cands = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
    (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')
  )
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }
  $cmd = Get-Command code.cmd -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Has-Winget { return [bool](Get-Command winget.exe -ErrorAction SilentlyContinue) }

function Resolve-BtVersion {
  if ($BuildToolsVersion) { return $BuildToolsVersion }
  $url = "$Central/$($ArchetypeGroup -replace '\.', '/')/package-typescript-archetype/maven-metadata.xml"
  try {
    [xml]$x = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
    $v = $x.metadata.versioning.release
    if ($v) { $script:BuildToolsVersion = $v; return $v }
  } catch { }
  Die 'Could not look up the latest Build Tools version on Maven Central. Re-run with -BuildToolsVersion x.y.z'
}

function Invoke-Native([string]$exe, [string[]]$argList) {
  # Arguments are passed as an array, so -Dfoo.bar=baz is not split by PowerShell
  Quiet { & $exe @argList }
  if ($LASTEXITCODE -ne 0) { throw "$(Split-Path $exe -Leaf) exited with code $LASTEXITCODE" }
}

# ---------------------------------------------------------------- install ---
function Install-Jdk {
  Log "Temurin JDK $JdkMajor ($ToolsDir)"
  if (Jdk-Home) { Skip "already installed ($(Split-Path (Jdk-Home) -Leaf))"; return }
  $a = 'x64'; if ($Arch -eq 'arm64') { $a = 'aarch64' }
  $api = "https://api.adoptium.net/v3/assets/latest/$JdkMajor/hotspot?os=windows&architecture=$a&image_type=jdk&vendor=eclipse"
  $assets = Invoke-RestMethod -Uri $api -UseBasicParsing
  $pkg = $null
  foreach ($as in @($assets)) { if ($as.binary.package.name -like '*.zip') { $pkg = $as.binary.package; break } }
  if (-not $pkg) { Die "No Temurin $JdkMajor zip found for windows/$a" }
  $zip = Join-Path $env:TEMP $pkg.name
  Download $pkg.link $zip
  if ((Get-Hash $zip 'SHA256') -ne $pkg.checksum.ToLower()) { Remove-Item $zip -Force; Die 'JDK checksum mismatch - not installing.' }
  Expand-Zip $zip $ToolsDir
  Remove-Item $zip -Force
  Skip "installed $($pkg.name) (checksum verified)"
}

function Install-Node {
  Log "Node.js $NodeMajor ($ToolsDir)"
  if (Node-Home) { Skip "already installed ($(Split-Path (Node-Home) -Leaf))"; return }
  $base = "https://nodejs.org/dist/latest-v$NodeMajor.x"
  $sums = (Invoke-WebRequest -Uri "$base/SHASUMS256.txt" -UseBasicParsing).Content
  $line = ($sums -split "`n" | Where-Object { $_ -match "node-v[\d\.]+-win-$Arch\.zip\s*$" } | Select-Object -First 1)
  if (-not $line) { Die "No Node $NodeMajor zip found for win-$Arch" }
  $parts = $line.Trim() -split '\s+'
  $want = $parts[0].ToLower(); $name = $parts[1]
  $zip = Join-Path $env:TEMP $name
  Download "$base/$name" $zip
  if ((Get-Hash $zip 'SHA256') -ne $want) { Remove-Item $zip -Force; Die 'Node checksum mismatch - not installing.' }
  Expand-Zip $zip $ToolsDir
  Remove-Item $zip -Force
  Skip "installed $name (checksum verified)"
}

function Install-Maven {
  Log "Apache Maven $MavenVersion ($MavenHome)"
  if (Test-Path (Join-Path $MavenHome 'bin\mvn.cmd')) { Skip 'already installed'; return }
  $name = "apache-maven-$MavenVersion-bin.zip"
  $zip = Join-Path $env:TEMP $name
  $ok = $false
  foreach ($base in @("https://dlcdn.apache.org/maven/maven-3/$MavenVersion/binaries",
                      "https://archive.apache.org/dist/maven/maven-3/$MavenVersion/binaries")) {
    try {
      Download "$base/$name" $zip
      $want = ((Invoke-WebRequest -Uri "$base/$name.sha512" -UseBasicParsing).Content -split '\s+')[0].ToLower()
      $ok = $true; break
    } catch { }
  }
  if (-not $ok) { Die "Could not download Maven $MavenVersion from apache.org" }
  if ((Get-Hash $zip 'SHA512') -ne $want) { Remove-Item $zip -Force; Die 'Maven checksum mismatch - not installing.' }
  Expand-Zip $zip $ToolsDir
  Remove-Item $zip -Force
  Skip 'installed (checksum verified)'
}

function Install-Git {
  Log 'Git for Windows (provides openssl.exe)'
  if (Find-OpenSsl) { Skip "openssl found: $(Find-OpenSsl)"; return }
  if (-not (Has-Winget)) { Die 'openssl.exe not found and winget is not available. Install Git for Windows from https://git-scm.com and re-run.' }
  Quiet { & winget.exe install --id Git.Git -e --scope user --silent --accept-package-agreements --accept-source-agreements }
  if (-not (Find-OpenSsl)) {
    Quiet { & winget.exe install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements }
  }
  if (-not (Find-OpenSsl)) { Die 'Git installed but openssl.exe still not found - open a new terminal and re-run.' }
  Skip "openssl: $(Find-OpenSsl)"
}

function Install-VsCode {
  Log 'Visual Studio Code'
  if (Find-Code) { Skip "already installed ($(Find-Code))"; return }
  if (-not (Has-Winget)) { Warn 'VS Code not found and winget is not available - install it from https://code.visualstudio.com, then re-run.'; return }
  Quiet { & winget.exe install --id Microsoft.VisualStudioCode -e --scope user --silent --accept-package-agreements --accept-source-agreements }
  if (Find-Code) { Skip 'installed' } else { Warn 'VS Code install did not finish - re-run later.' }
}

function Set-UserEnv {
  Log 'User environment variables'
  $jdk = Jdk-Home; $node = Node-Home
  if (-not $jdk -or -not $node) { Die 'JDK or Node missing - run install again.' }
  if ([Environment]::GetEnvironmentVariable('JAVA_HOME', 'User') -ne $jdk) {
    [Environment]::SetEnvironmentVariable('JAVA_HOME', $jdk, 'User'); Skip "JAVA_HOME = $jdk"
  } else { Skip 'JAVA_HOME already set' }
  Add-UserPath @((Join-Path $MavenHome 'bin'), (Join-Path $jdk 'bin'), $node)
  # npm cache: the default (%LOCALAPPDATA%\npm-cache) is fine on Windows; nothing to change.
  Load-Env
}

function Check-Versions {
  Log 'Checking versions'
  $j = Quiet { & java.exe -version 2>&1 | Select-Object -First 1 | ForEach-Object { "$_" } }; Skip "$j"
  $m = Quiet { & mvn.cmd -v 2>$null | Select-Object -First 1 }; Skip "$m"
  if ("$m" -notmatch 'Maven 3\.9') { Warn "Expected Maven 3.9.x but got: $m" }
  $nv = Quiet { & node.exe -v 2>$null }; $npv = Quiet { & npm.cmd -v 2>$null }
  Skip "node $nv   npm $npv"
}

function Setup-VsCodeExt {
  Log 'VS Code extension (vRealize Developer Tools)'
  $code = Find-Code
  if (-not $code) { Warn 'VS Code CLI not found - skipping extension'; return }
  $list = @(Quiet { & $code --list-extensions 2>$null })
  if ($list -contains $VsCodeExt) { Skip 'already installed' }
  else {
    Quiet { & $code --install-extension $VsCodeExt 2>&1 | Out-Null }
    if (@(Quiet { & $code --list-extensions 2>$null }) -contains $VsCodeExt) { Skip "installed $VsCodeExt" }
    else { Die "Could not install VS Code extension $VsCodeExt" }
  }
  $ver = Resolve-BtVersion
  Ensure-Dir (Split-Path $VsCodeUserSettings)
  $obj = $null; $parseFailed = $false
  if (Test-Path $VsCodeUserSettings) {
    $raw = Get-Content $VsCodeUserSettings -Raw
    if ($raw -and $raw.Trim()) {
      try { $obj = $raw | ConvertFrom-Json } catch { $parseFailed = $true }
    }
  }
  if ($parseFailed) {
    Warn "VS Code settings.json has comments or is not plain JSON - set 'Vrdev > Build Tools: Default Version' to $ver by hand"; return
  }
  if (-not $obj) { $obj = New-Object PSObject }
  $cur = $null
  if ($obj.PSObject.Properties['vrdev.buildTools.defaultVersion']) { $cur = $obj.'vrdev.buildTools.defaultVersion' }
  if ($cur -eq $ver) { Skip "vrdev.buildTools.defaultVersion already $ver"; return }
  $obj | Add-Member -NotePropertyName 'vrdev.buildTools.defaultVersion' -NotePropertyValue $ver -Force
  Write-Utf8NoBom $VsCodeUserSettings ($obj | ConvertTo-Json -Depth 20)
  Skip "set vrdev.buildTools.defaultVersion = $ver"
}

function Setup-Cert {
  Log "Package signing certificate ($CertDir)"
  if ((Test-Path (Join-Path $CertDir 'private_key.pem')) -and (Test-Path (Join-Path $CertDir 'certificate.pem')) -and (Test-Path $PackagingCfg)) {
    Skip 'already present'; return
  }
  $openssl = Find-OpenSsl
  if (-not $openssl) { Die 'openssl.exe not found (install Git for Windows).' }
  Ensure-Dir $CertDir; Restrict-ToUser $BtHome
  $keyPass = Random-Hex 16
  $cn = "$env:USERNAME Build Tools Signing"
  $cfg = @"
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
"@
  Write-Utf8NoBom (Join-Path $CertDir 'certificate.cfg') $cfg
  Push-Location $CertDir
  try {
    $env:BT_KEYPASS = $keyPass
    Invoke-Native $openssl @('genrsa', '-out', 'private_key.key', '2048')
    Invoke-Native $openssl @('req', '-new', '-x509', '-sha256', '-days', '3650', '-key', 'private_key.key', '-out', 'certificate.crt', '-config', 'certificate.cfg')
    Invoke-Native $openssl @('pkcs12', '-export', '-name', 'BuildTools-Signing', '-out', 'certificate.pfx', '-inkey', 'private_key.key', '-in', 'certificate.crt', '-passout', 'env:BT_KEYPASS')
    Invoke-Native $openssl @('pkcs12', '-in', 'certificate.pfx', '-nocerts', '-passin', 'env:BT_KEYPASS', '-passout', 'env:BT_KEYPASS', '-out', 'private_key.pem')
    Invoke-Native $openssl @('pkcs12', '-in', 'certificate.pfx', '-nokeys', '-clcerts', '-passin', 'env:BT_KEYPASS', '-out', 'certificate.pem')
    Remove-Item 'private_key.key' -Force
  } finally { Remove-Item env:BT_KEYPASS -ErrorAction SilentlyContinue; Pop-Location }
  Write-Utf8NoBom $PackagingCfg (@{ keyPass = (Protect $keyPass) } | ConvertTo-Json)
  Skip "created (CN = $cn); key password is DPAPI-encrypted in $PackagingCfg"
}

function Setup-MasterPassword {
  Log 'Maven master password (~\.m2\settings-security.xml)'
  Ensure-Dir $M2
  if (Test-Path $SettingsSec) { Skip 'already present'; return }
  $pw = Random-Hex 24
  $out = Quiet { & mvn.cmd --encrypt-master-password $pw 2>$null }
  $enc = ($out | Select-String -Pattern '\{.*\}' | Select-Object -Last 1)
  if (-not $enc) { Warn 'mvn --encrypt-master-password failed - skipping'; return }
  $val = $enc.Matches[0].Value
  Write-Utf8NoBom $SettingsSec "<settingsSecurity>`r`n  <master>$val</master>`r`n</settingsSecurity>`r`n"
  Skip 'created (random master password)'
}

# ------------------------------------------------------------ settings.xml ---
function Get-Profiles {
  if (-not (Test-Path $ProfileDir)) { return @() }
  $r = @()
  foreach ($f in (Get-ChildItem $ProfileDir -Filter '*.json' | Sort-Object Name)) {
    $r += (Get-Content $f.FullName -Raw | ConvertFrom-Json)
  }
  return $r
}

function Render-Profile($p) {
  $pw = Unprotect $p.Password
  $tok = Unprotect $p.Token
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine('    <profile>')
  [void]$sb.AppendLine("      <!-- $(XmlEsc $p.Type) | updated $(XmlEsc $p.Updated) -->")
  [void]$sb.AppendLine("      <id>$(XmlEsc $p.Id)</id>")
  [void]$sb.AppendLine('      <properties>')
  [void]$sb.AppendLine("        <vrang.host>$(XmlEsc $p.Host)</vrang.host>")
  [void]$sb.AppendLine("        <vrang.port>$(XmlEsc $p.Port)</vrang.port>")
  [void]$sb.AppendLine("        <vrang.org.name>$(XmlEsc $p.Org)</vrang.org.name>")
  [void]$sb.AppendLine("        <vrang.project.name>$(XmlEsc $p.Project)</vrang.project.name>")
  [void]$sb.AppendLine("        <vrang.vro.integration>$(XmlEsc $p.VroIntegration)</vrang.vro.integration>")
  [void]$sb.AppendLine('        <vrang.bp.release>true</vrang.bp.release>')
  [void]$sb.AppendLine("        <vro.host>$(XmlEsc $p.VroHost)</vro.host>")
  [void]$sb.AppendLine("        <vro.port>$(XmlEsc $p.Port)</vro.port>")
  [void]$sb.AppendLine('        <vro.auth>vra</vro.auth>')
  if ($p.Type -eq 'vcfa9') {
    $login = "$($p.User)@$($p.Org)"
    [void]$sb.AppendLine("        <vrang.csp.host>$(XmlEsc $p.Host)</vrang.csp.host>")
    [void]$sb.AppendLine("        <vrang.username>$(XmlEsc $login)</vrang.username>")
    [void]$sb.AppendLine("        <vrang.password>$(XmlEsc $pw)</vrang.password>")
    [void]$sb.AppendLine("        <vro.username>$(XmlEsc $login)</vro.username>")
    [void]$sb.AppendLine("        <vro.password>$(XmlEsc $pw)</vro.password>")
    if ($p.VroHost -ne $p.Host) {
      [void]$sb.AppendLine("        <vro.authHost>$(XmlEsc $p.Host)</vro.authHost>")
      [void]$sb.AppendLine("        <vro.authPort>$(XmlEsc $p.Port)</vro.authPort>")
    }
  } else {
    [void]$sb.AppendLine("        <vrang.refresh.token>$(XmlEsc $tok)</vrang.refresh.token>")
    [void]$sb.AppendLine("        <vro.refresh.token>$(XmlEsc $tok)</vro.refresh.token>")
  }
  if ($p.IgnoreCert -eq 'true') {
    [void]$sb.AppendLine('        <vrealize.ssl.ignore.certificate>true</vrealize.ssl.ignore.certificate>')
    [void]$sb.AppendLine('        <vrealize.ssl.ignore.hostname>true</vrealize.ssl.ignore.hostname>')
  }
  [void]$sb.AppendLine('      </properties>')
  [void]$sb.AppendLine('    </profile>')
  return $sb.ToString()
}

function Render-Settings {
  Log 'Writing ~\.m2\settings.xml'
  Ensure-Dir $M2; Ensure-Dir $ProfileDir
  if ((Test-Path $SettingsXml) -and -not (Select-String -Path $SettingsXml -Pattern $SettingsMark -SimpleMatch -Quiet)) {
    $bak = "$SettingsXml.bak-$(Get-Date -Format yyyyMMddHHmmss)"
    Copy-Item $SettingsXml $bak
    Warn "Existing settings.xml was not created by this script - backed up to $bak"
    Warn 'Mirrors / servers / proxies in it are NOT carried over; copy them back in if you need them.'
  }
  $keyPass = ''
  if (Test-Path $PackagingCfg) { $keyPass = Unprotect ((Get-Content $PackagingCfg -Raw | ConvertFrom-Json).keyPass) }
  $priv = (Join-Path $CertDir 'private_key.pem') -replace '\\', '/'
  $cert = (Join-Path $CertDir 'certificate.pem') -replace '\\', '/'
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
  [void]$sb.AppendLine("<!-- $SettingsMark - regenerated on every run; edit profiles with: bt-setup.ps1 add-profile -->")
  [void]$sb.AppendLine('<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"')
  [void]$sb.AppendLine('          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"')
  [void]$sb.AppendLine('          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 http://maven.apache.org/xsd/settings-1.0.0.xsd">')
  [void]$sb.AppendLine('  <profiles>')
  [void]$sb.AppendLine('    <profile>')
  [void]$sb.AppendLine('      <id>packaging</id>')
  [void]$sb.AppendLine('      <properties>')
  [void]$sb.AppendLine("        <vroPrivateKeyPem>$(XmlEsc $priv)</vroPrivateKeyPem>")
  [void]$sb.AppendLine("        <vroCertificatePem>$(XmlEsc $cert)</vroCertificatePem>")
  [void]$sb.AppendLine("        <vroKeyPass>$(XmlEsc $keyPass)</vroKeyPass>")
  [void]$sb.AppendLine('      </properties>')
  [void]$sb.AppendLine('    </profile>')
  $ids = @('packaging')
  foreach ($p in (Get-Profiles)) { [void]$sb.Append((Render-Profile $p)); $ids += $p.Id }
  [void]$sb.AppendLine('  </profiles>')
  [void]$sb.AppendLine('  <activeProfiles>')
  [void]$sb.AppendLine('    <activeProfile>packaging</activeProfile>')
  [void]$sb.AppendLine('  </activeProfiles>')
  [void]$sb.AppendLine('</settings>')
  Write-Utf8NoBom $SettingsXml $sb.ToString()
  Restrict-ToUser $SettingsXml
  Skip "profiles: $($ids -join ', ')"
}

# ------------------------------------------------------------------ tokens ---
function Disable-CertCheck {
  if ($PSVersionTable.PSVersion.Major -ge 6) { return }   # PS 7 uses -SkipCertificateCheck
  if (-not ('BtTrustAll' -as [type])) {
    Add-Type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class BtTrustAll : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint sp, X509Certificate c, WebRequest r, int p) { return true; }
}
"@
  }
  [Net.ServicePointManager]::CertificatePolicy = New-Object BtTrustAll
}

function Fetch-TokenVra8($p, [string]$password) {
  $body = @{ username = $p.User; password = $password; domain = $p.Domain } | ConvertTo-Json
  $uri = "https://$($p.Host)/csp/gateway/am/api/login?access_token"
  $irm = @{ Uri = $uri; Method = 'Post'; Body = $body; ContentType = 'application/json' }
  if ($p.IgnoreCert -eq 'true') {
    if ($PSVersionTable.PSVersion.Major -ge 6) { $irm['SkipCertificateCheck'] = $true } else { Disable-CertCheck }
  }
  try { $r = Invoke-RestMethod @irm } catch { Die "Login to https://$($p.Host) failed: $($_.Exception.Message)" }
  if (-not ($r -and $r.PSObject.Properties['refresh_token'] -and $r.refresh_token)) { Die 'Login response had no refresh_token.' }
  Skip 'refresh token obtained'
  return $r.refresh_token
}

function Get-Credential-For($p) {
  if ($p.Type -eq 'vcfa9') {
    $pw = AskSecret "Password for $($p.User)@$($p.Org) (written to ~\.m2\settings.xml, user-only ACL)"
    $p.Password = Protect $pw; $p.Token = ''
  } else {
    $pw = AskSecret "Password for $($p.User) (used once, never stored)"
    $p.Token = Protect (Fetch-TokenVra8 $p $pw); $p.Password = ''
  }
}

function Save-Profile($p) {
  Ensure-Dir $ProfileDir; Restrict-ToUser $BtHome
  $p.Updated = (Get-Date -Format 'yyyy-MM-dd')
  Write-Utf8NoBom (Join-Path $ProfileDir "$($p.Id).json") ($p | ConvertTo-Json)
}

# --------------------------------------------------------------- commands ---
function Cmd-AddProfile {
  Load-Env
  Log 'Connection profile'
  $id = (Ask $ProfileId 'Profile id (use with mvn -P<id>), e.g. lab-vcfa, cib-prod').ToLower()
  $file = Join-Path $ProfileDir "$id.json"
  $d = [ordered]@{ Type = 'vra8'; Host = ''; Port = '443'; Org = 'vidm'; Project = ''; VroHost = '';
                   VroIntegration = 'embedded-VRO'; IgnoreCert = 'true'; User = 'configadmin'; Domain = 'System Domain' }
  if (Test-Path $file) {
    Warn "Profile '$id' exists - its current values are offered as defaults."
    $old = Get-Content $file -Raw | ConvertFrom-Json
    foreach ($k in @($d.Keys)) { if ($old.PSObject.Properties[$k] -and $old.$k) { $d[$k] = $old.$k } }
  }
  $p = [pscustomobject][ordered]@{ Id = $id; Type = ''; Host = ''; Port = ''; Org = ''; Project = ''; VroHost = '';
                                   VroIntegration = ''; IgnoreCert = ''; User = ''; Domain = ''; Password = ''; Token = ''; Updated = '' }
  $p.Type = Ask $Type 'Target type: vra8 (Aria/vRA 8.x) or vcfa9 (VCF Automation 9)' $d.Type
  if (@('vra8', 'vcfa9') -notcontains $p.Type) { Die 'Type must be vra8 or vcfa9' }
  $p.Host = Ask $HostName 'Automation host (FQDN)' $d.Host
  $p.Port = Ask $Port 'Port' $d.Port
  $p.Org = Ask $Org 'Org name (VM Apps org for vcfa9)' $d.Org
  $p.Project = Ask $Project 'Default project' $d.Project
  $vd = $d.VroHost; if (-not $vd) { $vd = $p.Host }
  $p.VroHost = Ask $VroHost 'vRO host (same as Automation host for embedded vRO)' $vd
  $p.VroIntegration = Ask $VroIntegration 'vRO integration name in Automation' $d.VroIntegration
  $p.IgnoreCert = Ask $IgnoreCert 'Ignore self-signed certificates? (true/false)' $d.IgnoreCert
  if ($p.Type -eq 'vcfa9') {
    $p.User = Ask $User "Username without @org (login becomes user@$($p.Org))" $d.User
  } else {
    $p.User = Ask $User 'Username' $d.User
    $p.Domain = Ask $Domain 'Domain (System Domain for local users)' $d.Domain
  }
  Get-Credential-For $p
  Save-Profile $p
  Render-Settings
  Log 'Done. Push from a project folder with:'
  Skip "mvn clean package vrealize:push -P$id"
  Skip "(VM Apps projects use the same vrealize:push goal; pull them with: mvn vra-ng:pull -P$id)"
}

function Cmd-RefreshToken {
  Load-Env
  $id = $Target.ToLower()
  if (-not $id) { Die 'Usage: bt-setup.ps1 refresh-token <profile-id>' }
  $file = Join-Path $ProfileDir "$id.json"
  if (-not (Test-Path $file)) { Die "No profile '$id'. Existing: $((Get-Profiles | ForEach-Object { $_.Id }) -join ', ')" }
  $p = Get-Content $file -Raw | ConvertFrom-Json
  Log "Refreshing credentials for $($p.Id) ($($p.Host))"
  Get-Credential-For $p
  Save-Profile $p
  Render-Settings
}

function Cmd-NewProject {
  Load-Env
  if (-not (Get-Command mvn.cmd -ErrorAction SilentlyContinue)) { Die 'Run "bt-setup.ps1 install" first.' }
  Log 'New Build Tools project'
  $c = Ask $Cust 'Customer code (2-5 letters, LAB for lab, MBCOM for shared)'
  $s = (Ask $Scope 'Package scope, e.g. core, network, vm (lower case)').ToLower()
  $t = Ask $ProjectType 'Type: js (ES5 actions) | xml (workflows) | mixed | ts (TypeScript) | vra' 'mixed'
  $group = $ArchetypeGroup
  switch ($t) {
    'js'    { $arch = 'package-actions-archetype' }
    'xml'   { $arch = 'package-xml-archetype' }
    'mixed' { $arch = 'package-mixed-archetype' }
    'ts'    { $arch = 'package-typescript-archetype' }
    'vra'   { $arch = 'package-vra-ng-archetype'; $group = 'com.vmware.pscoe.vra-ng.archetypes' }
    default { Die "Unknown type '$t'" }
  }
  $ver = Resolve-BtVersion
  $root = $ProjectRoot
  if (-not $root) { $root = Join-Path (Join-Path $env:USERPROFILE 'BuildTools') $c.ToUpper() }
  Ensure-Dir $root
  $dir = Join-Path $root $s
  if (Test-Path $dir) { Die "$dir already exists." }
  Skip "package com.$($c.ToLower()).$s  |  $arch $ver  |  $dir"
  Push-Location $root
  try {
    Invoke-Native 'mvn.cmd' @('-B', '-q', 'archetype:generate',
      "-DarchetypeGroupId=$group", "-DarchetypeArtifactId=$arch", "-DarchetypeVersion=$ver",
      "-DgroupId=com.$($c.ToLower())", "-DartifactId=$s")
  } finally { Pop-Location }

  # vRealize Developer Tools needs vrdev.maven.profile per project
  $first = ''
  $profiles = @(Get-Profiles)
  if ($profiles.Count -gt 0) { $first = $profiles[0].Id }
  $mp = $MavenProfile
  if (-not $mp -and $first) { $mp = Ask '' 'Maven profile for VS Code (vrdev.maven.profile)' $first }
  if ($mp) {
    $vs = Join-Path $dir '.vscode'; Ensure-Dir $vs
    $f = Join-Path $vs 'settings.json'
    $o = New-Object PSObject
    if (Test-Path $f) { try { $o = Get-Content $f -Raw | ConvertFrom-Json } catch { $o = New-Object PSObject } }
    $o | Add-Member -NotePropertyName 'vrdev.maven.profile' -NotePropertyValue $mp -Force
    Write-Utf8NoBom $f ($o | ConvertTo-Json -Depth 20)
    Skip "VS Code: vrdev.maven.profile = $mp"
  } else {
    Warn "No connection profile yet - after add-profile, set vrdev.maven.profile in $dir\.vscode\settings.json"
  }
  if ($t -eq 'vra') {
    Warn 'The vra archetype adds sample content (Small VM blueprint, vra8-db-mssql policies, subscription, catalog item...).'
    Warn 'Everything under src is pushed - move what you do not want out of src before the first push.'
  }
  Log "Created $dir"
}

function Cmd-SelfTest {
  Load-Env
  Log 'Self-test: scaffold, build and sign a throwaway project'
  $root = Join-Path $BtHome 'selftest'
  if (Test-Path $root) { Remove-Item $root -Recurse -Force }
  Ensure-Dir $root
  $script:Cust = 'SELF'; $script:Scope = 'buildtest'; $script:ProjectType = 'js'; $script:ProjectRoot = $root; $script:MavenProfile = 'packaging'
  Cmd-NewProject
  $dir = Join-Path $root 'buildtest'
  $log = Join-Path $BtHome 'selftest-mvn.log'
  Push-Location $dir
  try {
    Quiet { & mvn.cmd -B -e clean package '-DskipTests' *> $log }
    $rc = $LASTEXITCODE
  } finally { Pop-Location }
  $pkg = Get-ChildItem $dir -Recurse -Filter '*.package' -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'com.self.*' } | Select-Object -First 1
  if ($rc -eq 0 -and $pkg) {
    Skip "built $($pkg.Name) ($($pkg.Length) bytes)"
    Remove-Item $root -Recurse -Force
    Log 'Self-test passed - BUILD SUCCESS'
  } else {
    Select-String -Path $log -Pattern 'ERROR|npm err' | Select-Object -First 30 | ForEach-Object { Write-Host "    $($_.Line)" }
    Die "Self-test failed. Full output: $log  (project kept at $dir)"
  }
}

function Cmd-Doctor {
  Load-Env
  Check-Versions
  Log 'Files'
  foreach ($f in @($SettingsXml, $SettingsSec, (Join-Path $CertDir 'private_key.pem'), (Join-Path $CertDir 'certificate.pem'))) {
    if (Test-Path $f) { Write-Host "    ok       $f" } else { Write-Host "    MISSING  $f" -ForegroundColor Yellow }
  }
  $openssl = Find-OpenSsl
  if ($openssl -and (Test-Path (Join-Path $CertDir 'certificate.pem'))) {
    $end = Quiet { & $openssl x509 -in (Join-Path $CertDir 'certificate.pem') -noout -enddate 2>$null }
    Skip "cert expires: $($end -replace '^notAfter=', '')"
  }
  try { Log "Latest Build Tools on Maven Central: $(Resolve-BtVersion)" } catch { Log 'Latest Build Tools: unknown' }
  Log 'Profiles'
  $ps = @(Get-Profiles)
  if ($ps.Count -eq 0) { Skip 'none - run: bt-setup.ps1 add-profile' }
  foreach ($p in $ps) {
    $reach = 'fail'
    try {
      $t = New-Object Net.Sockets.TcpClient
      $iar = $t.BeginConnect($p.Host, [int]$p.Port, $null, $null)
      if ($iar.AsyncWaitHandle.WaitOne(3000) -and $t.Connected) { $reach = 'ok' }
      $t.Close()
    } catch { }
    Write-Host ('    {0,-16} {1,-6} {2,-30} updated {3}  tcp/{4} {5}' -f $p.Id, $p.Type, $p.Host, $p.Updated, $p.Port, $reach)
  }
}

function Cmd-Install {
  Ensure-Dir $ToolsDir
  Install-Git
  Install-Jdk
  Install-Node
  Install-Maven
  Set-UserEnv
  Check-Versions
  Install-VsCode
  Setup-VsCodeExt
  Setup-Cert
  Setup-MasterPassword
  Render-Settings
  if (-not $SkipProfilePrompt -and @(Get-Profiles).Count -eq 0) {
    $a = Read-Host '    Add a connection profile now? [Y/n]'
    if (-not $a -or $a -match '^[Yy]') { Cmd-AddProfile }
  }
  Log 'All set. Open a NEW terminal so JAVA_HOME / PATH apply (this window is already updated).'
}

function Usage {
  Get-Help $PSCommandPath -Detailed | Out-String | Write-Host
}

switch ($Command.ToLower()) {
  'install'       { Cmd-Install }
  'add-profile'   { Cmd-AddProfile }
  'refresh-token' { Cmd-RefreshToken }
  'new-project'   { Cmd-NewProject }
  'selftest'      { Cmd-SelfTest }
  'doctor'        { Cmd-Doctor }
  default         { Usage }
}
