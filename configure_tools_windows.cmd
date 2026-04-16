@echo off
:: This tool will try to detect common cli tools and will configure the Netskope SSL certificate bundle.

:: Set Certificate bundle name and location
set /p certName="Please provide certificate bundle name [netskope-cert-bundle.pem]:"
if "%certName%"=="" set certName=netskope-cert-bundle.pem

set /p certDir="Please provide certificate bundle location [C:\netskope]:"
if "%certDir%"=="" set certDir=C:\netskope

if not exist "%certDir%" (
    echo %certDir% does not exist.
    echo Creating %certDir%
    mkdir "%certDir%"
)

:: Get tenant information to create certificate bundle
set /p tenantName="Please provide full tenant name (ex: mytenant.eu.goskope.com):"
set /p orgKey="Please provide tenant orgkey:"

:: Check tenant reachability
curl -k --write-out "%%{http_code}" --silent --output NUL https://%tenantName%/locallogin > temp.txt
set /p status_code=<temp.txt
del temp.txt

if "%status_code%" NEQ "307" (
    echo Tenant Unreachable
    exit /b 1
) else (
    echo Tenant Reachable
)

:: Create or update certificate bundle
set certBundleExists=0
if exist "%certDir%\%certName%" (
    echo %certName% already exists in %certDir%.
    set /p recreate="Recreate Certificate Bundle? (y/n): "
    if /i "%recreate%"=="y" set certBundleExists=1
) else (
    set certBundleExists=1
)

if %certBundleExists%==1 (
    echo Creating cert bundle
    curl -k "https://addon-%tenantName%/config/ca/cert?orgkey=%orgKey%" > "%certDir%\%certName%"
    curl -k "https://addon-%tenantName%/config/org/cert?orgkey=%orgKey%" >> "%certDir%\%certName%"
    curl -k -L "https://ccadb.my.salesforce-sites.com/mozilla/IncludedRootsPEMTxt?TrustBitsInclude=Websites" >> "%certDir%\%certName%"
)

:: Ask whether to create a replay script
set createReplay=n
set /p createReplay="Create replay script (configured_tools.bat)? [y/N]: "
if /i "%createReplay%"=="y" (
    echo @echo off > "%~dp0configured_tools.bat"
    echo Replay script: %~dp0configured_tools.bat
)

:: Tools configuration (add more tools here as needed)

:: Windows Certificate Store
echo.
echo Windows Certificate Store:
powershell -NoProfile -Command "$cr='%createReplay%'; $certContent = Get-Content '%certDir%\%certName%' -Raw; if ($certContent -match '-----BEGIN CERTIFICATE-----\s*([\s\S]*?)\s*-----END CERTIFICATE-----') { $b64 = $Matches[1] -replace '\s',''; try { $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,[Convert]::FromBase64String($b64)); $thumb = $x509.Thumbprint; $inStore = @(Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumb }).Count -gt 0; if ($inStore) { Write-Host '  already configured (certificate found in store)' } else { Write-Host '  importing certificate...'; $r = certutil -addstore -f Root '%certDir%\%certName%' 2>&1; if ($LASTEXITCODE -eq 0) { Write-Host '  configured (imported into LocalMachine\Root)'; if ($cr -ieq 'y') { Add-Content -Path configured_tools.bat -Value 'certutil -addstore -f Root \"%certDir%\%certName%\"' } } else { $r2 = certutil -addstore -f -user Root '%certDir%\%certName%' 2>&1; if ($LASTEXITCODE -eq 0) { Write-Host '  configured (imported into CurrentUser\Root)'; if ($cr -ieq 'y') { Add-Content -Path configured_tools.bat -Value 'certutil -addstore -f -user Root \"%certDir%\%certName%\"' } } else { Write-Host '  access denied - rerun as Administrator to import into machine store' } } } } catch { Write-Host ('  could not check certificate store: ' + $_) } } else { Write-Host '  no PEM certificate found in bundle' }"

echo.
call :command_exists git
if %ERRORLEVEL% EQU 0 call :configure_tool git "git config --global http.sslCAInfo" "git config --global http.sslCAInfo" "git config --global http.sslCAInfo %certDir%\%certName%"

echo.
call :command_exists openssl
if %ERRORLEVEL% EQU 0 call :configure_tool openssl "openssl version -a" "setx SSL_CERT_FILE" "setx SSL_CERT_FILE %certDir%\%certName%"

