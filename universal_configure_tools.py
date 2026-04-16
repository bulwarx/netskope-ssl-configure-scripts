#!/usr/bin/env python3
import json
import os
import re
import subprocess
import tempfile
import requests
import platform
import shutil
import urllib3

# Determine if the OS is Windows
is_windows = platform.system() == "Windows"

def get_shell():
    if is_windows:
        return None  # Windows CMD does not need a shell profile file
    else:
        my_shell = os.getenv('SHELL')
        print(f'Shell used is {my_shell}')
        if 'bash' in my_shell:
            return os.path.expanduser('~/.bash_profile')
        else:
            return os.path.expanduser('~/.zshenv')

shell = get_shell()

def get_input(prompt, default):
    user_input = input(f'{prompt} [{default}]: ')
    return user_input if user_input else default

cert_name = get_input('Please provide certificate bundle name', 'netskope-cert-bundle.pem')
cert_dir = get_input('Please provide certificate bundle location', '~/netskope')
cert_dir = os.path.normpath(os.path.expanduser(cert_dir))

if not os.path.isdir(cert_dir):
    print(f'{cert_dir} does not exist.')
    print(f'creating {cert_dir}')
    os.makedirs(cert_dir, exist_ok=True)

tenant_name = input('Please provide full tenant name (ex: mytenant.eu.goskope.com): ')
org_key = input('Please provide tenant orgkey: ')

status_code = requests.get(f'https://{tenant_name}/locallogin').status_code

if status_code != 200:
    print('Tenant Unreachable')
    exit(1)
else:
    print('Tenant Reachable')

def command_exists(command):
    return subprocess.call(f'command -v {command}', shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0 if not is_windows else shutil.which(command) is not None

def create_cert_bundle():
    print('Creating cert bundle')
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    urls = [
        f'https://addon-{tenant_name}/config/ca/cert?orgkey={org_key}',
        f'https://addon-{tenant_name}/config/org/cert?orgkey={org_key}',
        'https://curl.se/ca/cacert.pem'
    ]
    with open(os.path.join(cert_dir, cert_name), 'wb') as f:
        for url in urls:
            response = requests.get(url, verify=False)
            f.write(response.content)

if os.path.isfile(os.path.join(cert_dir, cert_name)):
    print(f'{cert_name} already exists in {cert_dir}.')
    recreate = input('Recreate Certificate Bundle? (y/N) ').strip().lower()
    if recreate == 'y':
        create_cert_bundle()
else:
    create_cert_bundle()

# --- Replay script ---
_replay_ext = 'bat' if is_windows else 'sh'
create_replay = input(f'Create replay script (configured_tools.{_replay_ext})? (y/N) ').strip().lower() == 'y'
configured_tools_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), f'configured_tools.{_replay_ext}')
if create_replay:
    with open(configured_tools_file, 'w') as f:
        if is_windows:
            f.write('@echo off\n')
    print(f'Replay script: {configured_tools_file}')

def replay(line):
    if create_replay:
        with open(configured_tools_file, 'a') as f:
            f.write(line + '\n')

def set_env_var(env_var, value):
    if is_windows:
        subprocess.run(f'setx {env_var} "{value}"', shell=True)
    else:
        with open(shell, 'a') as f:
            f.write(f'export {env_var}="{value}"\n')
        subprocess.run(f'source', shell=True)

def find_all_pythons():
    """Return a deduplicated list of (path, label) for every Python executable found."""
    found = {}  # normcase(path) -> (path, label)

    if is_windows:
        # Python Launcher is the most reliable source on Windows
        try:
            result = subprocess.run(['py', '--list-paths'], capture_output=True, text=True)
            if result.returncode == 0:
                for line in result.stdout.splitlines():
                    # Format: -V:3.14[-64] *   C:\...\python.exe
                    m = re.search(r'(-V:\S+)\s+\*?\s+(.*python\.exe)', line, re.IGNORECASE)
                    if m:
                        label, path = m.group(1), m.group(2).strip()
                        if os.path.isfile(path):
                            found[os.path.normcase(path)] = (path, label)
        except FileNotFoundError:
            pass
        # Fallback: whatever 'python' resolves to on PATH
        result = subprocess.run(['where', 'python'], capture_output=True, text=True)
        for line in result.stdout.splitlines():
            line = line.strip()
            if line and os.path.isfile(line):
                found.setdefault(os.path.normcase(line), (line, 'python'))

        # Discover Pythons bundled inside other tools by parsing their --version output
        bundled_sources = [
            (['az', '--version'], r"Python location '(.+python\.exe)'", 'Azure CLI'),
        ]
        for cmd, pattern, label in bundled_sources:
            try:
                r = subprocess.run(cmd, capture_output=True, text=True)
                if r.returncode == 0:
                    m = re.search(pattern, r.stdout, re.IGNORECASE)
                    if m:
                        path = m.group(1)
                        if os.path.isfile(path):
                            found.setdefault(os.path.normcase(path), (path, label))
            except FileNotFoundError:
                pass
    else:
        for cmd in ['python3', 'python']:
            result = subprocess.run(['which', '-a', cmd], capture_output=True, text=True)
            for line in result.stdout.splitlines():
                line = line.strip()
                if line and os.path.isfile(line):
                    real = os.path.realpath(line)
                    found.setdefault(os.path.normcase(real), (real, cmd))

    return list(found.values())


