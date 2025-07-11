#!/bin/bash
# SPDX-License-Identifier: GPL-3.0

# For debugging purposes
# set -x

# Quick and (very) dirty script to make novideo drivers for vgpu guest
# for unraid
# Credits:midi1996
#         samicrusader#4026
#         ich777
## Check if Script is running as root

cleanup() {
    echo -ne "\r"
    if [[ "${CLEANUP_END}" == "1" ]]; then
        # Auto cleanup mode (no confirmation)
        echo " [<] Auto-cleaning up temporary files..."
        rm -rf "${DATA_TMP}" && echo " [i] Temporary build directory ${DATA_TMP} removed." \
            || { echo "  [!] Error while removing ${DATA_TMP}. Please delete it manually."; exit 1; }
        echo " [i] Cleanup complete. Exiting."
        exit 0
    fi
    # Interactive cleanup (when not in auto-clean mode)
    echo " [<] Cleaning up the mess..."
    echo "  [?] Do you want to delete the temporary folder ${DATA_TMP} and remove all build files?"
    echo "  [?] Type Y to confirm or any other key to cancel."
    read -r clsans
    if [[ "${clsans,,}" == "y" ]]; then
        echo "  [!] Removing ${DATA_TMP}..."
        rm -rf "${DATA_TMP}" && echo " [i] Cleaned up! Exiting." \
            || { echo "  [!] Error while removing ${DATA_TMP}. Bailing out."; exit 1; }
    else
        echo "  [!] Not cleaning up. Exiting now."
    fi
    exit 0
}

files_prepare() {
    echo
    # Create log file
    touch "${LOG_F}" || { echo " [!] Error creating log file ${LOG_F}."; exit 1; }
    echo " [i] Log file created: ${LOG_F}"
    echo " [>] Running preliminary checks..."
    # If NV_RUN provided, get driver version for naming
    if [[ -n "${NV_RUN}" ]]; then
        echo "  [i] Determining NVIDIA driver version from package..."
        echo "  [i] This may take a moment, please wait."
        NV_DRV_V=$(sh "${DATA_DIR}/${NV_RUN}" --version 2>/dev/null | grep -i "version" | cut -d " " -f4)
        if [[ -z "${NV_DRV_V}" ]]; then
            echo "  [!] Error: Could not retrieve NVIDIA driver version from ${NV_RUN}. Please check the package or verify it with '--version'."
            exit 1
        fi
        echo "  [✓] NVIDIA driver version: ${NV_DRV_V}"
    fi
    # Check disk space (require ~7GB free)
    FREE_STG=$(df -k --output=avail "$PWD" | tail -n1)
    if [[ "${FREE_STG}" -lt $((7*1024*1024)) ]]; then
        echo "  [!] Not enough disk space. Ensure at least 7 GB is free."
        exit 1
    else
        echo " [✓] Sufficient disk space available."
    fi
    # Check internet connectivity (needed for kernel and package downloads)
    if wget -q --spider https://kernel.org; then
        echo " [✓] Internet connection: OK"
    else
        echo " [!] Internet connection unavailable. Please check your network."
        exit 1
    fi
    echo ""
    echo " [>] Preparing folder structure..."
    if [[ -z "${SKIP_KERNEL}" && -d "${DATA_TMP}" ]]; then
        echo " [!] Found an existing temporary build directory."
        echo "  [?] Do you want to delete the old temporary folder 'tmp' and start fresh?"
        echo "  [?] Enter 1 for Yes or 2 for No."
        select ans in "Yes" "No"; do
            case $ans in
                Yes )
                    echo "  [>] Removing old temporary folder..."
                    rm -rf "${DATA_TMP}" || { echo "   [!] Error deleting old temporary folder. Please remove it manually."; exit 1; }
                    echo " [✓] Old temporary folder deleted."
                    break
                    ;;
                No )
                    echo " [!] Reusing existing 'tmp' folder. (This may cause errors if contents are stale.)"
                    break
                    ;;
            esac
        done
    fi
    mkdir -p "${DATA_TMP}" || { echo "  [!] Error creating base temp directory ${DATA_TMP}."; exit 1; }
    mkdir -p "${NV_TMP_D}/usr/lib64/xorg/modules/drivers" \
             "${NV_TMP_D}/usr/lib64/xorg/modules/extensions" \
             "${NV_TMP_D}/usr/bin" \
             "${NV_TMP_D}/etc" \
             "${NV_TMP_D}/lib/modules/${UNAME%/}/kernel/drivers/video" \
             "${NV_TMP_D}/lib/firmware" || { echo "  [!] Error creating NVIDIA package directory structure."; exit 1; }
    echo " [✓] Temporary folders created."
    echo " [✓] Preliminary setup done."
    echo
}

