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

if [ "$(id -u)" != 0 ]; then
	cat <<R

  [!] Not running as root.
  [i] Please run the script again as root.
  [i] Run: 
  [i] sudo bash $(basename $0) [flags]
  [i] Exiting...

R
	exit 1
fi

######## FUNCTIONS ##########

cleanup () {
	echo -ne "\r"
	echo " [<] Cleaning up the mess..."
	echo "  [?] Do you want to cleanup $DATA_TMP and remove it?"
	echo "  [?] Type Y to confirm or any key to cancel."
	read clsans
	if [[ "${clsans,,}" == "y" ]]; then
		echo "  [!] Cleaning up..."
		rm -rf "${DATA_TMP}" && echo " [i] Cleaned up! Exiting." || { echo "  [!] Error while removing $DATA_TMP. Bailing out."; exit 1; }
	else
		echo "  [!] Not cleaning up. Exiting now."
	fi
	exit 1
}

files_prepare () {
	echo
	touch "${LOG_F}" || { echo " [!] Error creating log file."; exit 1; }
	echo " [i] Log file created: ${LOG_F}"
	echo " [>] Running some tests..."
	# [ ! -d "${DATA_DIR}"/${UNAME} ] && echo " [X] Unraid source folder does not exist." && exit 1 || echo " [*] Unraid Source folder found."
	# NVIDIA_FILE=${DATA_DIR}/NVIDIA-Linux-x86_64-${NV_DRV_V}-grid.run
	# [ ! -e "${NVIDIA_FILE}" ] && echo " [X] Nvidia vGPU GRID Guest drivers not found." && exit 1 || echo " [*] Nvidia Drivers found."
	if [[ -n "${NV_RUN}" ]]; then
		echo "  [i] Retrieving Nvidia drivers version from package..."
		echo "  [i] It might take a while... Please wait."
 	 	NV_DRV_V=$(sh "${DATA_DIR}"/"${NV_RUN}" --version | grep -i version | cut -d " " -f4)
 		if [[ -z "${NV_DRV_V}" ]]; then
  		echo "  [!] Error while getting Nvidia drivers version, please check package or with '--version' flag."
  		exit 1
  	fi
  	echo "  [✓] Got Nvidia driver version: ${NV_DRV_V} "
	fi
	FREE_STG=$(df -k --output=avail "$PWD" | tail -n1)
	[ "${FREE_STG}" -lt $((7*1024*1024)) ] && echo "  [!] Not enough disk space. Make sure that you have 7GB free." && exit 1 || echo " [✓] Enough free space on disk."
	if wget -q --spider https://kernel.org
	then
		echo " [✓] Internet Available."
	else
		echo " [!] Internet Unvailable."
		exit 1
	fi
	echo ""
	echo " [>] Preparing folder structure..."
	if [[ -z "${SKIP_KERNEL}" ]] && [[ -d "${DATA_TMP}" ]]; then
		echo " [!] Old tmp folder found."
		echo "  [?] Do you want to delete the old temporiry file 'tmp'?"
		echo "  [?] Press 1 for yes or 2 for no"
		select ans in "Yes" "No"; do
			case $ans in
				Yes )
					echo "  [>] Proceeding with the deletion..."
					rm -rf "${DATA_TMP}" || { echo "   [!] Error while deleting the old temporaryf folder. Please delete it manually."; exit 1; }
					echo " [✓] Old output deleted."
					break
					;;
				No ) 
					echo " [!] Using old tmp folder! Errors may occure."
					break
			 		;;
			esac
		done
	fi
	mkdir -p "${DATA_TMP}" 
	mkdir -p "${NV_TMP_D}"/usr/lib64/xorg/modules/{drivers,extensions} \
			"${NV_TMP_D}"/usr/bin \
			"${NV_TMP_D}"/etc \
			"${NV_TMP_D}"/lib/modules/"${UNAME%/}"/kernel/drivers/video \
			"${NV_TMP_D}"/lib/firmware || { echo "  [!] Error making destination folder"; exit 1; }
	echo " [✓] Folders created."
	echo " [✓] Done preparing."
	echo
}

