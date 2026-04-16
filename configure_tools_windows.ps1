#Requires -Version 5.1
<#
.SYNOPSIS
    Configures the Netskope SSL certificate bundle as trusted by developer tools.
.DESCRIPTION
    Prompts for tenant details, downloads the certificate bundle, then patches every
    Python installation found (certifi + pip), sets persistent environment variables,
    and runs tool-specific config commands for Git, cURL, Node, AWS CLI, gcloud, etc.
    Optionally writes a configured_tools.ps1 replay script in the current directory.
#>

# ─── TLS bypass for initial download (cert not trusted yet) ──────────────────

if ($PSVersionTable.PSVersion.Major -lt 7) {
    # PS 5.1: allow untrusted certs via ServicePointManager callback
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $skipTls = @{}
} else {
    $skipTls = @{ SkipCertificateCheck = $true }
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

function Read-Default($prompt, $default) {
    $v = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($v)) { $default } else { $v }
}

function Test-Cmd($name) {
    $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Set-PersistentEnvVar($name, $value) {
    [Environment]::SetEnvironmentVariable($name, $value, [EnvironmentVariableTarget]::User)
    Set-Item -Path "Env:\$name" -Value $value -ErrorAction SilentlyContinue
}

$configuredToolsFile = Join-Path $PSScriptRoot 'configured_tools.ps1'

function Add-Replay($line) {
    if ($createReplay) { Add-Content -Path $configuredToolsFile -Value $line }
}

# ─── Color helpers ────────────────────────────────────────────────────────────
#   Write-Ok     green  — success / configured
#   Write-Warn   yellow — already configured / skipped
#   Write-Err    red    — error / access denied
#   Write-Header cyan   — section header (adds blank line before)
#   Write-Dim    gray   — not installed / N/A
function Write-Ok($msg)     { Write-Host $msg -ForegroundColor Green }
function Write-Warn($msg)   { Write-Host $msg -ForegroundColor Yellow }
function Write-Err($msg)    { Write-Host $msg -ForegroundColor Red }
function Write-Header($msg) { Write-Host ""; Write-Host $msg -ForegroundColor Cyan }
function Write-Dim($msg)    { Write-Host $msg -ForegroundColor DarkGray }

# ─── User inputs ──────────────────────────────────────────────────────────────

$certName   = Read-Default 'Certificate bundle name'     'netskope-cert-bundle.pem'
$certDir    = Read-Default 'Certificate bundle location' (Join-Path $env:USERPROFILE 'netskope')
$certDir    = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($certDir))
$certPath   = Join-Path $certDir $certName

$tenantName = Read-Host 'Full tenant name (e.g. mytenant.eu.goskope.com)'
$orgKey     = Read-Host 'Tenant orgkey'

# ─── Create directory ────────────────────────────────────────────────────────

if (-not (Test-Path $certDir)) {
    Write-Warn "$certDir does not exist — creating it"
    New-Item -ItemType Directory -Path $certDir -Force | Out-Null
}

# ─── Tenant reachability ──────────────────────────────────────────────────────

