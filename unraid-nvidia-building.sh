#!/bin/bash
# SPDX-License-Identifier: GPL-3.0

# A script to build Nvidia drivers for vGPU guests on Unraid.
# Credits: midi1996, samicrusader#4026, ich777

# For debugging purposes
# set -x

# --- Configuration Variables (easier to update) ---
# Source: https://github.com/ich777/libnvidia-container
LIBNVIDIA_CONTAINER_V="1.14.3"
# Source: https://github.com/ich777/nvidia-container-toolkit
CONTAINER_TOOLKIT_V="1.14.3"

# --- Global Variables (set later in the script) ---
DATA_DIR=$(pwd)
DATA_TMP="${DATA_DIR}/tmp"
NV_TMP_D="${DATA_TMP}/NVIDIA"
LOG_F="${DATA_DIR}/logfile_$(date +'%Y.%m.%d')_${RANDOM}.log"
CPU_COUNT=$(nproc)
SKIP_KERNEL=
CLEANUP_END=
NV_DRV_V=""
UNAME=""
LNX_MAJ_NUMBER=""
LNX_FULL_VER=""
NV_RUN=""
UNRAID_DIR=""

######## FUNCTIONS ##########

cleanup() {
	echo
	echo " [<] Cleaning up the mess..."
	echo "  [?] Do you want to remove the temporary directory '$DATA_TMP'?"
	read -p "  [?] Type 'y' to confirm or any other key to cancel: " clsans
	if [[ "${clsans,,}" == "y" ]]; then
		echo "  [!] Cleaning up..."
		rm -rf "${DATA_TMP}" && echo "  [i] Cleaned up successfully." || { echo "  [!] Error while removing '$DATA_TMP'. Please remove it manually."; exit 1; }
	else
		echo "  [i] Not cleaning up. The temporary directory is located at: $DATA_TMP"
	fi
	echo " [i] Exiting."
	exit 0
}

files_prepare() {
	echo
	touch "${LOG_F}" || { echo " [!] Error creating log file."; exit 1; }
	echo " [i] Log file created: ${LOG_F}"
	echo " [>] Running pre-flight checks..."

	# Check for Nvidia run file provided via -n flag
	if [[ ! -f "${DATA_DIR}/${NV_RUN}" ]]; then
		echo " [X] Nvidia driver installer not found at: ${DATA_DIR}/${NV_RUN}"
		exit 1
	fi
	echo "  [✓] Nvidia installer found."

	# Check for Unraid source dir provided via -u flag
	if [[ ! -d "${DATA_DIR}/${UNRAID_DIR}" ]]; then
		echo " [X] Unraid source directory not found at: ${DATA_DIR}/${UNRAID_DIR}"
		exit 1
	fi
	echo "  [✓] Unraid source directory found."

	echo "  [i] Retrieving Nvidia driver version from package..."
	echo "  [i] This may take a moment..."
	# Use a more robust way to capture version, but this is the standard for now.
	NV_DRV_V=$(sh "${DATA_DIR}/${NV_RUN}" --version | grep -i 'version' | head -n1 | awk '{print $4}')
	if [[ -z "${NV_DRV_V}" ]]; then
		echo "  [!] Error getting Nvidia driver version. Please check the installer package."
		exit 1
	fi
	echo "  [✓] Got Nvidia driver version: ${NV_DRV_V}"

	local FREE_STG
	FREE_STG=$(df -k --output=avail "$PWD" | tail -n1)
	# Check for 7GB in KB
	if [[ "${FREE_STG}" -lt $((7 * 1024 * 1024)) ]]; then
		echo "  [!] Not enough disk space. At least 7GB of free space is required in the current directory."
		exit 1
	fi
	echo "  [✓] Enough free space on disk."

	if wget -q --spider https://kernel.org; then
		echo "  [✓] Internet connection is available."
	else
		echo "  [!] Internet connection is unavailable. Cannot download kernel source."
		exit 1
	fi
	echo ""

	echo " [>] Preparing folder structure..."
	if [[ -z "${SKIP_KERNEL}" ]] && [[ -d "${DATA_TMP}" ]]; then
		echo " [!] An old temporary folder was found: '${DATA_TMP}'"
		read -p "  [?] Do you want to delete it and start fresh? (y/n): " ans
		if [[ "${ans,,}" == "y" ]]; then
			echo "  [>] Deleting old temporary folder..."
			rm -rf "${DATA_TMP}" || { echo "   [!] Error deleting the folder. Please remove it manually."; exit 1; }
			echo "  [✓] Old folder deleted."
		else
			echo " [!] Using the old temporary folder. This may cause unexpected issues."
		fi
	fi

	mkdir -p "${DATA_TMP}" \
		"${NV_TMP_D}/usr/lib64/xorg/modules/"{drivers,extensions} \
		"${NV_TMP_D}/usr/bin" \
		"${NV_TMP_D}/etc" \
		"${NV_TMP_D}/lib/modules/${UNAME}/kernel/drivers/video" \
		"${NV_TMP_D}/lib/firmware" || { echo "  [!] Error creating destination directories."; exit 1; }

	echo " [✓] Folder structure created."
	echo " [✓] Preparation complete."
	echo
}

