# Unraid Nvidia vGPU drivers builder

A Script based on ich777 building tools for regular nvidia drivers.
Due to licensing, I will not and cannot upload the nvidia vgpu drivers, you will have to source the drivers package yourself and build it on your own for Unraid.

## Requirements:

- VM running Ubuntu (22.04 LTS tested)
   - I haven't tried any other OS, you may try and see if that works
- Enough threads in the vm to build the linux kernel (the more threads you allocate the faster the build times)
- 8GB of RAM (min)
- 128GB of fast storage (min)
- `git fakeroot build-essential ncurses-dev xz-utils libssl-dev bc flex libelf-dev fakeroot bison build-essential clang dwarves` packages to be installed to build the kernel (I just googled how to compile the linux kernel on ubuntu, the packages listed here might not be enough depending on the version being built)

## How to:

0. Install the dependencies
1. Make a folder named nvidia somewhere and put the script inside that folder (the folder must be on a linux filesystem, like btrfs/ext4)
2. Copy in the nvidia folder the Unraid linux src folder found under `/usr/src` (eg. `/usr/src/linux-6.8.12-Unraid/`)
3. Source your nvidia vgpu package from nvidia's portal and put it in the nvidia folder
4. Open terminal inside the folder and run `sudo ./unraid-nvidia-building.sh -u linux-<version>-Unraid -n <nvidia_drivers_package>.run` (replace the linux version with the one you copied, eg 6.8.12, and put the full nvidia package name after `-n` option)
5. Let it build (might take minutes to hours depending on how much resources you gave to the vm)
6. You will get a folder named `out` that will contain 2 files: the unraid package + md5 

## Script options:

**-n [file]**: Points to Nvidia drivers package (.run file)
**-u [folder]**: Points to unraid's linux src folder
**-h**: Displays help
**-s**: Skips building kernel (only used for debug purposes)
**-c**: Cleans up temporary files/folder after building

## Tested versions:

- 6.12.x (tested and working)
- 7.x (NOT TESTED, I'm running unraid inside a vm, not as my host)

## Notes:

- Due to some unmet nvidia drivers deps, you might need to install `elfutil` on unraid on your own, along with other deps, please use `strace` (which you also need to install on your own) to find out which deps are needed, I haven't used nvidia vgpu drivers on unraid for a while, so I forgot which ones are needed
- Some Docker containers might not work well on first start up with these drivers (noticed it with jellyfin, handbrake and the such), restarting the containers will fix it, I do not know why that happens.

## Contribution:

You may contribute to better the building script. I wrote it as quick and dirty script to build the drivers package, so it's a "works on my machine" kind of thing. If you have any way to expand, correct and fix anything with this script, please feel free to do so. I'm thinking of rewriting it in python, but with some irl stuff, it might take a wile before I get there. This script has been shared since some people wanted to use it on their own machines.

## License: 

GPL-3.0
