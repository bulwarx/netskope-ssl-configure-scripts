#!/usr/bin/env python3
import os
import re
import subprocess
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

if status_code !=200:
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

configured_tools_file = os.path.join(os.getcwd(), 'configured_tools.sh')
with open(configured_tools_file, 'w') as f:
    pass

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
                with open(configured_tools_file, 'a') as f:
                    if is_windows:
                        f.write(f'# certifi patch for {python_exe}\n')
                        f.write(f'type "{cert_path}" >> "{certifi_bundle}"\n')
                    else:
                        f.write(f'# certifi patch for {python_exe}\n')
                        f.write(f'cat "{cert_path}" >> "{certifi_bundle}"\n')
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
        with open(configured_tools_file, 'a') as f:
            f.write(f'"{python_exe}" -m pip config set global.cert "{cert_path}"\n')
    else:
        print(f'    pip: not installed')

    # requests — informational only (REQUESTS_CA_BUNDLE env var covers it)
    r = subprocess.run([python_exe, '-c', 'import requests; print(requests.__version__)'],
                       capture_output=True, text=True)
    if r.returncode == 0:
        print(f'    requests {r.stdout.strip()}: present (covered by REQUESTS_CA_BUNDLE)')


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
                with open(configured_tools_file, 'a') as f:
                    if is_windows:
                        f.write(f'setx {env_var} "{os.path.join(cert_dir, cert_name)}"\n')
                    else:
                        f.write(f'export {env_var}="{os.path.join(cert_dir, cert_name)}"\n')
        if post_command:
            subprocess.run(post_command, shell=True)
            with open(configured_tools_file, 'a') as f:
                f.write(f'{post_command}\n')
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
    with open(configured_tools_file, 'a') as f:
        if is_windows:
            f.write(f'setx REQUESTS_CA_BUNDLE "{_cert_path}"\n')
        else:
            f.write(f'export REQUESTS_CA_BUNDLE="{_cert_path}"\n')
else:
    print('  No Python installations found')

for tool_name, env_var, check_command, post_command in tools:
    configure_tool(tool_name, env_var, check_command, post_command)

azure_storage_path = os.path.expanduser('~/Library/Application Support/StorageExplorer/certs') if not is_windows else os.path.join(os.getenv('USERPROFILE'), 'AppData', 'Roaming', 'StorageExplorer', 'certs')
if os.path.isdir(azure_storage_path):
    print('Azure Storage Explorer is installed')
    shutil.copy(os.path.join(cert_dir, cert_name), azure_storage_path)
    print('Azure Storage Explorer configured')
    with open(configured_tools_file, 'a') as f:
        f.write(f'cp "{os.path.join(cert_dir, cert_name)}" "{azure_storage_path}"\n')
else:
    print('Azure Storage Explorer is not installed')

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