try {
    Invoke-WebRequest -Uri "https://$tenantName/locallogin" -UseBasicParsing @skipTls `
                      -ErrorAction Stop | Out-Null
    Write-Ok 'Tenant Reachable'
} catch {
    Write-Err "Tenant Unreachable: $_"
    exit 1
}

# ─── Cert bundle download ─────────────────────────────────────────────────────

function New-CertBundle {
    Write-Host 'Creating cert bundle...'
    $urls = @(
        "https://addon-$tenantName/config/ca/cert?orgkey=$orgKey"
        "https://addon-$tenantName/config/org/cert?orgkey=$orgKey"
        'https://curl.se/ca/cacert.pem'
    )
    if (Test-Path $certPath) {
        Remove-Item -Path $certPath -Force -ErrorAction SilentlyContinue
    }
    [IO.File]::WriteAllBytes($certPath, [byte[]]@())
    $stream = [IO.File]::Open($certPath, [IO.FileMode]::Append)
    try {
        foreach ($url in $urls) {
            $bytes = (Invoke-WebRequest -Uri $url -UseBasicParsing @skipTls).Content
            $stream.Write($bytes, 0, $bytes.Length)
        }
    } finally {
        $stream.Close()
    }
    Write-Ok "Cert bundle saved: $certPath"
}

$certWasRecreated = $false
if (Test-Path $certPath) {
    Write-Warn "$certName already exists in $certDir."
    $recreate = Read-Host 'Recreate Certificate Bundle? (y/N)'
    if ($recreate -ieq 'y') { New-CertBundle; $certWasRecreated = $true }
} else {
    New-CertBundle
    $certWasRecreated = $true
}

$createReplay = (Read-Host 'Create replay script (configured_tools.ps1)? [y/N]') -ieq 'y'
if ($createReplay) {
    Set-Content -Path $configuredToolsFile -Value '# Netskope SSL configuration - replay script'
    Write-Ok "Replay script: $configuredToolsFile"
}

# ─── Windows Certificate Store ───────────────────────────────────────────────

Write-Header "Windows Certificate Store"

$certContent = Get-Content $certPath -Raw -ErrorAction SilentlyContinue
if ($certContent -match '-----BEGIN CERTIFICATE-----\s*([\s\S]*?)\s*-----END CERTIFICATE-----') {
    $b64 = $Matches[1] -replace '\s', ''
    try {
        $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            ,[Convert]::FromBase64String($b64))
        $thumb = $x509.Thumbprint
        $inStore = @(
            Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $thumb }
        ).Count -gt 0
        if ($inStore) {
            Write-Warn "  already configured (certificate found in store)"
        } else {
            Write-Host "  importing certificate into Windows store..."
            $addMachine = certutil -addstore -f Root $certPath 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "  configured (imported into LocalMachine\Root)"
                Add-Replay "certutil -addstore -f Root `"$certPath`""
            } else {
                $addUser = certutil -addstore -f -user Root $certPath 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "  configured (imported into CurrentUser\Root)"
                    Add-Replay "certutil -addstore -f -user Root `"$certPath`""
                } else {
                    Write-Err "  access denied — rerun as Administrator to import into machine store"
                }
            }
        }
    } catch {
        Write-Err "  could not check certificate store: $_"
    }
} else {
    Write-Err "  no PEM certificate found in bundle"
}

# ─── Python: find all installations ──────────────────────────────────────────

function Get-AllPythons {
    $found = [ordered]@{}  # normcase(path) => @(path, label)

    # Python Launcher — most reliable on Windows
    if (Test-Cmd 'py') {
        py --list-paths 2>$null | ForEach-Object {
            if ($_ -match '(-V:\S+)\s+\*?\s+(.*python\.exe)') {
                $path = $Matches[2].Trim()
                if (Test-Path $path) {
                    $found[$path.ToLower()] = @($path, $Matches[1])
                }
            }
        }
    }

    # Fallback: all 'python' entries on PATH
    where.exe python 2>$null | ForEach-Object {
        $p = $_.Trim()
        if ($p -and (Test-Path $p) -and -not $found.Contains($p.ToLower())) {
            $found[$p.ToLower()] = @($p, 'python')
        }
    }

    # Bundled Pythons detected from tool output
    @(
        @{ Cmd = 'az'; Args = '--version'; Pattern = "Python location '(.+python\.exe)'"; Label = 'Azure CLI' }
    ) | ForEach-Object {
        $src = $_
        if (Test-Cmd $src.Cmd) {
            $out = & $src.Cmd $src.Args 2>$null | Out-String
            if ($out -match $src.Pattern) {
                $path = $Matches[1]
                if ((Test-Path $path) -and -not $found.Contains($path.ToLower())) {
                    $found[$path.ToLower()] = @($path, $src.Label)
                }
            }
        }
    }

    return $found.Values
}

function Configure-PythonSSL($pythonExe, $label, $certWasRecreated = $false) {
    Write-Host ""
    Write-Host "  " -NoNewline
    Write-Host "[$label]" -ForegroundColor Cyan -NoNewline
    Write-Host " $pythonExe"

    # certifi — append with a marker so re-runs are idempotent; re-patch when cert was recreated
    $certifiBundle = & $pythonExe -c 'import certifi; print(certifi.where())' 2>$null
    if ($LASTEXITCODE -eq 0 -and $certifiBundle) {
        $certifiBundle = $certifiBundle.Trim()
        $existing  = [IO.File]::ReadAllBytes($certifiBundle)
        $markerStr = "`n# Netskope SSL bundle"
        $markerBytes = [Text.Encoding]::UTF8.GetBytes($markerStr)
        # Search for marker
        $markerIdx = -1
        for ($mi = 0; $mi -le $existing.Length - $markerBytes.Length; $mi++) {
            $match = $true
            for ($mj = 0; $mj -lt $markerBytes.Length; $mj++) {
                if ($existing[$mi + $mj] -ne $markerBytes[$mj]) { $match = $false; break }
            }
            if ($match) { $markerIdx = $mi; break }
        }
        $hadMarker = $markerIdx -ge 0
        if ($hadMarker -and -not $certWasRecreated) {
            Write-Warn "    certifi: already configured ($certifiBundle)"
        } else {
            # Strip old Netskope bundle if present, then re-append fresh cert
            if ($hadMarker) { $existing = $existing[0..($markerIdx - 1)] }
            try {
                [IO.File]::WriteAllBytes($certifiBundle, $existing)
                $stream = [IO.File]::Open($certifiBundle, [IO.FileMode]::Append)
                $marker = [Text.Encoding]::UTF8.GetBytes("`n# Netskope SSL bundle`n")
                $cert   = [IO.File]::ReadAllBytes($certPath)
                $stream.Write($marker, 0, $marker.Length)
                $stream.Write($cert, 0, $cert.Length)
                $stream.Close()
                $action = if ($hadMarker) { 'updated' } else { 'configured' }
                Write-Ok "    certifi: $action ($certifiBundle)"
                Add-Replay "# certifi patch for $pythonExe"
                Add-Replay "Add-Content -Path `"$certifiBundle`" -Value (Get-Content -Path `"$certPath`" -Raw)"
            } catch [System.UnauthorizedAccessException] {
                Write-Err "    certifi: access denied — rerun as Administrator to patch $certifiBundle"
            } catch {
                Write-Err "    certifi: failed — $_"
            }
        }
    } else {
        Write-Dim "    certifi: not installed"
    }

    # pip global cert
    & $pythonExe -m pip --version *>$null
    if ($LASTEXITCODE -eq 0) {
        & $pythonExe -m pip config set global.cert $certPath *>$null
        Write-Ok "    pip: configured"
        Add-Replay "`"$pythonExe`" -m pip config set global.cert `"$certPath`""
    } else {
        Write-Dim "    pip: not installed"
    }

    # requests — informational (REQUESTS_CA_BUNDLE env var covers it)
    $reqVer = & $pythonExe -c 'import requests; print(requests.__version__)' 2>$null
    if ($LASTEXITCODE -eq 0 -and $reqVer) {
        Write-Dim "    requests $($reqVer.Trim()): present (covered by REQUESTS_CA_BUNDLE)"
    }
}

