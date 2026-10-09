# Redmine Installer for AlmaLinux

A Bash-based installer for deploying Redmine on **AlmaLinux 9 or later**, using a native installation without Docker.

## Features

- ✅ Supports AlmaLinux 9+
- ✅ Native installation — no Docker required
- ✅ IP-based web access
- ✅ Automated installation using Bash
- ✅ Installs the components required to run Redmine

## Requirements

- AlmaLinux 9 or later
- Root access or a user with `sudo` privileges
- Internet connectivity
- A server with sufficient disk space, RAM, and CPU resources
- An available server IP address

## Installation

### 1. Update the system

```bash
sudo dnf update -y
sudo dnf install -y curl wget git
```

### 2. Download the installer

```bash
wget -O install-redmine.sh https://raw.githubusercontent.com/redhatmurali/Redmine-installer/main/install-redmine%20%281%29.sh
```

### 3. Review the script

```bash
less install-redmine.sh
```

### 4. Run the installer

```bash
chmod +x install-redmine.sh
sudo bash install-redmine.sh
```

Follow any prompts displayed by the installer.

## Access Redmine

After installation, open a browser and navigate to the server IP address using the port and protocol configured by the installer.

Example:

```text
http://YOUR_SERVER_IP/
```

The exact URL depends on the web server configuration.

## Deployment Details

| Item | Configuration |
|---|---|
| Operating system | AlmaLinux 9+ |
| Installation method | Native installation |
| Container runtime | Not required |
| Access method | Server IP address |
| Installation script | `install-redmine.sh` |

## Security Recommendations

- Change all default credentials immediately.
- Configure the firewall to allow only required ports.
- Use HTTPS before exposing Redmine to the public Internet.
- Back up the Redmine database, uploaded files, and configuration.
- Review the installer before running it with root privileges.

## Repository

[View Redmine-installer on GitHub](https://github.com/redhatmurali/Redmine-installer)

## License

Add a `LICENSE` file if you intend to distribute this project for reuse.