build_kernel() {
	echo " [>] Building kernel source for '${LNX_FULL_VER}'..."
	echo "  [>] Downloading Linux ${LNX_FULL_VER} source..."
	cd "${DATA_TMP}" || exit 1
	wget -q -nc -4c --show-progress --progress=bar:force:noscroll https://mirrors.edge.kernel.org/pub/linux/kernel/v"${LNX_MAJ_NUMBER}".x/linux-"${LNX_FULL_VER}".tar.xz || { echo "  [!] Error downloading the kernel source."; exit 1; }

	echo "  [>] Extracting the kernel source..."
	tar xf "./linux-${LNX_FULL_VER}.tar.xz" || { echo "  [!] Error extracting the kernel source."; exit 1; }
	cd "./linux-${LNX_FULL_VER}" || { echo "  [!] Error changing to the kernel source directory."; exit 1; }
	echo "   [✓] Extracted kernel source ${LNX_FULL_VER}."

	echo "  [>] Applying Unraid patches..."
	# Copy Unraid source to a temporary location to avoid modifying original
	local TEMP_UNRAID_SRC="${DATA_TMP}/unraid_src_temp"
	cp -r "${DATA_DIR}/${UNRAID_DIR}" "${TEMP_UNRAID_SRC}"
	find "${TEMP_UNRAID_SRC}" -type f -name '*.patch' -exec patch -p1 -i {} \; -delete >>"${LOG_F}" 2>&1 || { echo "  [!] Failed to apply Unraid patches. Check log for details."; exit 1; }
	echo "   [✓] Applied Unraid patches to the kernel source."
	rm -rf "${TEMP_UNRAID_SRC}"

	echo "  [>] Merging Unraid config and files..."
	cp "${DATA_DIR}/${UNRAID_DIR}/.config" . || { echo "  [!] Couldn't find .config file in your Unraid source folder."; exit 1; }
	cp -r "${DATA_DIR}/${UNRAID_DIR}/drivers/md/." "drivers/md/" || { echo "  [!] Couldn't find drivers/md folder in your Unraid source folder."; exit 1; }
	echo "   [✓] Merged Unraid config and files."

	echo "  [>] Building the kernel (this will take a long time)..."
	echo "   [i] Output is being logged to: ${LOG_F}"
	make -j"${CPU_COUNT}" olddefconfig >>"${LOG_F}" 2>&1
	make -j"${CPU_COUNT}" >>"${LOG_F}" 2>&1 || { echo -e "\n  [!] Error building the kernel.\n  [!] Please check ${LOG_F} for details.\n"; exit 1; }
	make -j"${CPU_COUNT}" modules >>"${LOG_F}" 2>&1 || { echo -e "\n  [!] Error building the kernel modules.\n  [!] Please check ${LOG_F} for details.\n"; exit 1; }
	echo " [✓] Kernel build complete."
	echo
}

link_kernel_source() {
	echo " [>] Linking compiled kernel source to /lib/modules for the Nvidia installer..."
	mkdir -p "/lib/modules/${UNAME}"
	# The nvidia installer looks for this symlink to find kernel headers
	ln -sf "${DATA_TMP}/linux-${LNX_FULL_VER}" "/lib/modules/${UNAME}/build" || { echo "  [!] Error creating symlink in /lib/modules/${UNAME}."; exit 1; }
	echo " [✓] Kernel source linked."
	echo
}