Write-Header "Python installations"
$allPythons = @(Get-AllPythons)
if ($allPythons.Count -gt 0) {
    foreach ($entry in $allPythons) {
        Configure-PythonSSL $entry[0] $entry[1] $certWasRecreated
    }
    Write-Host ""
    Set-PersistentEnvVar 'REQUESTS_CA_BUNDLE' $certPath
    Write-Ok "REQUESTS_CA_BUNDLE set globally"
    Add-Replay "[Environment]::SetEnvironmentVariable('REQUESTS_CA_BUNDLE', `"$certPath`", 'User')"
} else {
    Write-Dim "  No Python installations found"
}

# ─── Tool configuration ───────────────────────────────────────────────────────

function Configure-Tool($toolName, $envVar, $checkCmd, $postCmd = $null) {
    Write-Host ""
    if (Test-Cmd $checkCmd) {
        Write-Host "$toolName is installed"
        & $checkCmd --version
        if ($envVar) {
            $current = [Environment]::GetEnvironmentVariable($envVar, [EnvironmentVariableTarget]::User)
            if ($current -eq $certPath) {
                Write-Warn "$toolName already configured"
            } else {
                Set-PersistentEnvVar $envVar $certPath
                Write-Ok "$toolName configured"
                Add-Replay "[Environment]::SetEnvironmentVariable('$envVar', `"$certPath`", 'User')"
            }
        }
        if ($postCmd) {
            Invoke-Expression $postCmd
            Add-Replay $postCmd
        }
    } else {
        Write-Dim "$toolName is not installed"
    }
}