def configure_python_ssl(python_exe, label, cert_path):
    """Patch certifi and pip for a specific Python installation."""
    print(f'\n  [{label}] {python_exe}')

    # certifi — append Netskope bundle with a marker to detect re-runs
    r = subprocess.run([python_exe, '-c', 'import certifi; print(certifi.where())'],
                       capture_output=True, text=True)
    if r.returncode == 0:
        certifi_bundle = r.stdout.strip()
        marker = b'# Netskope SSL bundle'
        with open(certifi_bundle, 'rb') as f:
            existing = f.read()
        if marker in existing:
            print(f'    certifi: already configured ({certifi_bundle})')
        else:
            try:
                with open(cert_path, 'rb') as src, open(certifi_bundle, 'ab') as dst:
                    dst.write(b'\n' + marker + b'\n')
                    dst.write(src.read())
                print(f'    certifi: configured ({certifi_bundle})')
                replay(f'# certifi patch for {python_exe}')
                if is_windows:
                    replay(f'type "{cert_path}" >> "{certifi_bundle}"')
                else:
                    replay(f'cat "{cert_path}" >> "{certifi_bundle}"')
            except PermissionError:
                print(f'    certifi: access denied - rerun as Administrator to patch {certifi_bundle}')
    else:
        print(f'    certifi: not installed')

    # pip global cert
    r = subprocess.run([python_exe, '-m', 'pip', '--version'],
                       capture_output=True, text=True)
    if r.returncode == 0:
        subprocess.run([python_exe, '-m', 'pip', 'config', 'set', 'global.cert', cert_path],
                       capture_output=True)
        print(f'    pip: configured')
        replay(f'"{python_exe}" -m pip config set global.cert "{cert_path}"')
    else:
        print(f'    pip: not installed')

    # requests — informational only (REQUESTS_CA_BUNDLE env var covers it)
    r = subprocess.run([python_exe, '-c', 'import requests; print(requests.__version__)'],
                       capture_output=True, text=True)
    if r.returncode == 0:
        print(f'    requests {r.stdout.strip()}: present (covered by REQUESTS_CA_BUNDLE)')


def configure_windows_cert_store(cert_path):
    """Import the Netskope CA cert into the Windows certificate store."""
    print('\nWindows Certificate Store:')
    # PowerShell reads the file itself — avoids embedding PEM content in the command
    escaped = cert_path.replace("'", "''")
    check_script = (
        f"$p = '{escaped}'\n"
        "$txt = Get-Content $p -Raw -ErrorAction SilentlyContinue\n"
        "if ($txt -match '-----BEGIN CERTIFICATE-----[\\s\\S]*?-----END CERTIFICATE-----') {\n"
        "    $b64 = ($Matches[0] -replace '-----BEGIN CERTIFICATE-----','' "
                   "-replace '-----END CERTIFICATE-----','' -replace '\\s','')\n"
        "    try {\n"
        "        $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(\n"
        "            ,[Convert]::FromBase64String($b64))\n"
        "        $thumb = $x509.Thumbprint\n"
        "        $found = @(Get-ChildItem Cert:\\LocalMachine\\Root, Cert:\\CurrentUser\\Root "
                            "-ErrorAction SilentlyContinue |\n"
        "            Where-Object { $_.Thumbprint -eq $thumb }).Count -gt 0\n"
        "        if ($found) { Write-Output 'FOUND' } else { Write-Output 'NOTFOUND' }\n"
        "    } catch { Write-Output 'ERROR' }\n"
        "} else { Write-Output 'ERROR' }"
    )
    r = subprocess.run(['powershell', '-NoProfile', '-Command', check_script],
                       capture_output=True, text=True)
    result = r.stdout.strip()
    if result == 'FOUND':
        print('  already configured (certificate found in store)')
        return
    if result == 'ERROR' or not result:
        print('  could not check certificate store')
        return

    # Not found — try machine store (admin), fall back to user store
    print('  importing certificate into Windows store...')
    ret = subprocess.run(['certutil', '-addstore', '-f', 'Root', cert_path],
                         capture_output=True)
    if ret.returncode == 0:
        print('  configured (imported into LocalMachine\\Root)')
        replay(f'certutil -addstore -f Root "{cert_path}"')
    else:
        ret2 = subprocess.run(['certutil', '-addstore', '-f', '-user', 'Root', cert_path],
                              capture_output=True)
        if ret2.returncode == 0:
            print('  configured (imported into CurrentUser\\Root)')
            replay(f'certutil -addstore -f -user Root "{cert_path}"')
        else:
            print('  access denied - rerun as Administrator to import into machine store')