install_nvidia_driver() {
	echo " [>] Building Nvidia drivers into staging directory: ${NV_TMP_D}"
	cd "${DATA_DIR}" || exit 1
	chmod +x "${DATA_DIR}/${NV_RUN}" || { echo " [!] Error setting execute permission on the installer."; exit 1; }

	if [[ -f /var/log/nvidia-installer.log ]]; then
		cat <<Q
  [!] An existing Nvidia installation log was found on this system.
  [i] This script will attempt to run the uninstaller first to ensure a clean state.
  [i] This is generally safe inside a temporary VM or container.
  [?] Press Enter to continue, or Ctrl+C to stop.
Q
		read -r
		echo "  [>] Running Nvidia uninstaller for cleanup..."
		sh "${DATA_DIR}/${NV_RUN}" --uninstall --silent >>"${LOG_F}" 2>&1
		echo "  [i] Uninstallation command finished."
	fi

	cat <<NI
  [i] Starting the Nvidia driver build...
  [i] You can monitor the detailed progress by running this in another terminal:
  [i]   tail -f /var/log/nvidia-installer.log
  [i] The full log will also be saved to: ${LOG_F}
NI

	sh "${DATA_DIR}/${NV_RUN}" \
		--kernel-name="${UNAME}" \
		--no-precompiled-interface \
		--disable-nouveau \
		--no-x-check \
		--no-dkms \
		--no-nouveau-check \
		--skip-depmod \
		--silent \
		--j"${CPU_COUNT}" \
		--x-prefix="${NV_TMP_D}/usr" \
		--x-library-path="${NV_TMP_D}/usr/lib64" \
		--x-module-path="${NV_TMP_D}/usr/lib64/xorg/modules" \
		--opengl-prefix="${NV_TMP_D}/usr" \
		--installer-prefix="${NV_TMP_D}/usr" \
		--utility-prefix="${NV_TMP_D}/usr" \
		--documentation-prefix="${NV_TMP_D}/usr" \
		--application-profile-path="${NV_TMP_D}/usr/share/nvidia" \
		--proc-mount-point="${NV_TMP_D}/proc" \
		--kernel-install-path="${NV_TMP_D}/lib/modules/${UNAME}/kernel/drivers/video" \
		--compat32-prefix="${NV_TMP_D}/usr" \
		--compat32-libdir=lib \
		--install-compat32-libs >>"${LOG_F}" 2>&1 &
	local NV_PID=$!

	# Wait for installer log to be created, then tail it
	for ((i = 0; i < 30; i++)); do
		[[ -f /var/log/nvidia-installer.log ]] && break
		sleep 1
	done
	if [[ ! -f /var/log/nvidia-installer.log ]]; then
		echo "   [!] Nvidia installer log was not created after 30 seconds. Something is wrong."
		kill "$NV_PID" 2>/dev/null
		exit 1
	fi
	tail -F /var/log/nvidia-installer.log >>"${LOG_F}" &
	local TAIL_PID=$!

	wait "$NV_PID"
	local NV_STATUS=$?
	# Give tail a moment to catch up before killing it
	sleep 1
	kill "$TAIL_PID" 2>/dev/null

	echo "  [>] Verifying Nvidia driver installation..."
	if [[ $NV_STATUS -eq 0 ]] && grep -q "Installation of the NVIDIA Accelerated Graphics Driver for Linux-x86_64 is now complete." /var/log/nvidia-installer.log; then
		echo "   [✓] Nvidia driver build appears to be successful."
	else
		echo -e '\a' # Beep
		cat <<NQ
  [!] The Nvidia driver build may have FAILED.
  [!] Please check the logs carefully:
  [!]   - /var/log/nvidia-installer.log
  [!]   - ${LOG_F}
NQ
		read -p "   [?] Do you want to continue and attempt to package the (possibly broken) build? (y/n): " confirm
		if [[ "${confirm,,}" != "y" ]]; then
			echo "   [i] Aborting as requested."
			exit 1
		fi
	fi
	echo
}

copy_extra_files() {
	echo " [>] Copying extra driver files (OpenCL, Vulkan, firmware)..."
	# Copy files that the installer places on the host system into our staging directory
	copy_if_exists() {
		if [[ -e "$1" ]]; then
			cp -R "$1" "$2" || echo "  [!] Warning: Failed to copy '$1'."
		fi
	}

	copy_if_exists /lib/firmware/nvidia "${NV_TMP_D}/lib/firmware/"
	copy_if_exists /usr/bin/nvidia-modprobe "${NV_TMP_D}/usr/bin/"
	copy_if_exists /etc/OpenCL "${NV_TMP_D}/etc/"
	copy_if_exists /etc/vulkan "${NV_TMP_D}/etc/"
	copy_if_exists /etc/nvidia "${NV_TMP_D}/etc/"
	copy_if_exists /usr/lib/nvidia "${NV_TMP_D}/usr/lib/"
	copy_if_exists /usr/share/nvidia "${NV_TMP_D}/usr/share/"
	
	echo " [✓] Extra file copy is done. Please check for any warnings above."
	echo
}