# Git — uses git config, not an env var, on Windows
Write-Host ""
if (Test-Cmd 'git') {
    Write-Host "Git is installed"
    git --version
    $current = git config --global http.sslCAInfo
    if ($current -eq $certPath) {
        Write-Warn "Git already configured"
    } else {
        git config --global http.sslCAInfo $certPath
        Write-Ok "Git configured"
        Add-Replay "git config --global http.sslCAInfo `"$certPath`""
    }
} else { Write-Dim "Git is not installed" }

Configure-Tool 'OpenSSL' 'SSL_CERT_FILE' 'openssl'

# cURL — write .curlrc (works for both OpenSSL and Schannel curl)
Write-Host ""
if (Test-Cmd 'curl') {
    Write-Host "cURL is installed"
    curl --version
    $curlrc = Join-Path $env:USERPROFILE '.curlrc'
    "--cacert `"$certPath`"" | Set-Content -Path $curlrc -Encoding ASCII
    Write-Ok "cURL configured ($curlrc)"
    Add-Replay "Set-Content -Path `"$curlrc`" -Value `"--cacert \`"$certPath\`"`" -Encoding ASCII"
} else { Write-Dim "cURL is not installed" }

Configure-Tool 'AWS CLI'   'AWS_CA_BUNDLE'       'aws'
Configure-Tool 'NodeJS'    'NODE_EXTRA_CA_CERTS'  'node'

# Google Cloud CLI
Write-Host ""
if (Test-Cmd 'gcloud') {
    Write-Host "Google Cloud CLI is installed"
    gcloud --version
    gcloud config set core/custom_ca_certs_file $certPath
    Write-Ok "Google Cloud CLI configured"
    Add-Replay "gcloud config set core/custom_ca_certs_file `"$certPath`""
} else { Write-Dim "Google Cloud CLI is not installed" }

# NPM
Write-Host ""
if (Test-Cmd 'npm') {
    Write-Host "NodeJS Package Manager (NPM) is installed"
    npm --version
    npm config set cafile $certPath
    Write-Ok "NodeJS Package Manager (NPM) configured"
    Add-Replay "npm config set cafile `"$certPath`""
} else { Write-Dim "NodeJS Package Manager (NPM) is not installed" }

Configure-Tool 'Ruby'    'SSL_CERT_FILE' 'ruby'

# PHP Composer
Write-Host ""
if (Test-Cmd 'composer') {
    Write-Host "PHP Composer is installed"
    composer --version
    composer config --global cafile $certPath
    Write-Ok "PHP Composer configured"
    Add-Replay "composer config --global cafile `"$certPath`""
} else { Write-Dim "PHP Composer is not installed" }

Configure-Tool 'GoLang'           'SSL_CERT_FILE'      'go'
Configure-Tool 'Azure CLI'        'REQUESTS_CA_BUNDLE'  'az'
Configure-Tool 'Oracle Cloud CLI' 'REQUESTS_CA_BUNDLE'  'oci'

# Cargo — needs two env vars
Write-Host ""
if (Test-Cmd 'cargo') {
    Write-Host "Cargo Package Manager is installed"
    cargo --version
    Set-PersistentEnvVar 'SSL_CERT_FILE'  $certPath
    Set-PersistentEnvVar 'GIT_SSL_CAPATH' $certPath
    Write-Ok "Cargo Package Manager configured"
    Add-Replay "[Environment]::SetEnvironmentVariable('SSL_CERT_FILE',  `"$certPath`", 'User')"
    Add-Replay "[Environment]::SetEnvironmentVariable('GIT_SSL_CAPATH', `"$certPath`", 'User')"
} else { Write-Dim "Cargo Package Manager is not installed" }

# Yarn
Write-Host ""
if (Test-Cmd 'yarn') {
    Write-Host "Yarn is installed"
    yarn --version
    yarn config set cafile $certPath
    Write-Ok "Yarn configured"
    Add-Replay "yarn config set cafile `"$certPath`""
} else { Write-Dim "Yarn is not installed" }

# Azure Storage Explorer
Write-Host ""
$storageExplorerCerts = Join-Path $env:APPDATA 'StorageExplorer\certs'
if (Test-Path $storageExplorerCerts) {
    Write-Host "Azure Storage Explorer is installed"
    Copy-Item -Path $certPath -Destination $storageExplorerCerts -Force
    Write-Ok "Azure Storage Explorer configured"
    Add-Replay "Copy-Item -Path `"$certPath`" -Destination `"$storageExplorerCerts`" -Force"
} else { Write-Dim "Azure Storage Explorer is not installed" }