build_kernel() {
    echo " [>] Building the Unraid kernel..."
    echo "  [>] Downloading Linux kernel source ${LNX_FULL_VER}..."
    cd "${DATA_TMP}" || { echo "  [!] Error: Could not enter temp directory ${DATA_TMP}."; exit 1; }
    wget -q -nc -4c --show-progress --progress=bar:force:noscroll "https://mirrors.edge.kernel.org/pub/linux/kernel/v${LNX_MAJ_NUMBER}.x/linux-${LNX_FULL_VER}.tar.xz" \
        || { echo "  [!] Error downloading Linux kernel source tarball."; exit 1; }
    echo "  [>] Extracting kernel source archive..."
    tar -xf "linux-${LNX_FULL_VER}.tar.xz" || { echo "  [!] Error extracting linux-${LNX_FULL_VER}.tar.xz"; exit 1; }
    cd "linux-${LNX_FULL_VER}" || { echo "  [!] Error entering linux-${LNX_FULL_VER} source directory"; exit 1; }
    echo "   [✓] Kernel source ${LNX_FULL_VER} extracted."
    echo "  [>] Applying Unraid patches to kernel..."
    cp -r "${DATA_DIR}/${UNRAID_DIR}" "${DATA_TMP}/${UNAME%/}" || { echo "  [!] Unraid source folder not found at ${DATA_DIR}/${UNRAID_DIR}"; exit 1; }
    find "${DATA_TMP}/${UNAME%/}" -type f -name '*.patch' -exec patch -p1 -i {} \; -delete >> "${LOG_F}" 2>&1 \
        || { echo "  [!] Failed to apply Unraid kernel patches. See ${LOG_F} for details."; exit 1; }
    echo "   [✓] Unraid patches applied."
    echo "  [>] Merging Unraid configuration and files..."
    cp "${DATA_TMP}/${UNAME%/}/.config" . || { echo "  [!] .config not found in Unraid source folder. Exiting."; exit 1; }
    cp -r "${DATA_TMP}/${UNAME%/}/drivers/md"/* drivers/md/ 2>/dev/null || { echo "  [!] Unraid 'drivers/md' folder not found or empty. Exiting."; exit 1; }
    echo "   [✓] Unraid kernel config and files merged."
    echo "  [>] Compiling the kernel (this may take a while)..."
    make -j"$(nproc)" >> "${LOG_F}" 2>&1 || { echo -e "\n  [!] Kernel build failed. Check ${LOG_F} for details.\n"; exit 1; }
    make -j"$(nproc)" modules >> "${LOG_F}" 2>&1 || { echo -e "\n  [!] Kernel modules build failed. Check ${LOG_F} for details.\n"; exit 1; }
    echo " [✓] Kernel build complete."
    echo
}

link_sauce() {
    echo " [>] Linking built kernel source into /lib/modules..."
    cd "${DATA_TMP}" || { echo "  [!] Error accessing temp directory ${DATA_TMP}."; exit 1; }
    mkdir -p /lib/modules/"${UNAME%/}" || { echo "  [!] Error creating /lib/modules/${UNAME%/} directory"; exit 1; }
    ln -sf "${DATA_TMP}/linux-${LNX_FULL_VER}" /lib/modules/"${UNAME%/}"/build || { echo "  [!] Error linking /lib/modules/${UNAME%/}/build"; exit 1; }
    echo " [✓] Kernel source linked for module compilation."
    echo
}

nv_inst() {
    echo " [>] Installing NVIDIA vGPU drivers (this will take a while)..."
    cd "${DATA_DIR}" || { echo " [!] Error: Could not access directory ${DATA_DIR}."; exit 1; }
    chmod +x "${DATA_DIR}/${NV_RUN}" || { echo " [!] Error making NVIDIA installer executable."; exit 1; }
    # Remove any previous extracted installer folder
    if [ -d "$(basename "${NV_RUN}" .run)" ]; then
        echo "  [>] Removing old NVIDIA installer directory..."
        rm -rf "$(basename "${NV_RUN}" .run)" || { echo "  [!] Error removing old NVIDIA installer directory."; exit 1; }
    fi
    # Remove old installer log if exists
    if [[ -f /var/log/nvidia-installer.log ]]; then
        echo "  [>] Removing old NVIDIA installer log..."
        rm -f /var/log/nvidia-installer.log || echo "  [!] Warning: could not remove old /var/log/nvidia-installer.log (continuing)."
        cat <<WARN
  [?] If NVIDIA drivers were previously installed on this system,
  [?] running this script in a VM is strongly recommended to avoid conflicts.
  [?] The script will attempt to uninstall any existing NVIDIA driver to prevent issues.
  [?] Press Enter to continue (or Ctrl+C to abort)...
WARN
        read -r
        echo "  [>] Uninstalling any existing NVIDIA driver..."
        sh "${DATA_DIR}/${NV_RUN}" --uninstall --silent >> "${LOG_F}" 2>&1
        echo "  [i] Uninstall step complete (check ${LOG_F} for any issues)."
    fi
    cat <<INST
  [>] Launching NVIDIA driver installer...
   [i] You can monitor progress in another terminal via:
   [i]    tail -F /var/log/nvidia-installer.log
   [i] The installer log is also being recorded to ${LOG_F}.
INST
    # Run NVIDIA installer with specific options for packaging
    sh "${DATA_DIR}/${NV_RUN}" --kernel-name="${UNAME%/}" \
        --no-precompiled-interface \
        --disable-nouveau \
        --x-prefix="${NV_TMP_D}/usr" \
        --x-library-path="${NV_TMP_D}/usr/lib64" \
        --x-module-path="${NV_TMP_D}/usr/lib64/xorg/modules" \
        --opengl-prefix="${NV_TMP_D}/usr" \
        --installer-prefix="${NV_TMP_D}/usr" \
        --utility-prefix="${NV_TMP_D}/usr" \
        --documentation-prefix="${NV_TMP_D}/usr" \
        --application-profile-path="${NV_TMP_D}/usr/share/nvidia" \
        --proc-mount-point="${NV_TMP_D}/proc" \
        --kernel-install-path="${NV_TMP_D}/lib/modules/${UNAME%/}/kernel/drivers/video" \
        --compat32-prefix="${NV_TMP_D}/usr" \
        --compat32-libdir="/lib" \
        --install-compat32-libs \
        --no-x-check \
        --no-dkms \
        --no-nouveau-check \
        --skip-depmod \
        --silent \
        --no-questions \
        --ui=none \
        --accept-license \
        --j"${CPU_COUNT}" >> "${LOG_F}" 2>&1 &
    NV_PID=$!
    # Wait for installer log to appear, then tail it to log file
    local TRY_MAX=30
    local try_count=0
    while [ ! -f /var/log/nvidia-installer.log ]; do
        if [ "${try_count}" -ge "${TRY_MAX}" ]; then
            echo "   [!] NVIDIA installer log not found after ${TRY_MAX} seconds."
            exit 1
        fi
        try_count=$((try_count + 1))
        sleep 1
    done
    tail -F /var/log/nvidia-installer.log >> "${LOG_F}" &
    TAIL_PID=$!
    wait $NV_PID
    # Installer finished, kill the tail process
    kill $TAIL_PID 2>/dev/null
    echo "  [>] Verifying NVIDIA driver installation log..."
    if grep -q "installation of the NVIDIA" /var/log/nvidia-installer.log && grep -q "is now complete" /var/log/nvidia-installer.log; then
        echo "   [✓] NVIDIA driver installed into temporary directory successfully."
        echo "   [i] (See /var/log/nvidia-installer.log or ${LOG_F} for details.)"
        # Short pause to allow user to read success message
        for (( i=5; i>0; i--)); do
            echo -ne "   [i] Continuing in ${i} seconds...\r"
            sleep 1
        done
        echo
    else
        echo -e '\a'
        cat <<FAIL
  [!] NVIDIA driver installation might have failed.
  [i] Check /var/log/nvidia-installer.log for errors.
  [i] The resulting package could be incomplete or broken.
  [!] Press Ctrl+C now to abort, or press Enter to continue at your own risk.
FAIL
        read -r
    fi
}

copy_files() {
    echo " [>] Copying supplementary files..."
    if [ -d /lib/firmware/nvidia ]; then
        cp -R /lib/firmware/nvidia "${NV_TMP_D}/lib/firmware/" || echo "  [!] Warning: Failed to copy /lib/firmware/nvidia"
    fi
    if [ -f /usr/bin/nvidia-modprobe ]; then
        cp /usr/bin/nvidia-modprobe "${NV_TMP_D}/usr/bin/" || echo "  [!] Warning: Failed to copy nvidia-modprobe"
    else
        echo "  [i] Note: /usr/bin/nvidia-modprobe not found, skipping."
    fi
    if [ -d /etc/OpenCL ]; then
        cp -R /etc/OpenCL "${NV_TMP_D}/etc/" || echo "  [!] Warning: Failed to copy OpenCL configuration"
    fi
    if [ -d /etc/vulkan ]; then
        cp -R /etc/vulkan "${NV_TMP_D}/etc/" || echo "  [!] Warning: Failed to copy Vulkan configuration"
    fi
    if [ -d /etc/nvidia ]; then
        cp -R /etc/nvidia "${NV_TMP_D}/etc/" || echo "  [!] Warning: Failed to copy /etc/nvidia"
    fi
    if [ -d /usr/lib/nvidia ]; then
        cp -R /usr/lib/nvidia "${NV_TMP_D}/usr/lib/" || echo "  [!] Warning: Failed to copy /usr/lib/nvidia"
    fi
    if [ -d /usr/share/nvidia ]; then
        cp -R /usr/share/nvidia "${NV_TMP_D}/usr/share/" || echo "  [!] Warning: Failed to copy /usr/share/nvidia"
    fi
    echo " [✓] Supplementary files copied (where available)."
    echo
}

libnvidia_inst() {
    echo " [>] Adding NVIDIA container runtime files..."
    cd "${DATA_TMP}" || { echo " [!] Error entering temp directory ${DATA_TMP}."; exit 1; }
    # Download and extract libnvidia-container package if not already present
    if [ ! -f "${DATA_TMP}/libnvidia-container-v${LIBNVIDIA_CONTAINER_V}.tar.gz" ]; then
        echo "  [>] Downloading libnvidia-container v${LIBNVIDIA_CONTAINER_V}..."
        wget -q -nc --show-progress --progress=bar:force:noscroll -O "${DATA_TMP}/libnvidia-container-v${LIBNVIDIA_CONTAINER_V}.tar.gz" \
            "https://github.com/ich777/libnvidia-container/releases/download/${LIBNVIDIA_CONTAINER_V}/libnvidia-container-v${LIBNVIDIA_CONTAINER_V}.tar.gz" \
            || { echo "  [!] Error downloading libnvidia-container-v${LIBNVIDIA_CONTAINER_V}.tar.gz"; exit 1; }
    fi
    tar -C "${NV_TMP_D}/" -xf "${DATA_TMP}/libnvidia-container-v${LIBNVIDIA_CONTAINER_V}.tar.gz" \
        || { echo "  [!] Error extracting libnvidia-container package"; exit 1; }
    # Download and extract nvidia-container-toolkit package if not present
    if [ ! -f "${DATA_TMP}/nvidia-container-toolkit-v${CONTAINER_TOOLKIT_V}.tar.gz" ]; then
        echo "  [>] Downloading nvidia-container-toolkit v${CONTAINER_TOOLKIT_V}..."
        wget -q -nc --show-progress --progress=bar:force:noscroll -O "${DATA_TMP}/nvidia-container-toolkit-v${CONTAINER_TOOLKIT_V}.tar.gz" \
            "https://github.com/ich777/nvidia-container-toolkit/releases/download/${CONTAINER_TOOLKIT_V}/nvidia-container-toolkit-v${CONTAINER_TOOLKIT_V}.tar.gz" \
            || { echo "  [!] Error downloading nvidia-container-toolkit-v${CONTAINER_TOOLKIT_V}.tar.gz"; exit 1; }
    fi
    tar -C "${NV_TMP_D}/" -xf "${DATA_TMP}/nvidia-container-toolkit-v${CONTAINER_TOOLKIT_V}.tar.gz" \
        || { echo "  [!] Error extracting nvidia-container-toolkit package"; exit 1; }
    echo " [✓] NVIDIA container runtime files added."
    echo
}

package_building() {
    echo " [>] Creating Slackware package..."
    PLUGIN_NAME="nvidia-driver"
    BASE_DIR="${NV_TMP_D}"
    TMP_PKG_DIR="${DATA_TMP}/${PLUGIN_NAME}_$$"
    VERSION="$(date +'%Y.%m.%d')"
    mkdir -p "${TMP_PKG_DIR}/${VERSION}" || { echo "  [!] Error creating packaging directory."; exit 1; }
    cd "${TMP_PKG_DIR}/${VERSION}" || { echo "  [!] Error entering packaging directory."; exit 1; }
    cp -R "${BASE_DIR}/"* "${TMP_PKG_DIR}/${VERSION}/" || { echo "  [!] Error copying files into package directory."; exit 1; }
    mkdir -p install
    # Create Slackware package description
    cat > install/slack-desc <<EOF
           |-----handy-ruler------------------------------------------------------|
$PLUGIN_NAME: $PLUGIN_NAME package for Unraid
$PLUGIN_NAME:
$PLUGIN_NAME: Contains:
$PLUGIN_NAME:  - NVIDIA vGPU Driver v${NV_DRV_V}
$PLUGIN_NAME:  - libnvidia-container v${LIBNVIDIA_CONTAINER_V}
$PLUGIN_NAME:  - nvidia-container-toolkit v${CONTAINER_TOOLKIT_V}
$PLUGIN_NAME:
$PLUGIN_NAME: Custom $PLUGIN_NAME built for Unraid kernel ${UNAME%%-*} by user.
$PLUGIN_NAME:
EOF
    # Determine if makepkg is available
    MAKEPKG_CMD=""
    if command -v makepkg > /dev/null 2>&1; then
        echo " [*] 'makepkg' found, using system makepkg."
        MAKEPKG_CMD="$(command -v makepkg)"
    else
        echo "  [!] 'makepkg' not found. Installing Slackware pkgtools temporarily..."
        if ! ls "${DATA_TMP}"/pkgtools-*.txz >/dev/null 2>&1; then
            echo "    [>] Downloading Slackware pkgtools..."
            wget -q -nc --show-progress --progress=bar:force:noscroll -P "${DATA_TMP}" \
                "https://slackware.uk/slackware/slackware64-15.0/slackware64/a/pkgtools-15.0-noarch-42.txz" \
                || { echo "    [!] Error downloading pkgtools package. Please manually place pkgtools .txz in ${DATA_TMP}"; exit 1; }
        fi
        tar -C "${DATA_TMP}" -xf "${DATA_TMP}/pkgtools-"*.txz sbin/makepkg || { echo "    [!] Error extracting makepkg from pkgtools."; exit 1; }
        MAKEPKG_CMD="${DATA_TMP}/sbin/makepkg"
        if [[ ! -x "${MAKEPKG_CMD}" ]]; then
            echo "    [!] makepkg is not available even after installation. Aborting."
            exit 1
        fi
        echo "    [✓] 'makepkg' installed temporarily."
    fi
    echo "  [>] Building the package (this may take a while)..."
    "${MAKEPKG_CMD}" -l n -c n "${TMP_PKG_DIR}/${PLUGIN_NAME%%-*}-${NV_DRV_V}-${UNAME%/}-1.txz" >> "${LOG_F}" 2>&1 \
        || { echo "  [!] makepkg failed to create the package. See ${LOG_F} for details."; exit 1; }
    md5sum "${TMP_PKG_DIR}/${PLUGIN_NAME%%-*}-${NV_DRV_V}-${UNAME%/}-1.txz" | awk '{print $1}' > "${TMP_PKG_DIR}/${PLUGIN_NAME%%-*}-${NV_DRV_V}-${UNAME%/}-1.txz.md5"
    echo "  [>] Creating output directory ${DATA_DIR}/out"
    mkdir -p "${DATA_DIR}/out" && echo " [✓] Output directory ready."
    echo "  [>] Copying package and checksum to output directory..."
    cp "${TMP_PKG_DIR}/${PLUGIN_NAME%%-*}-${NV_DRV_V}-${UNAME%/}-1.txz"* "${DATA_DIR}/out/" \
        || { echo "  [!] Error copying final package to ${DATA_DIR}/out"; exit 1; }
    echo ""
    echo "   [i] Package created: ${DATA_DIR}/out/${PLUGIN_NAME%%-*}-${NV_DRV_V}-${UNAME%/}-1.txz"
    echo "   [i] MD5 checksum: $(cat "${DATA_DIR}/out/${PLUGIN_NAME%%-*}-${NV_DRV_V}-${UNAME%/}-1.txz.md5")"
    echo "   [i] Package size: $(du -h "${DATA_DIR}/out/${PLUGIN_NAME%%-*}-${NV_DRV_V}-${UNAME%/}-1.txz" | cut -f1)"
    echo ""
    echo " [✓] Package build complete."
    echo -e '\a'
}

# Helper to run commands and catch failures
run_cmd() {
    local cmd="$*"
    local line_no=$BASH_LINENO
    # Execute the command
    eval "$cmd"
    local status=$?
    if [ $status -ne 0 ]; then
        echo "[!] Command '${cmd}' failed with exit status $status at line $line_no"
        exit $status
    fi
}

######### MAIN SCRIPT ##########

# Ensure script is run as root
if [[ $(id -u) -ne 0 ]]; then
    cat <<EOF
  [!] Not running as root.
  [i] Please run this script as root (e.g., with sudo).
  [i] Exiting...
EOF
    exit 1
fi

# Initialize variables
DATA_DIR=$(pwd)
DATA_TMP="${DATA_DIR}/tmp"
NV_TMP_D="${DATA_TMP}/NVIDIA"
LOG_F="${DATA_DIR}/logfile_$(date +'%Y.%m.%d')_$RANDOM.log"
CPU_COUNT=$(nproc)
LIBNVIDIA_CONTAINER_V="1.14.3"
CONTAINER_TOOLKIT_V="1.14.3"
CLEANUP_END=0
SKIP_KERNEL=

# Parse options
while getopts 'n:u:shc' OPTION; do
    case "$OPTION" in
        n)
            NV_RUN="$OPTARG"
            echo " [i] NVIDIA driver package: ${NV_RUN}"
            ;;
        u)
            UNRAID_DIR="$OPTARG"
            echo " [i] Unraid source folder: ${UNRAID_DIR}"
            ;;
        s)
            SKIP_KERNEL=1
            echo " [i] Skipping kernel build (assuming kernel already built)."
            ;;
        h)
            cat <<EOF

 [i] Usage: sudo bash $(basename "$0") -u <Unraid_source_folder> -n <NVIDIA_driver.run> [options]

 [i] Options:
    -s    Skip kernel build step (if kernel source is already compiled)
    -c    Clean up temporary files after build (or run standalone to just clean up)
    -h    Show this help message

EOF
            exit 0
            ;;
        c)
            CLEANUP_END=1
            echo " [i] Will clean up temporary files after script completes."
            ;;
        ?)
            echo -e "\n [!] Usage: sudo bash $(basename "$0") -n <NVIDIA_driver.run> -u <Unraid_source_folder> [options]\n"
            exit 1
            ;;
    esac
done

# Ensure mandatory arguments are provided (-n and -u)
if [[ -z "${NV_RUN}" || -z "${UNRAID_DIR}" ]]; then
    if [[ "${CLEANUP_END}" == "1" && -z "${NV_RUN}" && -z "${UNRAID_DIR}" ]]; then
        # If only -c was provided (no -n or -u), perform cleanup
        cleanup
    else
        echo -e "\n [!] Error: -u and -n options are required to run the build.\n"
        echo " [i] Usage: sudo bash $(basename "$0") -u <Unraid_source_folder> -n <NVIDIA_driver.run> [options]"
        echo " [i] Try '$(basename "$0") -h' for more information."
        exit 1
    fi
fi

# Begin main execution
cat <<WEL

 [!] Welcome to the Unraid NVIDIA vGPU Driver Packager
 [!] Note: Tested with NVIDIA vGPU driver versions 525.85 and 525.105 on Unraid 6.12.x.
 [!] Starting in 3 seconds... (Press Ctrl+C to cancel)

WEL
sleep 3

# Derive kernel version details from Unraid source folder name
UNAME=$(echo "${UNRAID_DIR}" | sed 's/linux-//')
LNX_MAJ_NUMBER=$(echo "${UNAME%/}" | cut -d "." -f1)
LNX_FULL_VER=$(echo "${UNAME%/}" | cut -d "-" -f1)

# Execute the main build steps
run_cmd files_prepare
if [[ -z "${SKIP_KERNEL}" ]]; then
    run_cmd build_kernel
fi
run_cmd link_sauce
run_cmd nv_inst
# Copying supplementary files is non-critical, so we don't use run_cmd (just log warnings if any)
copy_files
run_cmd libnvidia_inst
run_cmd package_building

# If -c was specified, auto-clean the temporary files
if [[ "${CLEANUP_END}" == "1" ]]; then
    cleanup
fi

echo -e "\n [i] Script completed successfully."
exit 0
