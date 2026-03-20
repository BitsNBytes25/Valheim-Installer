# Valheim Installer

Valheim-Installer is a tool to automate the installation and management of Valheim dedicated servers on Linux systems. 
It supports both automated installation via [Warlock](https://github.com/BitsNBytes25/Warlock) and manual installation for advanced users.

## Features

- Automated setup of Valheim dedicated server
- Firewall configuration
- SteamCMD integration
- Supports both interactive and non-interactive environments

## Recommended Installation (with Warlock)

The easiest and most reliable way to install Valheim-Installer is using [Warlock](https://github.com/BitsNBytes25/Warlock):

Refer to the [Warlock documentation](https://github.com/BitsNBytes25/Warlock) for more details.

## Manual Installation

Manual installation is supported for advanced users or custom setups.

```bash
sudo su - -c "bash <(wget -qO- https://raw.githubusercontent.com/BitsNBytes25/Valheim-Installer/dist/installer.sh)" root
```

## Project Structure

- `src/` – Source code and scripts for development
- `dist/` – Production-ready files for installation
- `scriptlets/` – Modular scripts for various tasks (firewall, Steam, etc.)
- `media/` – Images and media assets
- `scripts/` – Configuration files

## Requirements

- Linux (tested on Ubuntu, Debian)
- Python 3 (for some scriptlets)

## License

See [LICENSE.md](LICENSE.md) for license information.

## Support

For issues or feature requests, please open an issue on the [GitHub repository](https://github.com/BitsNBytes25/Valheim-Installer).

## Links

* Based on [Warlock-Template](https://github.com/BitsNBytes25/Warlock-Game-Template)
* Uses [Warlock Game Manager](https://github.com/BitsNBytes25/Warlock-Manager)
