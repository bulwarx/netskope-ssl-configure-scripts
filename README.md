# SSL Configure Scripts

Cross-platform scripts to build a Netskope CA bundle and configure common developer tools to trust it.

This project is intended for environments with SSL inspection (MITM), where tools fail TLS validation unless a trusted corporate/root certificate is configured.

## What These Scripts Do

1. Prompt for tenant details and bundle location.
2. Download and create a certificate bundle (tenant + org certs + public CA roots).
3. Detect installed tools and apply SSL certificate configuration automatically.
4. Optionally generate a replay script with the applied configuration commands.

## Scripts Included

- `configure_tools_linux.sh`: Linux-focused shell script.
- `configure_tools_mac.sh`: macOS-focused shell script.
- `configure_tools_windows.cmd`: Windows CMD script.
- `configure_tools_windows.ps1`: Windows PowerShell script.
- `universal_configure_tools.py`: Unified Python script with broader discovery/configuration support.

## Supported Tools (Universal Script)

- Git
- OpenSSL
- cURL
- AWS CLI
- Google Cloud CLI
- NPM
- Node.js
- Ruby
- PHP Composer
- Go
- Azure CLI
- Oracle Cloud CLI
- Cargo
- Yarn
- Python environments (certifi, pip, requests env var)
- Java/JDK truststores (keytool)
- VS Code (`http.systemCertificates`)
- Docker Desktop (`~/.docker/ca.pem`)
- Windows Certificate Store (Windows only)
- .NET / NuGet status guidance (Windows only)

Note: The shell/CMD/PowerShell scripts cover overlapping subsets of these tools.

## Quick Start

Run one script for your platform:

- Linux: `./configure_tools_linux.sh`
- macOS: `./configure_tools_mac.sh`
- Windows CMD: `configure_tools_windows.cmd`
- Windows PowerShell: `./configure_tools_windows.ps1`
- Any platform (Python): `python universal_configure_tools.py`

## Credit

Original creator and upstream repository:

- https://github.com/duduke/ssl-configure-scripts

Additional contributions and improvements by the Bulwarx Ltd team to enhance tool coverage, cross-platform support, and user experience.