build_kernel () {
	echo " [>] Building kernel sauce..."
	echo "  [>] Downloading Linux ${LNX_FULL_VER} Sauce..."
	cd "${DATA_TMP}"
	wget -q -nc -4c --show-progress --progress=bar:force:noscroll https://mirrors.edge.kernel.org/pub/linux/kernel/v"${LNX_MAJ_NUMBER}".x/linux-"${LNX_FULL_VER}".tar.xz || { echo "  [!] Error downloading the kernel source."; exit 1; }
	echo "  [>] Extracting the kernel sauce..." 
	tar xf ./linux-"${LNX_FULL_VER}".tar.xz || { echo "  [!] Error while extracting the linux source"; exit 1; }
	cd ./linux-"${LNX_FULL_VER}" || { echo "  [!] Error while changing to the linux source folder"; exit 1; }
	echo "   [✓] Extracted kernel sauce ${LNX_FULL_VER}."
	echo "  [>] Applying Unraid patches..."
	cp -r "${DATA_DIR}"/"${UNRAID_DIR}" "${DATA_TMP}"/"${UNAME%/}"
	find "${DATA_TMP}"/"${UNAME%/}"/ -type f -name '*.patch' -exec patch -p1 -i {} \; -delete >>"${LOG_F}" 2>&1 || { echo "  [!] Couldn't Patch the source, exiting..."; exit 1; }
	echo "   [✓] Applied Unraid patches to the kernel sauce."
	echo "  [>] Merging Unraid config and files..."
	cp "${DATA_TMP}"/"${UNAME%/}"/.config . || { echo "  [!] Couldn't find .config file in your Unraid folder, exiting..."; exit 1; }
	cp -r "${DATA_TMP}"/"${UNAME%/}"/drivers/md/* drivers/md/ || { echo "  [!] Couldn't find drivers/md folder in your Unraid folder, exiting..."; exit 1; }
	echo "   [✓] Merged Unraid config and files..."
	echo "  [>] Building the kernel..." 
	make -j$(nproc) >>"${LOG_F}" 2>&1 || { echo -e "\n  [!] Error Building the kernel.\n  [!] Please check ${LOG_F} .\n"; exit 1; }
	make -j$(nproc) modules >>"${LOG_F}" 2>&1 || { echo -e "\n  [!] Error Building the kernel modules.\n  [!] Please check ${LOG_F} .\n"; exit 1; }
	echo " [✓] Done cooking the sauce."
	echo
}

link_sauce () {
	# Prepare kernel source build directory
	echo " [>] Linking source dir to host /lib/modules "
	cd "${DATA_TMP}"
	mkdir -p /lib/modules/"${UNAME%/}" || { echo "  [!] Error making /lib/modules/${UNAME%/} folder"; exit 1; }
	ln -sf "${DATA_TMP}"/linux-"${LNX_FULL_VER}" /lib/modules/"${UNAME%/}"/build || { echo "  [!] Error linking /lib/modules/""${UNAME%/}"" folder"; exit 1; } 
	echo " [✓] Linked."
	echo
}

nv_inst () {
	echo " [>] Installing Nvidia drivers to ${NV_TMP_D}"
	cd "${DATA_DIR}"
	chmod +x "${DATA_DIR}/${NV_RUN}" || { echo " [!] Error setting chmod to the Installer. Exiting."; exit 1; }
	
	if [ -d "$(basename "${NV_RUN}")" ]; then
		echo "  [>] Removing old Nvidia Installer folder"
		rm -rf "$(basename "${NV_RUN}")" || { echo "  [!] Error while removing old Nvidia Installer folder"; exit 1; }
	fi
	
	if [[ -f /var/log/nvidia-installer.log ]]; then
		echo "  [>] Removing old Nvidia Installer logs..."
		rm -f /var/log/nvidia-installer.log || echo "  [!] Error while removing old Nvidia Installer logs. Continuing..."
		cat <<Q
  [?] On host systems with Nvidia drivers are already installed
  [?] driver conflicts and system breaks can happen.
  [?] Make sure you're running this IN A VM!
  [?] This script will attempt uninstalling Nvidia drivers
  [?] before proceeding to clean up the system.
  [?] Press Enter to continue, or Ctrl+C to stop the script!
Q
		read -p ""
		echo "  [>] Uninstalling Nvidia drivers..."
		sh "${DATA_DIR}/${NV_RUN}" --uninstall --silent >>"${LOG_F}" 2>&1
		cat <<UF
  [?] Uninstall is complete. Reguardless of the success,
  [?] it's only for cleanup.
  [i] Proceeding...
UF
	fi
	
	cat <<NI
  [>] Installing Nvidia drivers to ${NV_TMP_D}
   [i] You might want to check the progress by running:
   [i] tail -F /var/log/nvidia-installer.log 
   [i] The output of the log will be in ${LOG_F} too.
NI
	
	sh "${DATA_DIR}/${NV_RUN}" --kernel-name="${UNAME%/}" \
	  --no-precompiled-interface \
	  --disable-nouveau \
	  --x-prefix="${NV_TMP_D}"/usr \
	  --x-library-path="${NV_TMP_D}"/usr/lib64 \
	  --x-module-path="${NV_TMP_D}"/usr/lib64/xorg/modules \
	  --opengl-prefix="${NV_TMP_D}"/usr \
	  --installer-prefix="${NV_TMP_D}"/usr \
	  --utility-prefix="${NV_TMP_D}"/usr \
	  --documentation-prefix="${NV_TMP_D}"/usr \
	  --application-profile-path="${NV_TMP_D}"/usr/share/nvidia \
	  --proc-mount-point="${NV_TMP_D}"/proc \
	  --kernel-install-path="${NV_TMP_D}"/lib/modules/"${UNAME%/}"/kernel/drivers/video \
	  --compat32-prefix="${NV_TMP_D}"/usr \
	  --compat32-libdir=/lib \
	  --install-compat32-libs \
	  --no-x-check \
	  --no-dkms \
	  --no-nouveau-check \
	  --skip-depmod \
	  --j"${CPU_COUNT}" \
	  --silent >>"${LOG_F}" 2>&1 &
	
	NV_PID=$!
	
	tee -a "${LOG_F}" >/dev/null <<LOG

[>>] tail -F /var/log/nvidia-installer.log

LOG
	
	# wait for Installer log to show up and copy it to local log file
	RET=30
	RET_C=0
	
	while [ ! -f /var/log/nvidia-installer.log ]
	do
		if [ "$RET_C" -ge "$RET" ]; then
			echo "   [!] Error while getting Nvidia Installer logs after $RET retries."
			exit 1
		fi
		RET_C=$((RET_C+1))
		sleep 1
	done
	
	tail -F /var/log/nvidia-installer.log >> "${LOG_F}" &
	TAIL_PID=$!
	
	wait $NV_PID
	kill $TAIL_PID
	
	echo "  [>] Checking Nvidia driver install logs for success..."
	if grep -q "now complete" /var/log/nvidia-installer.log >>"${LOG_F}" 2>&1
	then
		echo "   [✓] Nvidia Driver seem to be installed properly."
		echo "   [i] You might want to check /var/log/nvidia-installer.log"
		for (( i=30; i>0; i-- )); do
			echo -ne "   [i] Resuming the script in $i seconds. Press any key to resume immeditely.\r"
				if IFS= read -sr -N 1 -t 1 key
				then
					break
				fi
			done
	else
		echo -e '\a'
		cat <<NQ
  [!] Nvidia Driver DOES NOT seem to be installed properly.
  [i] You might want to check /var/log/nvidia-installer.log
  [i] Press Ctrl + C to Stop the script immeditely.
  [i] Sleeping for 30 seconds before resuming.
NQ
		sleep 30
		for (( i=30; i>0; i-- )); do
			echo -ne "   [i] Resuming the script in $i seconds. Press any key to resume immeditely.\r"
				if IFS= read -sr -N 1 -t 1 key
				then
					break
				fi
			done
			read -p "   [!] Are you sure you want to continue? $(echo $'\nThe resulting package may be broken!\n Press Enter to confirm.')" -n 1 -r
	fi
	echo 
	
	# Copy files for OpenCL and Vulkan over to temporary installation directory
	echo " [>] Copying extra files..."
	copy_files () {
	if [ -d /lib/firmware/nvidia ]; then
	  cp -R /lib/firmware/nvidia "${NV_TMP_D}"/lib/firmware/
	fi
	cp /usr/bin/nvidia-modprobe "${NV_TMP_D}"/usr/bin/
	cp -R /etc/OpenCL "${NV_TMP_D}"/etc/
	cp -R /etc/vulkan "${NV_TMP_D}"/etc/
	
	# Copy gridd related files
	cp -R /etc/nvidia "${NV_TMP_D}"/etc/
	cp -R /usr/lib/nvidia "${NV_TMP_D}"/usr/lib/
	cp -R /usr/share/nvidia "${NV_TMP_D}"/usr/share/
	}
	copy_files >>"${LOG_F}" 2>&1 || { echo " [!] Error while copying some files."; for (( i=60; i>0; i-- )); do echo "  [i] Resuming the script in $i seconds. Press any key to resume immeditely."; if IFS= read -sr -N 1 -t 1 key; then break; fi; done; }
	echo " [✓] File copy is done. Please check for any errors."
	echo
}

libnvidia_inst () {
	# Download libnvidia-container, nvidia-container-runtime & container-toolkit and extract it to temporary installation directory
	# Source libnvidia-container: https://github.com/ich777/libnvidia-container
	# Source nvidia-container-runtime: https://github.com/ich777/nvidia-container-runtime
	# Source nvidia-container-toolkit: https://github.com/ich777/nvidia-container-toolkit
	echo " [>] Copying Docker-related files..."

	cd "${DATA_TMP}"
	if [ ! -f "${DATA_TMP}"/libnvidia-container-v"${LIBNVIDIA_CONTAINER_V}".tar.gz ]; then
	  wget -q -nc --show-progress --progress=bar:force:noscroll -O "${DATA_TMP}"/libnvidia-container-v"${LIBNVIDIA_CONTAINER_V}".tar.gz "https://github.com/ich777/libnvidia-container/releases/download/${LIBNVIDIA_CONTAINER_V}/libnvidia-container-v${LIBNVIDIA_CONTAINER_V}.tar.gz" || { echo "Error downloading libnvidia-container-v${LIBNVIDIA_CONTAINER_V}.tar.gz"; exit 1; }
	fi
	tar -C "${NV_TMP_D}"/ -xf "${DATA_TMP}"/libnvidia-container-v"${LIBNVIDIA_CONTAINER_V}".tar.gz || { echo "Error while extracting libnvidia-container package"; exit 1; }

	cd "${DATA_TMP}"
	if [ ! -f "${DATA_TMP}"/nvidia-container-toolkit-v"${CONTAINER_TOOLKIT_V}".tar.gz ]; then
	  wget -q -nc --show-progress --progress=bar:force:noscroll -O "${DATA_TMP}"/nvidia-container-toolkit-v"${CONTAINER_TOOLKIT_V}".tar.gz "https://github.com/ich777/nvidia-container-toolkit/releases/download/${CONTAINER_TOOLKIT_V}/nvidia-container-toolkit-v${CONTAINER_TOOLKIT_V}.tar.gz" || { echo "Error downloading nvidia-container-toolkit-v${CONTAINER_TOOLKIT_V}.tar.gz"; exit 1; }
	fi
	tar -C "${NV_TMP_D}"/ -xf "${DATA_TMP}"/nvidia-container-toolkit-v"${CONTAINER_TOOLKIT_V}".tar.gz || { echo "Error while extracting nvidia-container-toolkit package"; exit 1; }

	echo " [✓] Docker-related files copied."
	echo ""
}

package_building () {
	# Create Slackware package
	echo " [>] Making Slackware Package..."

	PLUGIN_NAME="nvidia-driver"
	BASE_DIR="${NV_TMP_D}/"
	TMP_DIR="${DATA_TMP}/${PLUGIN_NAME}_$(echo $RANDOM)"
	# TMP_DIR="/tmp/${PLUGIN_NAME}_$(echo $RANDOM)"
	VERSION="$(date +'%Y.%m.%d')"

	mkdir -p "$TMP_DIR"/"$VERSION"
	cd "$TMP_DIR"/"$VERSION"
	cp -R "$BASE_DIR"/* "$TMP_DIR"/"$VERSION"/
	mkdir "$TMP_DIR"/"$VERSION"/install
	tee -a "$TMP_DIR"/"$VERSION"/install/slack-desc >/dev/null <<EOF
	   |-----handy-ruler------------------------------------------------------|
$PLUGIN_NAME: $PLUGIN_NAME Package contents:
$PLUGIN_NAME:
$PLUGIN_NAME: Nvidia-Driver v${NV_DRV_V}
$PLUGIN_NAME: libnvidia-container v${LIBNVIDIA_CONTAINER_V}
$PLUGIN_NAME: nvidia-container-toolkit v${CONTAINER_TOOLKIT_V}
$PLUGIN_NAME:
$PLUGIN_NAME:
$PLUGIN_NAME: Custom $PLUGIN_NAME for Unraid Kernel v${UNAME%%-*} by you
$PLUGIN_NAME:
EOF

	MAKEPKG=
	if command -v makepkg
	then
			echo " [*] makepkg is installed... Proceeding."
			MAKEPKG=$(which makepkg)
	else
		cat <<Q
  [!] This system does not have makepkg installed
  [!] Press Enter to continue and install
  [!] makepkg temporarily. Otherwise
  [!] press Ctrl+C to cancel, the driver package
  [!] will NOT be created.
Q
		read -p ""
		echo "  [>] Installing makepkg to ${DATA_TMP}..."
		if ! ls "${DATA_TMP}"/pkgtools*.txz 1> /dev/null 2>&1
		then
			echo "    [!] pkgtools not found. Downloading..."
			wget -q -nc --show-progress --progress=bar:force:noscroll https://slackware.uk/slackware/slackware64-15.0/slackware64/a/pkgtools-15.0-noarch-42.txz -P "${DATA_TMP}" || { echo "    [!] Error while downloading pkgtools package, please download Slackware pkgtool and put it manually in ${DATA_TMP}"; exit 1; }
		fi
		tar -C "${DATA_TMP}" -xf "${DATA_TMP}"/pkgtools* >>"${LOG_F}" 2>&1
		MAKEPKG=${DATA_TMP}/sbin/makepkg
		command -v "${MAKEPKG}" 1> /dev/null 2>&1 && echo "    [✓] makepkg has been installed to ${DATA_TMP}" || { echo "    [!] makepkg was not installed properly. Quitting."; exit 1; }
	fi
	echo "  [>] Making the package, this might take a while..."
	"${MAKEPKG}" -l n -c n "$TMP_DIR"/${PLUGIN_NAME%%-*}-"${NV_DRV_V}"-"${UNAME%/}"-1.txz >>"${LOG_F}" 2>&1
	md5sum "$TMP_DIR"/${PLUGIN_NAME%%-*}-"${NV_DRV_V}"-"${UNAME%/}"-1.txz | awk '{print $1}' | tee -a "$TMP_DIR"/${PLUGIN_NAME%%-*}-"${NV_DRV_V}"-"${UNAME%/}"-1.txz.md5 >>"${LOG_F}" 2>&1
	echo "  [>] Creating Out folder in ${DATA_DIR}"
	mkdir -p "${DATA_DIR}"/out && echo " [✓] Created Out dir."
	echo "  [>] Copying the resulting drivers..."
	cp -R "$TMP_DIR"/"${PLUGIN_NAME%%-*}"-"${NV_DRV_V}"-"${UNAME%/}"-1.txz* "${DATA_DIR}"/out
	echo ""
	echo "   [i] Filename: ${DATA_DIR}/out/${PLUGIN_NAME%%-*}-${NV_DRV_V}-${UNAME%/}-1.txz"
	echo "   [i] MD5 Hash: $(cat ${DATA_DIR}/out/${PLUGIN_NAME%%-*}-${NV_DRV_V}-${UNAME%/}-1.txz.md5)"
	echo "   [i] Size: $(du -kh ${DATA_DIR}/out/${PLUGIN_NAME%%-*}-${NV_DRV_V}-${UNAME%/}-1.txz | cut -f1)"
	echo ""
	echo " [✓] Done, check for errors."
	echo -e '\a'
}

run_cmd() {
	# catches errors and shows the line

    local command="$@"
    local exit_status=0
    local line_number=$LINENO

    # Run the command
    eval "$command"
    exit_status=$?

    # Check the exit status
    if [ $exit_status -ne 0 ]; then
        echo "[!] Command failed with exit status $exit_status at line $line_number"
        exit $exit_status
    fi
}

main_run() {
	trap cleanup INT
	run_cmd files_prepare
	if [[ -z "${SKIP_KERNEL}" ]]; then
		run_cmd build_kernel
	fi
	run_cmd link_sauce
	run_cmd nv_inst
	run_cmd copy_files
	run_cmd libnvidia_inst
	run_cmd package_building
}

######### SCRIPT ##########

# Options setup

while getopts 'n:u:shc' OPTION; do
	case "$OPTION" in
		n)
			NV_RUN="$OPTARG"
			echo " [i] Got Nvidia driver: ${NV_RUN}"
			;;
		u)
			UNRAID_DIR="$OPTARG"
			echo " [i] Got Unraid source: ${UNRAID_DIR}"
			;;
		s)
			SKIP_KERNEL=1
			echo " [i] Skipping kernel build. ONLY USE THIS IF KERNEL IS ALREADY BUILT!"
			;;
		h)
			echo -e "\n [i] Usage: sudo bash $(basename $0) [-n NVIDIA_RUN_INSTALLER] [-u UNRAID_SOURCE_FOLDER]\n"
			exit 0
			;;
		c)
			echo -e "\n [i] Cleaning up after script end."
			CLEANUP_END=1
			exit 0
			;;
		?)
			echo -e "\n [i] Usage: sudo bash $(basename $0) [-n NVIDIA_RUN_INSTALLER] [-u UNRAID_SOURCE_FOLDER]\n"
			exit 1
			;;
	esac
done

# Actual RUN

## Sauces ##

	# Source libnvidia-container: https://github.com/ich777/libnvidia-container
	# Source nvidia-container-runtime: https://github.com/ich777/nvidia-container-runtime
	# Source nvidia-container-toolkit: https://github.com/ich777/nvidia-container-toolkit

## VARS ##

  # WORK DIRS
DATA_DIR=$(pwd)
DATA_TMP=$(pwd)/tmp
NV_TMP_D="${DATA_TMP}/NVIDIA"
LOG_F="$DATA_DIR/logfile_$(date +'%Y.%m.%d')_$RANDOM".log

  # System Cap
CPU_COUNT=$(nproc)

  # Features
SKIP_KERNEL=

  # Docker Support
LIBNVIDIA_CONTAINER_V=1.14.3
CONTAINER_TOOLKIT_V=1.14.3

if [[ -z "${NV_RUN}" ]] || [[ -z "${UNRAID_DIR}" ]]; then
	if [[ "${CLEANUP_END}" -eq 1 ]]; then
		run_cmd cleanup
	else
		tee <<ERR
	
 [!] Please provide both [-u] and [-n]."
 [i] Usage:"
 [i] -n NVIDIA_RUN_INSTALLER.run"
 [i] -u UNRAID_SOURCE_FOLDER (linux-X.XX.XX-Unraid)"
	
ERR
	exit 1
	fi
elif [[ -n ${NV_RUN} ]] && [[ -n ${UNRAID_DIR} ]]; then
	tee <<WEL

 [!] Welcome to Nvidia driver packager for Unraid
 [!] Note: This sctipt has been tested with Nvidia drivers version: 525.85/525.105 
 [!] Sleeping 3 seconds before proceeding...

WEL
	sleep 3
	UNAME=$(echo "${UNRAID_DIR}" | sed 's/linux-//')
	LNX_MAJ_NUMBER=$(echo "${UNAME%/}" | cut -d "." -f1)
	LNX_FULL_VER=$(echo "${UNAME%/}" | cut -d "-" -f1)
	declare -g UNAME
	declare -g LNX_MAJ_NUMBER
	declare -g LNX_FULL_VER
	# declare -g LIBNVIDIA_CONTAINER_V=1.14.3
	# declare -g CONTAINER_TOOLKIT_V=1.14.3
	if [[ "${CLEANUP_END}" -eq 1 ]]; then
		run_cmd main_run
		run_cmd cleanup
	else
		run_cmd main_run
	fi
fi

echo <<END

	[!] Script Ended.

END

exit 0