echo.
call :command_exists curl
if %ERRORLEVEL% EQU 0 (
    echo cURL is installed
    curl --version
    echo --ca-native > %HOMEPATH%\.curlrc
	echo --ssl-revoke-best-effort >> %HOMEPATH%\.curlrc
    echo cURL
    if /i "%createReplay%"=="y" echo echo --ca-native ^> %%HOMEPATH%%\.curlrc >> configured_tools.bat
	if /i "%createReplay%"=="y" echo echo --ssl-revoke-best-effort ^>^> %%HOMEPATH%%\.curlrc >> configured_tools.bat
) else (
    echo cURL is not installed
)

echo.
set REQUESTS_CA_BUNDLE=
for /f "tokens=*" %%P in ('python -m requests') do (
    if "%%P"=="built on:" set REQUESTS_CA_BUNDLE=%%P
)
if "%REQUESTS_CA_BUNDLE%"=="%certDir%\%certName%" (
    echo Python Requests Already configured
) else (
    setx REQUESTS_CA_BUNDLE "%certDir%\%certName%"
    echo Python Requests Library Configured
    if /i "%createReplay%"=="y" echo setx REQUESTS_CA_BUNDLE "%certDir%\%certName%" >> configured_tools.bat
)

echo.
call :command_exists aws
if %ERRORLEVEL% EQU 0 call :configure_tool aws "aws --version" "setx AWS_CA_BUNDLE" "setx AWS_CA_BUNDLE %certDir%\%certName%"

echo.
call :command_exists gcloud
if %ERRORLEVEL% EQU 0 (
    echo Google Cloud CLI is installed
    gcloud --version
    gcloud config set core/custom_ca_certs_file %certDir%\%certName%
    echo Google Cloud CLI Configured
    if /i "%createReplay%"=="y" echo gcloud config set core/custom_ca_certs_file %certDir%\%certName% >> configured_tools.bat
) else (
    echo Google Cloud CLI is not installed
)

echo.
call :command_exists npm
if %ERRORLEVEL% EQU 0 (
    echo "NodeJS Package Manager (NPM) is installed"
    npm --version
    npm config set cafile %certDir%\%certName%
    echo "NodeJS Package Manager (NPM) Configured"
    if /i "%createReplay%"=="y" echo npm config set cafile %certDir%\%certName% >> configured_tools.bat
) else (
    echo "NodeJS Package Manager (NPM) is not installed"
)

echo.
call :command_exists node
if %ERRORLEVEL% EQU 0 call :configure_tool node "node --version" "setx NODE_EXTRA_CA_CERTS" "setx NODE_EXTRA_CA_CERTS %certDir%\%certName%"

echo.
call :command_exists ruby
if %ERRORLEVEL% EQU 0 call :configure_tool ruby "ruby --version" "setx SSL_CERT_FILE" "setx SSL_CERT_FILE %certDir%\%certName%"

echo.
call :command_exists composer
if %ERRORLEVEL% EQU 0 (
    echo PHP Composer is installed
    composer --version
    composer config --global cafile %certDir%\%certName%
    echo PHP Composer Configured
    if /i "%createReplay%"=="y" echo composer config --global cafile %certDir%\%certName% >> configured_tools.bat
) else (
    echo PHP Composer is not installed
)

echo.
call :command_exists go
if %ERRORLEVEL% EQU 0 call :configure_tool go "go --version" "setx SSL_CERT_FILE" "setx SSL_CERT_FILE %certDir%\%certName%"

echo.
call :command_exists az
if %ERRORLEVEL% EQU 0 call :configure_tool az "az --version" "setx REQUESTS_CA_BUNDLE" "setx REQUESTS_CA_BUNDLE %certDir%\%certName%"

echo.
call :command_exists pip
if %ERRORLEVEL% EQU 0 call :configure_tool pip "pip --version" "setx REQUESTS_CA_BUNDLE" "setx REQUESTS_CA_BUNDLE %certDir%\%certName%"

echo.
call :command_exists oci
if %ERRORLEVEL% EQU 0 call :configure_tool oci "oci --version" "setx REQUESTS_CA_BUNDLE" "setx REQUESTS_CA_BUNDLE %certDir%\%certName%"