# ─── Java JDK ────────────────────────────────────────────────────────────────

function Get-AllJDKs {
    $found = [ordered]@{}  # normcase(home) => @(home, label)

    function Add-JDK($home, $label) {
        if (-not $home -or -not (Test-Path $home -PathType Container)) { return }
        $keytool = Join-Path $home 'bin\keytool.exe'
        if ((Test-Path $keytool) -and -not $found.Contains($home.ToLower())) {
            $found[$home.ToLower()] = @($home, $label)
        }
    }

    if ($env:JAVA_HOME) { Add-JDK $env:JAVA_HOME 'JAVA_HOME' }

    $kt = Get-Command keytool -ErrorAction SilentlyContinue
    if ($kt) { Add-JDK (Split-Path (Split-Path $kt.Source)) 'PATH' }

    @(
        'HKLM:\SOFTWARE\JavaSoft\JDK',
        'HKLM:\SOFTWARE\WOW6432Node\JavaSoft\JDK'
    ) | ForEach-Object {
        if (Test-Path $_) {
            Get-ChildItem $_ -ErrorAction SilentlyContinue | ForEach-Object {
                $javaHome = (Get-ItemProperty $_.PSPath -Name JavaHome -ErrorAction SilentlyContinue).JavaHome
                if ($javaHome) { Add-JDK $javaHome "Registry ($($_.PSChildName))" }
            }
        }
    }

    $progFiles = $env:ProgramFiles
    @('Java','Eclipse Adoptium','Amazon Corretto','Zulu','Microsoft') | ForEach-Object {
        $parent = Join-Path $progFiles $_
        if (Test-Path $parent) {
            Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                Add-JDK $_.FullName "Common ($($_.Name))"
            }
        }
    }

    return $found.Values
}

