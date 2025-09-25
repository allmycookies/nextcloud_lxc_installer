# Nextcloud Installer & Manager for Proxmox LXC

This script provides a comprehensive, interactive, and robust solution for installing and managing a "Bare Metal" Nextcloud instance on a **Debian 12** or **Ubuntu 22.04** LXC container. It is specifically designed to create a flawless, warning-free setup.

## Features

This script is a "one-stop-shop" designed to make your Nextcloud setup as simple and reliable as possible. It anticipates and solves common problems automatically, giving you a production-ready instance right from the start.

  * **Guided Installation:** Interactive prompts for URL, admin user, passwords, and reverse proxy configuration.
  * **Automated Stack Setup:** Installs and configures the complete LAMP stack (Apache, MariaDB, PHP 8.2) and Redis for high-performance caching.
  * **Built-in Troubleshooting & Optimization:** Automatically fixes all common warnings from the Nextcloud "Administration Overview" panel:
      * Configures **Redis** for transactional file locking to prevent data corruption.
      * Installs and configures **Imagick** with SVG support.
      * Sets the correct **default phone region**.
      * Optimizes PHP `memory_limit` and file upload sizes.
      * Configures the cron job to use `background:cron`.
      * Solves the **"server-to-itself" loopback connection issue** common in container environments.
  * **Systemd Integration:** Creates and enables `systemd` services for automatic startup on boot.
  * **Optional SSL:** Can automatically set up a free Let's Encrypt SSL certificate if you are not using a reverse proxy.
  * **Post-Install Management:** After installation, the script becomes a powerful management tool with a menu to:
      * Check, start, stop, or restart services.
      * Reset the admin user's password.
      * Perform a clean and complete uninstallation.

## Why this script?

While other tools automate container creation, this script focuses on perfecting the Nextcloud instance *inside* the container. It was built to create a setup that passes all of Nextcloud's internal security and setup checks.

  * **Warning-Free Guarantee:** The script is designed to deliver an instance where the "Administration Overview" is green from the very first login. It saves you hours of troubleshooting.
  * **Intelligent & State-Aware:** The script detects an existing installation via a `.nextcloud_install_state` file and automatically switches from installer to **manager mode**.
  * **Reverse Proxy Aware:** It explicitly asks if you use a reverse proxy and configures Nextcloud's `trusted_proxies` and overwrite settings accordingly.
  * **Clean Bare Metal Setup:** It gives you a transparent setup without the abstraction layers of Docker, following best practices for performance and security.

## How to Use

All you need is a running Debian 12 or Ubuntu 22.04 LXC container.

Log in as the `root` user and execute the following command. The script will be downloaded and run, guiding you through the next steps.

-----

### Option 1: `curl` (Recommended)

```bash
bash <(curl -sSL https://raw.githubusercontent.com/allmycookies/nextcloud_lxc_installer/main/nc-installer.sh)
```

-----

### Option 2: `wget`

```bash
bash <(wget -qO - https://raw.githubusercontent.com/allmycookies/nextcloud_lxc_installer/main/nc-installer.sh)
```

-----

**That's it\!**

  * **On the first run**, the script will perform the interactive installation.
  * **On any subsequent run**, the script will detect your existing installation and launch the management menu.