echo.
call :command_exists cargo
if %ERRORLEVEL% EQU 0 (
    echo Cargo Package Manager is installed
    cargo --version
    set SSL_CERT_FILE=
    for /f "tokens=*" %%P in ('cargo --version') do (
        if "%%P"=="built on:" set SSL_CERT_FILE=%%P
    )
    if "%SSL_CERT_FILE%"=="%certDir%\%certName%" (
        echo Cargo Package Manager Already configured 1/2
    ) else (
        setx SSL_CERT_FILE "%certDir%\%certName%"
        if /i "%createReplay%"=="y" echo setx SSL_CERT_FILE "%certDir%\%certName%" >> configured_tools.bat
    )
    set GIT_SSL_CAPATH=
    for /f "tokens=*" %%P in ('cargo --version') do (
        if "%%P"=="built on:" set GIT_SSL_CAPATH=%%P
    )
    if "%GIT_SSL_CAPATH%"=="%certDir%\%certName%" (
        echo Cargo Package Manager Already configured 2/2
    ) else (
        setx GIT_SSL_CAPATH "%certDir%\%certName%"
        if /i "%createReplay%"=="y" echo setx GIT_SSL_CAPATH "%certDir%\%certName%" >> configured_tools.bat
    )
    echo Cargo Package Manager configured
) else (
    echo Cargo Package Manager is not installed
)

echo.
call :command_exists yarn
if %ERRORLEVEL% EQU 0 (
    echo Yarn is installed
    yarn --version
    yarn config set cafile %certDir%\%certName%
    echo Yarn Configured
    if /i "%createReplay%"=="y" echo yarn config set cafile %certDir%\%certName% >> configured_tools.bat
) else (
    echo Yarn is not installed
)

:: Java JDK
echo.
echo Java installations:
powershell -NoProfile -Command "$storepass='changeit'; $certPath='%certDir%\%certName%'; $certText=Get-Content $certPath -Raw; $pemBlocks=[regex]::Matches($certText,'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----') | Select-Object -First 2; function Get-AllJDKs { $found=@{}; function Add-JDK($home,$label){ if(-not $home -or -not (Test-Path $home)){return}; $kt=Join-Path $home 'bin\keytool.exe'; if((Test-Path $kt)-and-not $found.Contains($home.ToLower())){ $found[$home.ToLower()]=@($home,$label) } }; if($env:JAVA_HOME){Add-JDK $env:JAVA_HOME 'JAVA_HOME'}; $ktCmd=Get-Command keytool -ErrorAction SilentlyContinue; if($ktCmd){Add-JDK (Split-Path (Split-Path $ktCmd.Source)) 'PATH'}; @('HKLM:\SOFTWARE\JavaSoft\JDK','HKLM:\SOFTWARE\WOW6432Node\JavaSoft\JDK')|ForEach-Object{ if(Test-Path $_){ Get-ChildItem $_ -ErrorAction SilentlyContinue|ForEach-Object{ $jh=(Get-ItemProperty $_.PSPath -Name JavaHome -ErrorAction SilentlyContinue).JavaHome; if($jh){Add-JDK $jh ('Registry ('+$_.PSChildName+')')} } } }; @('Java','Eclipse Adoptium','Amazon Corretto','Zulu','Microsoft')|ForEach-Object{ $p=Join-Path $env:ProgramFiles $_; if(Test-Path $p){ Get-ChildItem $p -Directory -ErrorAction SilentlyContinue|ForEach-Object{ Add-JDK $_.FullName ('Common ('+$_.Name+')') } } }; return $found.Values }; $allJDKs=@(Get-AllJDKs); if($allJDKs.Count -eq 0){ Write-Host '  No Java installations found' } else { foreach($entry in $allJDKs){ $home=$entry[0]; $label=$entry[1]; Write-Host ('  ['+$label+'] '+$home); $cacerts=Join-Path $home 'lib\security\cacerts'; if(-not(Test-Path $cacerts)){ $cacerts=Join-Path $home 'jre\lib\security\cacerts' }; if(-not(Test-Path $cacerts)){ Write-Host '    cacerts: not found'; continue }; $keytool=Join-Path $home 'bin\keytool.exe'; for($i=0;$i -lt $pemBlocks.Count;$i++){ $alias='netskope-'+$i; & $keytool -list -alias $alias -keystore $cacerts -storepass $storepass *>$null; if($LASTEXITCODE -eq 0){ Write-Host ('    keytool alias '+$alias+': already configured') } else { $tmp=[IO.Path]::GetTempFileName()+'.pem'; try { [IO.File]::WriteAllText($tmp,$pemBlocks[$i].Value); & $keytool -import -trustcacerts -noprompt -alias $alias -file $tmp -keystore $cacerts -storepass $storepass *>$null; if($LASTEXITCODE -eq 0){ Write-Host ('    keytool alias '+$alias+': configured') } else { Write-Host ('    keytool alias '+$alias+': failed') } } catch [System.UnauthorizedAccessException]{ Write-Host '    keytool: access denied - rerun as Administrator' } finally { if(Test-Path $tmp){ Remove-Item $tmp -Force } } } } } }"

