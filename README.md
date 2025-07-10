# Unraid Nvidia vGPU Drivers Builder

A script based on ich777's build tools for regular Nvidia drivers, enhanced for a more automated and user-friendly experience.

**⚠️ Important: Use a Clean Build Environment**
Do **not** run this script on your main desktop or on an Unraid server that already has Nvidia drivers installed. The script interacts directly with the Nvidia installer and may conflict with or damage an existing installation. Use a clean, temporary build environment such as a fresh Ubuntu 22.04 LTS virtual machine or Docker container.

---

## Requirements

### Build Environment

* Ubuntu 22.04 LTS (tested and recommended) or any modern Linux distribution
* 8 GB RAM (minimum)
* \~20 GB of fast storage (SSD or NVMe recommended)
* Multiple CPU threads for faster kernel builds

### Essential Build Tools

Install these on a fresh Ubuntu or Debian-based system:

```bash
sudo apt update
sudo apt install -y \
  git fakeroot build-essential ncurses-dev xz-utils libssl-dev \
  bc flex libelf-dev bison clang dwarves
```

### Required Files

Place these in your build workspace:

1. **Unraid Kernel Source**
   A folder named like `linux-X.XX.XX-Unraid`, extracted from the Unraid OS zip file for your version.
2. **Nvidia Driver Installer**
   The `.run` package downloaded from the [Nvidia Driver Portal](https://www.nvidia.com/Download/index.aspx).

---

## Directory Structure

```
unraid-driver-build/
├── build-nvidia-driver.sh
├── NVIDIA-Linux-x86_64-535.129.03-grid.run
└── linux-6.1.64-Unraid/
```

---

## Usage

Make the script executable:

```bash
chmod +x build-nvidia-driver.sh
```

Run the script (replace file and folder names as needed):

```bash
sudo ./build-nvidia-driver.sh -u linux-6.1.64-Unraid -n NVIDIA-Linux-x86_64-535.129.03-grid.run
```

---

## Script Options

| Flag | Argument   | Description                                          |
| ---- | ---------- | ---------------------------------------------------- |
| -n   | `[file]`   | Required. Nvidia driver `.run` file.                 |
| -u   | `[folder]` | Required. Unraid kernel source folder.               |
| -s   |            | Skip kernel build (use if kernel was already built). |
| -c   |            | Clean temporary files after successful build.        |
| -h   |            | Display help message.                                |

---

## After Build

Once complete, a new `out` folder will contain:

* The Unraid-compatible `.txz` package
* The corresponding `.md5` checksum file

---

## Notes

* You may need to install additional packages on your Unraid server (such as `elfutils`) to meet driver dependencies.
* Use `strace` to identify missing dependencies if the driver fails to load.
* Some containers (e.g., Jellyfin, HandBrake) may not work correctly on first start. Restarting them usually resolves the issue.

---

## Contribution

This script is shared as a "works on my machine" solution. Contributions to improve, expand, or fix the script are welcome.

---

## License

GPL-3.0

---