def find_all_jdks():
    """Return a deduplicated list of (jdk_home, label) for every JDK installation found."""
    found = {}  # normcase(home) -> (home, label)

    def add_jdk(home, label):
        if not home or not os.path.isdir(home):
            return
        keytool = os.path.join(home, 'bin', 'keytool.exe' if is_windows else 'keytool')
        if os.path.isfile(keytool):
            found.setdefault(os.path.normcase(home), (home, label))

    if is_windows:
        add_jdk(os.getenv('JAVA_HOME', ''), 'JAVA_HOME')

        keytool_path = shutil.which('keytool')
        if keytool_path:
            add_jdk(os.path.dirname(os.path.dirname(os.path.realpath(keytool_path))), 'PATH')

        try:
            import winreg
            for hive, key_path in [
                (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\JavaSoft\JDK'),
                (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\WOW6432Node\JavaSoft\JDK'),
            ]:
                try:
                    with winreg.OpenKey(hive, key_path) as key:
                        i = 0
                        while True:
                            try:
                                version = winreg.EnumKey(key, i)
                                with winreg.OpenKey(key, version) as vkey:
                                    home, _ = winreg.QueryValueEx(vkey, 'JavaHome')
                                    add_jdk(home, f'Registry ({version})')
                            except OSError:
                                break
                            i += 1
                except OSError:
                    pass
        except ImportError:
            pass

        prog_files = os.environ.get('ProgramFiles', r'C:\Program Files')
        for vendor in ['Java', 'Eclipse Adoptium', 'Amazon Corretto', 'Zulu', 'Microsoft']:
            parent = os.path.join(prog_files, vendor)
            if os.path.isdir(parent):
                for entry in os.listdir(parent):
                    add_jdk(os.path.join(parent, entry), f'Common ({entry})')
    else:
        add_jdk(os.getenv('JAVA_HOME', ''), 'JAVA_HOME')
        for cmd in ['java', 'keytool']:
            r = subprocess.run(['which', cmd], capture_output=True, text=True)
            if r.returncode == 0:
                real = os.path.realpath(r.stdout.strip())
                add_jdk(os.path.dirname(os.path.dirname(real)), 'PATH')

    return list(found.values())


def configure_java_ssl(jdk_home, label, cert_path):
    """Import Netskope certs into a JDK truststore."""
    print(f'\n  [{label}] {jdk_home}')
    cacerts = os.path.join(jdk_home, 'lib', 'security', 'cacerts')
    if not os.path.isfile(cacerts):
        cacerts = os.path.join(jdk_home, 'jre', 'lib', 'security', 'cacerts')
    if not os.path.isfile(cacerts):
        print('    cacerts: not found')
        return

    keytool = os.path.join(jdk_home, 'bin', 'keytool.exe' if is_windows else 'keytool')
    with open(cert_path, 'r', errors='ignore') as f:
        content = f.read()
    pem_blocks = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', content, re.DOTALL)[:2]
    if not pem_blocks:
        print('    keytool: no PEM blocks found in bundle')
        return

    storepass = 'changeit'
    for i, pem in enumerate(pem_blocks):
        alias = f'netskope-{i}'
        r = subprocess.run([keytool, '-list', '-alias', alias, '-keystore', cacerts,
                            '-storepass', storepass], capture_output=True, text=True)
        if r.returncode == 0:
            print(f'    keytool alias {alias}: already configured')
            continue
        tmp = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False) as t:
                t.write(pem)
                tmp = t.name
            r2 = subprocess.run([keytool, '-import', '-trustcacerts', '-noprompt',
                                  '-alias', alias, '-file', tmp,
                                  '-keystore', cacerts, '-storepass', storepass],
                                 capture_output=True, text=True)
            if r2.returncode == 0:
                print(f'    keytool alias {alias}: configured')
                replay(f'# Java keytool import for {jdk_home} alias {alias}')
                replay(f'"{keytool}" -import -trustcacerts -noprompt -alias {alias} -file "{cert_path}" -keystore "{cacerts}" -storepass {storepass}')
            else:
                print(f'    keytool alias {alias}: failed - {r2.stderr.strip()}')
        except PermissionError:
            print(f'    keytool: access denied - rerun as Administrator to patch {cacerts}')
        finally:
            if tmp and os.path.exists(tmp):
                os.unlink(tmp)


def configure_vscode(cert_path):
    """Configure VS Code to trust the system certificate store."""
    print('\nVS Code:')
    if is_windows:
        appdata = os.getenv('APPDATA', '')
        settings_dirs = [
            os.path.join(appdata, 'Code', 'User'),
            os.path.join(appdata, 'Code - Insiders', 'User'),
        ]
    else:
        home = os.path.expanduser('~')
        settings_dirs = [
            os.path.join(home, '.config', 'Code', 'User'),
            os.path.join(home, '.config', 'Code - Insiders', 'User'),
            os.path.join(home, 'Library', 'Application Support', 'Code', 'User'),
        ]

    found_any = False
    for settings_dir in settings_dirs:
        if not os.path.isdir(settings_dir):
            continue
        found_any = True
        edition = 'VS Code Insiders' if 'Insiders' in settings_dir else 'VS Code'
        settings_file = os.path.join(settings_dir, 'settings.json')
        try:
            if os.path.isfile(settings_file):
                with open(settings_file, 'r', encoding='utf-8') as f:
                    settings = json.load(f)
            else:
                settings = {}
            if settings.get('http.systemCertificates') is True:
                print(f'  {edition}: already configured')
                continue
            settings['http.systemCertificates'] = True
            with open(settings_file, 'w', encoding='utf-8') as f:
                json.dump(settings, f, indent=4)
            print(f'  {edition}: configured')
            replay(f'# VS Code: set http.systemCertificates in {settings_file}')
        except (PermissionError, json.JSONDecodeError) as e:
            print(f'  {edition}: failed - {e}')

    if not found_any:
        print('  VS Code is not installed')


def configure_dotnet():
    """.NET and NuGet are covered by the Windows Certificate Store — report only."""
    print('\n.NET / NuGet:')
    found = False
    for cmd in ['dotnet', 'nuget']:
        if command_exists(cmd):
            r = subprocess.run([cmd, '--version'], capture_output=True, text=True)
            version = r.stdout.strip() if r.returncode == 0 else 'unknown'
            print(f'  {cmd} {version} is installed - covered by Windows Certificate Store')
            replay(f'# {cmd}: covered by Windows Certificate Store')
            found = True
    if not found:
        print('  .NET / NuGet is not installed')


def configure_docker(cert_path):
    """Copy cert bundle to Docker's trusted CA location."""
    print('\nDocker Desktop:')
    docker_dir = os.path.join(os.path.expanduser('~'), '.docker')
    docker_ca = os.path.join(docker_dir, 'ca.pem')

    docker_installed = command_exists('docker')
    if is_windows and not docker_installed:
        docker_desktop_dir = os.path.join(os.getenv('LOCALAPPDATA', ''), 'Docker', 'Desktop')
        docker_installed = os.path.isdir(docker_desktop_dir)

    if not docker_installed:
        print('  Docker is not installed')
        return

    if os.path.isfile(docker_ca):
        with open(docker_ca, 'rb') as f1, open(cert_path, 'rb') as f2:
            if f1.read() == f2.read():
                print('  already configured')
                return

    os.makedirs(docker_dir, exist_ok=True)
    try:
        shutil.copy2(cert_path, docker_ca)
        print(f'  configured ({docker_ca})')
        print('  Note: restart Docker Desktop to apply changes')
        replay(f'cp "{cert_path}" "{docker_ca}"')
    except PermissionError:
        print(f'  access denied - could not write to {docker_ca}')


def configure_tool(tool_name, env_var, check_command, post_command=None):
    print()
    if command_exists(check_command):
        print(f'{tool_name} is installed')
        subprocess.run(f'{check_command} --version', shell=True)
        if env_var:
            current_env = os.getenv(env_var)
            if current_env == os.path.join(cert_dir, cert_name):
                print(f'{tool_name} already configured')
            else:
                set_env_var(env_var, os.path.join(cert_dir, cert_name))
                print(f'{tool_name} configured')
                if is_windows:
                    replay(f'setx {env_var} "{os.path.join(cert_dir, cert_name)}"')
                else:
                    replay(f'export {env_var}="{os.path.join(cert_dir, cert_name)}"')
        if post_command:
            subprocess.run(post_command, shell=True)
            replay(post_command)
    else:
        print(f'{tool_name} is not installed')

_cert_path = os.path.join(cert_dir, cert_name)
tools = [
    ("Git", "GIT_SSL_CAPATH", "git", ""),
    ("OpenSSL", "SSL_CERT_FILE", "openssl", ""),
    ("cURL", "SSL_CERT_FILE", "curl", ""),
    ("AWS CLI", "AWS_CA_BUNDLE", "aws", ""),
    ("Google Cloud CLI", None, "gcloud", f'gcloud config set core/custom_ca_certs_file {_cert_path}'),
    ("NodeJS Package Manager (NPM)", None, "npm", f'npm config set cafile {_cert_path}'),
    ("NodeJS", "NODE_EXTRA_CA_CERTS", "node", ""),
    ("Ruby", "SSL_CERT_FILE", "ruby", ""),
    ("PHP Composer", None, "composer", f'composer config --global cafile {_cert_path}'),
    ("GoLang", "SSL_CERT_FILE", "go", ""),
    ("Azure CLI", "REQUESTS_CA_BUNDLE", "az", ""),
    ("Oracle Cloud CLI", "REQUESTS_CA_BUNDLE", "oci", ""),
    ("Cargo Package Manager", "SSL_CERT_FILE", "cargo", ""),
    ("Yarn", None, "yarnpkg", f'yarnpkg config set httpsCaFilePath {_cert_path}')
]

# --- Python: find all installations and patch each one ---
print('\nPython installations:')
_all_pythons = find_all_pythons()
if _all_pythons:
    for _py_exe, _label in _all_pythons:
        configure_python_ssl(_py_exe, _label, _cert_path)
    # Set REQUESTS_CA_BUNDLE globally once (covers requests, Azure CLI, OCI, pip, etc.)
    set_env_var('REQUESTS_CA_BUNDLE', _cert_path)
    print('\nREQUESTS_CA_BUNDLE set globally')
    if is_windows:
        replay(f'setx REQUESTS_CA_BUNDLE "{_cert_path}"')
    else:
        replay(f'export REQUESTS_CA_BUNDLE="{_cert_path}"')
else:
    print('  No Python installations found')

for tool_name, env_var, check_command, post_command in tools:
    configure_tool(tool_name, env_var, check_command, post_command)

azure_storage_path = os.path.expanduser('~/Library/Application Support/StorageExplorer/certs') if not is_windows else os.path.join(os.getenv('USERPROFILE'), 'AppData', 'Roaming', 'StorageExplorer', 'certs')
if os.path.isdir(azure_storage_path):
    print('Azure Storage Explorer is installed')
    shutil.copy(os.path.join(cert_dir, cert_name), azure_storage_path)
    print('Azure Storage Explorer configured')
    replay(f'cp "{os.path.join(cert_dir, cert_name)}" "{azure_storage_path}"')
else:
    print('Azure Storage Explorer is not installed')

if is_windows:
    configure_windows_cert_store(_cert_path)

print('\nJava installations:')
_all_jdks = find_all_jdks()
if _all_jdks:
    for _jdk_home, _jdk_label in _all_jdks:
        configure_java_ssl(_jdk_home, _jdk_label, _cert_path)
else:
    print('  No Java installations found')

configure_vscode(_cert_path)

if is_windows:
    configure_dotnet()

configure_docker(_cert_path)

if create_replay:
    print(f'\nReplay script saved: {configured_tools_file}')

# Adding a new tool
# To add a new tool, use the `configure_tool` function with the appropriate parameters.
# Example:
# configure_tool("Tool Name", "ENV_VAR_NAME", "check_command", "post_command")
# - tool_name: The name of the tool (for display purposes)
# - env_var: The environment variable to set (if applicable)
# - check_command: The command to check if the tool is installed (usually the tool's executable name)
# - post_command: Any additional configuration command needed after setting the environment variable (can be empty if not needed)
#
# Example for adding a hypothetical tool "MyTool":
# configure_tool("MyTool", "MYTOOL_CA_CERTS", "mytool", f'mytool config set cafile {cert_dir}/{cert_name}')