:: VS Code
echo.
echo VS Code:
powershell -NoProfile -Command "@(@{Dir=($env:APPDATA+'\Code\User');Edition='VS Code'},@{Dir=($env:APPDATA+'\Code - Insiders\User');Edition='VS Code Insiders'})|ForEach-Object{ $dir=$_.Dir; $edition=$_.Edition; $sf=Join-Path $dir 'settings.json'; if(-not(Test-Path $dir)){return}; try{ if(Test-Path $sf){ $s=Get-Content $sf -Raw|ConvertFrom-Json } else { $s=New-Object PSObject }; if($s.PSObject.Properties['http.systemCertificates'] -and $s.'http.systemCertificates' -eq $true){ Write-Host ('  '+$edition+': already configured') } else { $s|Add-Member -NotePropertyName 'http.systemCertificates' -NotePropertyValue $true -Force; $s|ConvertTo-Json -Depth 10|Set-Content $sf -Encoding UTF8; Write-Host ('  '+$edition+': configured') } } catch { Write-Host ('  '+$edition+': failed - '+$_) } }; if(-not(Test-Path ($env:APPDATA+'\Code\User'))-and-not(Test-Path ($env:APPDATA+'\Code - Insiders\User'))){ Write-Host '  VS Code is not installed' }"

:: .NET / NuGet
echo.
echo .NET / NuGet:
set dotnetFound=0
where dotnet >NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   dotnet is installed - covered by Windows Certificate Store
    if /i "%createReplay%"=="y" echo # dotnet: covered by Windows Certificate Store >> configured_tools.bat
    set dotnetFound=1
)
where nuget >NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   nuget is installed - covered by Windows Certificate Store
    if /i "%createReplay%"=="y" echo # nuget: covered by Windows Certificate Store >> configured_tools.bat
    set dotnetFound=1
)
if "%dotnetFound%"=="0" echo   .NET / NuGet is not installed

:: Docker Desktop
echo.
echo Docker Desktop:
set dockerInstalled=0
where docker >NUL 2>&1
if %ERRORLEVEL% EQU 0 set dockerInstalled=1
if "%dockerInstalled%"=="0" if exist "%LOCALAPPDATA%\Docker\Desktop" set dockerInstalled=1
if "%dockerInstalled%"=="0" (
    echo   Docker is not installed
    goto :after_docker
)
fc /b "%USERPROFILE%\.docker\ca.pem" "%certDir%\%certName%" >NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   already configured
    goto :after_docker
)
if not exist "%USERPROFILE%\.docker" mkdir "%USERPROFILE%\.docker"
copy /y "%certDir%\%certName%" "%USERPROFILE%\.docker\ca.pem" >NUL
echo   configured (%USERPROFILE%\.docker\ca.pem)
echo   Note: restart Docker Desktop to apply changes
if /i "%createReplay%"=="y" echo copy /y "%certDir%\%certName%" "%USERPROFILE%\.docker\ca.pem" >> configured_tools.bat
:after_docker

:: Function to check if a command exists
:command_exists
where %1 > NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    exit /b 0
) else (
    exit /b 1
)

:: Function to configure tools
:configure_tool
:: %1 - Tool name
:: %2 - Command to retrieve the current configuration
:: %3 - Command to set the new configuration
:: %4 - Command to log configuration
echo %~1 is installed
%~1 --version
set toolConfigured=0
for /f "tokens=*" %%P in ('%~2') do set toolConfigured=%%P
if "%toolConfigured%"=="%certDir%\%certName%" (
    echo %~1 Already configured
) else (
    %~3 "%certDir%\%certName%"
    echo %~1 Configured
    echo %~1 Configured
    if /i "%createReplay%"=="y" echo %~4 >> configured_tools.bat
)
exit /b 0
:: How to add a new tool:
:: 1. Add a call to :command_exists followed by the tool name (e.g., "call :command_exists mytool").
:: 2. If the tool is found (ERRORLEVEL is 0), call :configure_tool with the following parameters:
::    - Tool name (e.g., "mytool")
::    - Command to retrieve the current configuration (e.g., "mytool config --global cafile")
::    - Command to set the new configuration (e.g., "mytool config --global cafile")
::    - Command to log configuration (e.g., "mytool config --global cafile %certDir%\%certName%" >> configured_tools.bat)
:: Example:
:: echo.
:: call :command_exists mytool
:: if %ERRORLEVEL% EQU 0 call :configure_tool mytool "mytool config --global cafile" "mytool config --global cafile" "mytool config --global cafile %certDir%\%certName%" >> configured_tools.bat