function Configure-JavaSSL($jdkHome, $label, $certWasRecreated = $false) {
    Write-Host ""
    Write-Host "  " -NoNewline
    Write-Host "[$label]" -ForegroundColor Cyan -NoNewline
    Write-Host " $jdkHome"

    $cacerts = Join-Path $jdkHome 'lib\security\cacerts'
    if (-not (Test-Path $cacerts)) { $cacerts = Join-Path $jdkHome 'jre\lib\security\cacerts' }
    if (-not (Test-Path $cacerts)) { Write-Err "    cacerts: not found"; return }

    $keytool   = Join-Path $jdkHome 'bin\keytool.exe'
    $storepass = 'changeit'

    $certText  = Get-Content $certPath -Raw
    $pemBlocks = [regex]::Matches($certText, '-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----') |
                 Select-Object -First 2

    if ($pemBlocks.Count -eq 0) { Write-Err "    keytool: no PEM blocks found in bundle"; return }

    for ($i = 0; $i -lt $pemBlocks.Count; $i++) {
        $alias = "netskope-$i"
        & $keytool -list -alias $alias -keystore $cacerts -storepass $storepass *>$null
        if ($LASTEXITCODE -eq 0) {
            if (-not $certWasRecreated) {
                Write-Warn "    keytool alias ${alias}: already configured"
                continue
            }
            # cert bundle was recreated — delete stale alias to re-import fresh cert
            Write-Warn "    keytool alias ${alias}: removing stale entry to re-import"
            & $keytool -delete -alias $alias -keystore $cacerts -storepass $storepass *>$null
        }
        $tmp = [IO.Path]::GetTempFileName() + '.pem'
        try {
            [IO.File]::WriteAllText($tmp, $pemBlocks[$i].Value)
            & $keytool -import -trustcacerts -noprompt -alias $alias -file $tmp `
                       -keystore $cacerts -storepass $storepass *>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "    keytool alias ${alias}: configured"
                Add-Replay "# Java keytool import for $jdkHome alias $alias"
                Add-Replay "`"$keytool`" -import -trustcacerts -noprompt -alias $alias -file `"$certPath`" -keystore `"$cacerts`" -storepass $storepass"
            } else {
                Write-Err "    keytool alias ${alias}: failed"
            }
        } catch [System.UnauthorizedAccessException] {
            Write-Err "    keytool: access denied — rerun as Administrator to patch $cacerts"
        } catch {
            Write-Err "    keytool: error — $_"
        } finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Force }
        }
    }
}

Write-Header "Java installations"
$allJDKs = @(Get-AllJDKs)
if ($allJDKs.Count -gt 0) {
    foreach ($entry in $allJDKs) { Configure-JavaSSL $entry[0] $entry[1] $certWasRecreated }
} else {
    Write-Dim "  No Java installations found"
}

# ─── VS Code ──────────────────────────────────────────────────────────────────

Write-Header "VS Code"
@(
    @{ Dir = "$env:APPDATA\Code\User";            Edition = 'VS Code' }
    @{ Dir = "$env:APPDATA\Code - Insiders\User"; Edition = 'VS Code Insiders' }
) | ForEach-Object {
    $settingsDir  = $_.Dir
    $edition      = $_.Edition
    $settingsFile = Join-Path $settingsDir 'settings.json'
    if (-not (Test-Path $settingsDir)) { return }
    try {
        if (Test-Path $settingsFile) {
            $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
        } else {
            $settings = New-Object PSObject
        }
        if ($settings.PSObject.Properties['http.systemCertificates'] -and
            $settings.'http.systemCertificates' -eq $true) {
            Write-Warn "  ${edition}: already configured"
        } else {
            $settings | Add-Member -NotePropertyName 'http.systemCertificates' -NotePropertyValue $true -Force
            $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
            Write-Ok "  ${edition}: configured"
            Add-Replay "# VS Code: set http.systemCertificates in $settingsFile"
        }
    } catch {
        Write-Err "  ${edition}: failed — $_"
    }
}
if (-not (Test-Path "$env:APPDATA\Code\User") -and -not (Test-Path "$env:APPDATA\Code - Insiders\User")) {
    Write-Dim "  VS Code is not installed"
}

# ─── .NET / NuGet ─────────────────────────────────────────────────────────────

Write-Header ".NET / NuGet"
$dotnetFound = $false
@('dotnet','nuget') | ForEach-Object {
    if (Test-Cmd $_) {
        $ver = (& $_ --version 2>$null)
        Write-Ok "  $_ $ver — covered by Windows Certificate Store"
        Add-Replay "# ${_}: covered by Windows Certificate Store"
        $dotnetFound = $true
    }
}
if (-not $dotnetFound) { Write-Dim "  .NET / NuGet is not installed" }

# ─── Docker Desktop ───────────────────────────────────────────────────────────

Write-Header "Docker Desktop"
$dockerInstalled = (Test-Cmd 'docker') -or (Test-Path "$env:LOCALAPPDATA\Docker\Desktop")
if (-not $dockerInstalled) {
    Write-Dim "  Docker is not installed"
} else {
    $dockerDir = Join-Path $env:USERPROFILE '.docker'
    $dockerCa  = Join-Path $dockerDir 'ca.pem'
    $alreadyOk = $false
    if (Test-Path $dockerCa) {
        $alreadyOk = ((Get-FileHash $dockerCa).Hash -eq (Get-FileHash $certPath).Hash)
    }
    if ($alreadyOk) {
        Write-Warn "  already configured"
    } else {
        if (-not (Test-Path $dockerDir)) { New-Item -ItemType Directory $dockerDir -Force | Out-Null }
        try {
            Copy-Item $certPath $dockerCa -Force
            Write-Ok "  configured ($dockerCa)"
            Write-Host "  Note: restart Docker Desktop to apply changes"
            Add-Replay "Copy-Item -Path `"$certPath`" -Destination `"$dockerCa`" -Force"
        } catch [System.UnauthorizedAccessException] {
            Write-Err "  access denied — could not write to $dockerCa"
        }
    }
}

Write-Host ""
if ($createReplay) { Write-Ok "Done. Replay script: $configuredToolsFile" }
else { Write-Ok "Done." }

# ─── How to add a new tool ────────────────────────────────────────────────────
# Tool that uses an environment variable:
#   Configure-Tool 'MyTool' 'MYTOOL_CA_CERTS' 'mytool'
#
# Tool that also needs a post-config command:
#   Configure-Tool 'MyTool' $null 'mytool' "mytool config set cafile `"$certPath`""