install_container_toolkit() {
	echo " [>] Downloading and adding Docker container support files..."
	cd "${DATA_TMP}" || exit 1

	local LIBNVIDIA_URL="https://github.com/ich777/libnvidia-container/releases/download/${LIBNVIDIA_CONTAINER_V}/libnvidia-container-v${LIBNVIDIA_CONTAINER_V}.tar.gz"
	local TOOLKIT_URL="https://github.com/ich777/nvidia-container-toolkit/releases/download/${CONTAINER_TOOLKIT_V}/nvidia-container-toolkit-v${CONTAINER_TOOLKIT_V}.tar.gz"

	echo "  [>] Getting libnvidia-container..."
	wget -q -nc --show-progress --progress=bar:force:noscroll "$LIBNVIDIA_URL" || { echo "   [!] Error downloading libnvidia-container."; exit 1; }
	tar -C "${NV_TMP_D}/" -xf "libnvidia-container-v${LIBNVIDIA_CONTAINER_V}.tar.gz" || { echo "   [!] Error extracting libnvidia-container."; exit 1; }

	echo "  [>] Getting nvidia-container-toolkit..."
	wget -q -nc --show-progress --progress=bar:force:noscroll "$TOOLKIT_URL" || { echo "   [!] Error downloading nvidia-container-toolkit."; exit 1; }
	tar -C "${NV_TMP_D}/" -xf "nvidia-container-toolkit-v${CONTAINER_TOOLKIT_V}.tar.gz" || { echo "   [!] Error extracting nvidia-container-toolkit."; exit 1; }

	echo " [✓] Docker container support files added."
	echo
}

build_package() {
	echo " [>] Creating the final Slackware (.txz) package..."

	local PLUGIN_NAME="nvidia-driver"
	local PKG_TMP_DIR="${DATA_TMP}/${PLUGIN_NAME}_pkg_$(echo $RANDOM)"
	local VERSION
	VERSION=$(date +'%Y.%m.%d')
	
	mkdir -p "${PKG_TMP_DIR}/${VERSION}/install"
	cp -R "${NV_TMP_D}/"* "${PKG_TMP_DIR}/${VERSION}/"

	# Create the slack-desc file required for Slackware packages
	cat > "${PKG_TMP_DIR}/${VERSION}/install/slack-desc" <<EOF
|-----handy-ruler------------------------------------------------------|
$PLUGIN_NAME: Nvidia custom driver package for Unraid
$PLUGIN_NAME:
$PLUGIN_NAME: This package contains the proprietary Nvidia drivers, compiled
$PLUGIN_NAME: specifically for Unraid kernel ${UNAME}.
$PLUGIN_NAME:
$PLUGIN_NAME: Nvidia Driver Version: ${NV_DRV_V}
$PLUGIN_NAME: libnvidia-container: v${LIBNVIDIA_CONTAINER_V}
$PLUGIN_NAME: nvidia-container-toolkit: v${CONTAINER_TOOLKIT_V}
$PLUGIN_NAME:
$PLUGIN_NAME: Built by the Unraid Nvidia Driver Tool on $(date)
$PLUGIN_NAME:
EOF

	local MAKEPKG_CMD
	if command -v makepkg &>/dev/null; then
		echo "  [i] 'makepkg' is already installed."
		MAKEPKG_CMD="makepkg"
	else
		cat <<Q
  [!] 'makepkg' command not found.
  [i] It is required to create the .txz package.
  [i] The script will now attempt to download and use it temporarily.
Q
		echo "  [>] Downloading Slackware pkgtools..."
		wget -q -nc --show-progress --progress=bar:force:noscroll \
			https://slackware.uk/slackware/slackware64-15.0/slackware64/a/pkgtools-15.0-noarch-42.txz \
			-P "${DATA_TMP}" || { echo "   [!] Failed to download pkgtools."; exit 1; }
		
		tar -C "${DATA_TMP}" -xf "${DATA_TMP}/pkgtools"*.txz sbin/makepkg
		MAKEPKG_CMD="${DATA_TMP}/sbin/makepkg"
		chmod +x "$MAKEPKG_CMD"
		if [[ ! -x "$MAKEPKG_CMD" ]]; then
			echo "   [!] Failed to set up temporary 'makepkg'. Aborting."
			exit 1
		fi
		echo "   [✓] 'makepkg' is ready for temporary use."
	fi

	echo "  [>] Building package (this may take a moment)..."
	local PKG_FILENAME="${PLUGIN_NAME}-${NV_DRV_V}-${UNAME}-1.txz"
	cd "${PKG_TMP_DIR}/${VERSION}" || exit 1
	"${MAKEPKG_CMD}" -l n -c n "${DATA_DIR}/${PKG_FILENAME}" >>"${LOG_F}" 2>&1

	# Verify package was created and move to 'out' directory
	if [[ -f "${DATA_DIR}/${PKG_FILENAME}" ]]; then
		mkdir -p "${DATA_DIR}/out"
		mv "${DATA_DIR}/${PKG_FILENAME}" "${DATA_DIR}/out/"
		md5sum "${DATA_DIR}/out/${PKG_FILENAME}" | awk '{print $1}' > "${DATA_DIR}/out/${PKG_FILENAME}.md5"
		
		echo ""
		echo " [✓] SUCCESS! Your custom driver package is ready."
		echo "   ----------------------------------------------------------------"
		echo "   File:     out/${PKG_FILENAME}"
		echo "   Size:     $(du -sh "${DATA_DIR}/out/${PKG_FILENAME}" | awk '{print $1}')"
		echo "   MD5:      $(cat "${DATA_DIR}/out/${PKG_FILENAME}.md5")"
		echo "   ----------------------------------------------------------------"
		echo
		echo -e '\a' # Beep
	else
		echo " [X] FAILED to create the package. Check the log file: ${LOG_F}"
		exit 1
	fi
}

# --- Main Execution ---
main() {
	trap 'echo -e "\n[!] Script interrupted by user."; cleanup' INT

	if [[ -z "${NV_RUN}" ]] || [[ -z "${UNRAID_DIR}" ]]; then
		if [[ "${CLEANUP_END}" -eq 1 ]]; then
			cleanup
		else
			usage
			exit 1
		fi
	fi
	
	UNAME=$(basename "${UNRAID_DIR}" | sed 's/linux-//')
	LNX_FULL_VER=$(echo "${UNAME}" | cut -d- -f1)
	LNX_MAJ_NUMBER=$(echo "${LNX_FULL_VER}" | cut -d. -f1)

	cat <<WEL

 [!] Welcome to the Nvidia driver packager for Unraid
 [!] This script will download, compile, and package software.
 [i] Unraid Kernel Target: ${UNAME}
 [i] Nvidia Driver Source: ${NV_RUN}
 [i] The process will start in 5 seconds...
WEL
	sleep 5

	files_prepare

	if [[ -z "${SKIP_KERNEL}" ]]; then
		build_kernel
	else
		echo " [i] Skipping kernel build as requested."
	fi

	link_kernel_source
	install_nvidia_driver
	copy_extra_files
	install_container_toolkit
	build_package

	if [[ "${CLEANUP_END}" -eq 1 ]]; then
		cleanup
	else
		cat <<END
	
	[✓] Script finished successfully.
	[i] The temporary build directory has been left for inspection at:
	[i]   ${DATA_TMP}
	[i] You can run the script with the '-c' flag to clean it up automatically.

END
	fi
	exit 0
}

usage() {
	cat <<USAGE

Usage: sudo bash $(basename "$0") -n <NVIDIA.run> -u <UNRAID_SRC_DIR> [options]

Required:
  -n NVIDIA_INSTALLER.run   Path to the Nvidia .run installer file.
  -u UNRAID_SOURCE_DIR      Path to the Unraid kernel source directory (e.g., 'linux-6.1.64-Unraid').

Options:
  -s                        Skip the kernel build step. Use only if the kernel has already
                            been successfully built in the 'tmp' directory from a previous run.
  -c                        Cleanup the 'tmp' directory after the script finishes (or if run alone).
  -h                        Display this help message.

Example:
  sudo bash $(basename "$0") -n NVIDIA-Linux-x86_64-535.129.03-grid.run -u linux-6.1.64-Unraid

USAGE
}

# --- Script Entry Point ---
if [ "$(id -u)" -ne 0 ]; then
	cat <<R

  [!] This script must be run as root.
  [i] Please use: sudo bash $(basename "$0") [flags]
  [i] Exiting...

R
	exit 1
fi

while getopts 'n:u:sch' OPTION; do
	case "$OPTION" in
		n) NV_RUN="$OPTARG" ;;
		u) UNRAID_DIR="$OPTARG" ;;
		s) SKIP_KERNEL=1 ;;
		c) CLEANUP_END=1 ;;
		h) usage; exit 0 ;;
		?) usage; exit 1 ;;
	esac
done

# Run the main logic
main
