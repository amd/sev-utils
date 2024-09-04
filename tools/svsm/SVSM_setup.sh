#!/bin/bash

set -eux
set -eE
set -u
set -o pipefail

# Function to display usage information
usage() {
    cat <<EOF
Usage: $0 {setup_install|build_host_kernel|build_guest_kernel|install_igvm|build_qemu|build_edk2|build_svsm|build_all}

Commands:
  setup_install      Install all necessary dependencies and tools
  build_host_kernel  Build the host kernel with SVSM support
  build_guest_kernel Build the guest kernel with SVSM support
  install_igvm       Install the IGVM tool
  build_qemu         Build QEMU with SVSM support
  build_edk2         Build EDK2 with SVSM support
  build_svsm         Build coconut-svsm
  build_all          Perform all the above actions in sequence
EOF
}

# Working directory setup
WORKING_DIR="${WORKING_DIR:-$HOME/coconut-svsm}"
SETUP_WORKING_DIR="${SETUP_WORKING_DIR:-${WORKING_DIR}/setup}"

# Check if the directory exists
if [ -d "$WORKING_DIR" ]; then
  echo "Directory '$WORKING_DIR' already exists and is not empty. Deleting it..."
  rm -rf "WORKIG_DIR/"
  WORKING_DIR="${WORKING_DIR:-$HOME/coconut-svsm}"
fi

export WORKSPACE=${WORKSPACE:-"/home/amd"}
export PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-""}



# Function to log messages
log() {
    local level="$1"
    local message="$2"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $level: $message"
}

# Function to check command success
check_command() {
    local command="$1"
    local description="$2"
    if eval "$command"; then
        log "INFO" "$description: SUCCESS"
    else
        log "ERROR" "$description: FAILED"
        exit 1
    fi
}

# Function to install dependencies
install_dependencies() {
    log "INFO" "Updating package list..."
    check_command "sudo apt update" "Failed to update package list"

    log "INFO" "Installing dependencies..."
    check_command "sudo apt install -y \
        build-essential \
        curl \
        git \
        libclang-dev \
        autoconf \
        autoconf-archive \
        pkg-config \
        automake \
        libssl-dev \
        perl \
        libc6-dev \
        gcc-multilib \
        make \
        gcc \
        binutils" "Failed to install dependencies"
}

# Function to install Rust
install_rust() {
    log "INFO" "Installing Rust..."
    check_command "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y" "Failed to install Rust"

    log "INFO" "Sourcing Rust environment..."
    check_command "source $HOME/.cargo/env" "Failed to source Rust environment"

    log "INFO" "Adding Rust target..."
    check_command "rustup target add x86_64-unknown-none" "Failed to add Rust target"

    log "INFO" "Verifying Rust installation..."
    check_command "rustc --version" "Failed to verify Rust installation"
}

# Main function to install all components
install_all() {
    install_dependencies
    install_rust

    log "INFO" "All installations completed successfully!"
}




#!/bin/bash

# Function to build Linux host kernel with SVSM support
build_host_kernel() {
    # Set the working directory
    cd "$SETUP_WORKING_DIR" || { echo "Failed to change directory to $SETUP_WORKING_DIR"; exit 1; }
    
    local dir="host"
    
    # Check if the directory exists and remove it if necessary
    if [ -d "$dir" ]; then
        echo "Directory '$dir' already exists. Removing it..."
        rm -rf "$dir" || { echo "Failed to remove directory $dir"; exit 1; }
    fi

    # Create and navigate to the new directory
    mkdir "$dir" || { echo "Failed to create directory $dir"; exit 1; }
    cd "$dir" || { echo "Failed to change directory to $dir"; exit 1; }

    # Clone the kernel repository and switch to the appropriate branch
    echo "Cloning the kernel repository..."
    git clone https://github.com/coconut-svsm/linux || { echo "Failed to clone repository"; exit 1; }
    cd linux || { echo "Failed to change directory to linux"; exit 1; }
    git checkout svsm || { echo "Failed to checkout branch svsm"; exit 1; }

    # Create a script to configure and build the kernel
    cat << 'EOF' > host_kernel.sh
#!/bin/bash

set -eux

# Define version and commit variables
VER="-snp-host"
COMMIT=$(git log --format="%h" -1 HEAD)

# Copy the current kernel configuration and set local version
cp /boot/config-$(uname -r) .config
./scripts/config --set-str LOCALVERSION "$VER-$COMMIT"
./scripts/config --disable LOCALVERSION_AUTO
./scripts/config --enable DEBUG_INFO
./scripts/config --enable DEBUG_INFO_REDUCED
./scripts/config --enable EXPERT
./scripts/config --enable AMD_MEM_ENCRYPT
./scripts/config --disable AMD_MEM_ENCRYPT_ACTIVE_BY_DEFAULT
./scripts/config --enable KVM_AMD_SEV
./scripts/config --module CRYPTO_DEV_CCP_DD
./scripts/config --disable SYSTEM_TRUSTED_KEYS
./scripts/config --disable SYSTEM_REVOCATION_KEYS
./scripts/config --module SEV_GUEST
./scripts/config --disable IOMMU_DEFAULT_PASSTHROUGH

# Update configuration and build kernel
yes "" | make olddefconfig
make -j$(nproc) LOCALVERSION=
sudo make -j$(nproc) modules_install
sudo make -j$(nproc) install
EOF

    # Make the script executable and run it
    chmod +x host_kernel.sh || { echo "Failed to make host_kernel.sh executable"; exit 1; }
    ./host_kernel.sh || { echo "Failed to execute host_kernel.sh"; exit 1; }

    # Return to the previous directory
    cd .. || { echo "Failed to return to the previous directory"; exit 1; }
}


#!/bin/bash

# Function to build Linux guest kernel with SVSM support
build_guest_kernel() {
    # Navigate to the working directory
    cd "$SETUP_WORKING_DIR" || { echo "Failed to change directory to $SETUP_WORKING_DIR"; exit 1; }

    local dir="guest"
    
    # Check if the directory exists and remove it if necessary
    if [ -d "$dir" ]; then
        echo "Directory '$dir' already exists. Removing it..."
        rm -rf "$dir" || { echo "Failed to remove directory $dir"; exit 1; }
    fi

    # Create and navigate to the new directory
    mkdir "$dir" || { echo "Failed to create directory $dir"; exit 1; }
    cd "$dir" || { echo "Failed to change directory to $dir"; exit 1; }

    # Clone the kernel repository and switch to the appropriate branch
    echo "Cloning the kernel repository..."
    git clone https://github.com/coconut-svsm/linux || { echo "Failed to clone repository"; exit 1; }
    cd linux || { echo "Failed to change directory to linux"; exit 1; }
    git checkout svsm || { echo "Failed to checkout branch svsm"; exit 1; }

    # Create a script to configure and build the guest kernel
    cat << 'EOF' > guest_kernel.sh
#!/bin/bash

set -eux

# Define version and commit variables
VER="-snp-guest"
COMMIT=$(git log --format="%h" -1 HEAD)

# Copy the current kernel configuration and set local version
cp /boot/config-$(uname -r) .config
./scripts/config --set-str LOCALVERSION "$VER-$COMMIT"
./scripts/config --disable LOCALVERSION_AUTO
./scripts/config --enable DEBUG_INFO
./scripts/config --enable DEBUG_INFO_REDUCED
./scripts/config --enable EXPERT
./scripts/config --enable AMD_MEM_ENCRYPT
./scripts/config --disable AMD_MEM_ENCRYPT_ACTIVE_BY_DEFAULT
./scripts/config --enable KVM_AMD_SEV
./scripts/config --module CRYPTO_DEV_CCP_DD
./scripts/config --disable SYSTEM_TRUSTED_KEYS
./scripts/config --disable SYSTEM_REVOCATION_KEYS
./scripts/config --enable SEV_GUEST
./scripts/config --disable IOMMU_DEFAULT_PASSTHROUGH
./scripts/config --enable TCG_PLATFORM

# Update configuration and build kernel packages
yes "" | make -j$(nproc) olddefconfig
make -j$(nproc) LOCALVERSION= bindeb-pkg || { echo "Kernel build failed"; exit 1; }

EOF

    # Make the script executable and run it
    chmod +x guest_kernel.sh || { echo "Failed to make guest_kernel.sh executable"; exit 1; }
    ./guest_kernel.sh || { echo "Failed to execute guest_kernel.sh"; exit 1; }

    # Return to the previous directory
    cd .. || { echo "Failed to return to the previous directory"; exit 1; }
}


#!/bin/bash

# Function to install IGVM
install_igvm() {
    # Navigate to the working directory
    cd "$SETUP_WORKING_DIR" || { echo "Failed to change directory to $SETUP_WORKING_DIR"; exit 1; }

    # Clean up any existing IGVM files or directories
    echo "Cleaning up existing IGVM files..."
    rm -rf ./*igvm* || { echo "Failed to remove existing IGVM files"; exit 1; }

    # Download IGVM package
    local igvm_version="v0.1.6"
    local igvm_zip="igvm-${igvm_version}.zip"
    local igvm_dir="igvm-${igvm_version}"

    echo "Downloading IGVM version ${igvm_version}..."
    wget "https://github.com/microsoft/igvm/archive/refs/tags/${igvm_zip}" -O "${igvm_zip}" || { echo "Failed to download IGVM package"; exit 1; }

    # Unzip the downloaded package
    echo "Unzipping IGVM package..."
    unzip "${igvm_zip}" || { echo "Failed to unzip IGVM package"; exit 1; }

    # Navigate to the IGVM directory
    cd "igvm-${igvm_dir}" || { echo "Failed to change directory to ${igvm_dir}"; exit 1; }

    # Compile and install IGVM
    echo "Building IGVM..."
    make -f igvm_c/Makefile || { echo "Failed to build IGVM"; exit 1; }

    echo "Installing IGVM..."
    sudo make -f igvm_c/Makefile install || { echo "Failed to install IGVM"; exit 1; }

    # Set PKG_CONFIG_PATH environment variable
    export PKG_CONFIG_PATH=/usr/lib64/pkgconfig:$PKG_CONFIG_PATH
    echo "IGVM installation complete. PKG_CONFIG_PATH set to $PKG_CONFIG_PATH."
}




# Function to build QEMU with SVSM support
build_qemu() {
    # Define variables
    local working_dir="$SETUP_WORKING_DIR"
    local repo_url="https://github.com/coconut-svsm/qemu"
    local repo_dir="qemu"
    local branch="svsm-igvm"
    local install_prefix="$HOME/bin/qemu-svsm"

    # Navigate to the working directory
    cd "$working_dir" || { echo "Failed to change directory to $working_dir"; exit 1; }

    # Clean up any existing QEMU directory
    if [ -d "$repo_dir" ]; then
        echo "Directory '$repo_dir' already exists. Removing it..."
        rm -rf "$repo_dir" || { echo "Failed to remove existing $repo_dir"; exit 1; }
    fi

    # Clone the QEMU repository
    echo "Cloning QEMU repository from $repo_url..."
    git clone "$repo_url" "$repo_dir" || { echo "Failed to clone QEMU repository"; exit 1; }

    # Navigate into the QEMU directory
    cd "$repo_dir" || { echo "Failed to change directory to $repo_dir"; exit 1; }

    # Checkout the appropriate branch
    echo "Checking out branch $branch..."
    git checkout "$branch" || { echo "Failed to checkout branch $branch"; exit 1; }

    # Configure the build
    echo "Configuring QEMU with prefix $install_prefix..."
    ./configure --prefix="$install_prefix" --target-list=x86_64-softmmu --enable-igvm || { echo "Configuration failed"; exit 1; }

    # Build QEMU
    echo "Building QEMU..."
    make "-j$(nproc)" || { echo "Build failed"; exit 1; }

    # Install QEMU
    echo "Installing QEMU..."
    sudo make install || { echo "Installation failed"; exit 1; }

    echo "QEMU built and installed successfully with SVSM support."
}





# Function to build EDK2 with SVSM support
build_edk2() {
    # Define variables
    local working_dir="$SETUP_WORKING_DIR"
    local repo_url="https://github.com/coconut-svsm/edk2.git"
    local repo_dir="edk2"
    local branch="svsm"
    local tools_dir="BaseTools"
    local build_target="DEBUG"
    local build_toolchain="GCC5"
    local build_flags="-D DEBUG_ON_SERIAL_PORT -D DEBUG_VERBOSE -DTPM2_ENABLE"
    local build_package="OvmfPkg/OvmfPkgX64.dsc"

    # Navigate to the working directory  
    pushd "$working_dir" >/dev/null
    # Clean up any existing EDK2 directory
    if [ -d "$repo_dir" ]; then
        echo "Directory '$repo_dir' already exists. Removing it..."
        rm -rf "$repo_dir" || { echo "Failed to remove existing $repo_dir"; exit 1; }
    fi

    # Clone the EDK2 repository
    echo "Cloning EDK2 repository from $repo_url..."
    git clone "$repo_url" "$repo_dir" || { echo "Failed to clone EDK2 repository"; exit 1; }

    # Navigate into the EDK2 directory
    cd "$repo_dir" || { echo "Failed to change directory to $repo_dir"; exit 1; }   

    # Checkout the appropriate branch
    echo "Checking out branch $branch..."
    git checkout "$branch" || { echo "Failed to checkout branch $branch"; exit 1; }

    # Initialize and update submodules
    echo "Initializing and updating submodules..."
    git submodule init || { echo "Failed to initialize submodules"; exit 1; }
    git submodule update || { echo "Failed to update submodules"; exit 1; }

    # Set up environment variables for the build
    echo "Setting up environment variables..."
    export PYTHON3_ENABLE=TRUE
    export PYTHON_COMMAND=python3

    # Build BaseTools
    echo "Building BaseTools..."
    make "-j$(nproc)" -C "$tools_dir" || { echo "Failed to build BaseTools"; exit 1; }

    # Set up EDK2 environment
    echo "Setting up EDK2 environment..."   
    source ./edksetup.sh --reconfig || { echo "Failed to reconfigure EDK2 environment"; exit 1; }     

    # Build the EDK2 package
    echo "Building EDK2 with target $build_target and toolchain $build_toolchain..."
    build -a X64 -b "$build_target" -t "$build_toolchain" "$build_flags" -p "$build_package" || { echo "Failed to build EDK2 package"; exit 1; }
     popd >/dev/null
    echo "EDK2 build completed successfully."
}


# Function to build coconut-svsm
build_svsm() {
    # Define variables
    local working_dir="$SETUP_WORKING_DIR"
    local repo_url="https://github.com/coconut-svsm/svsm"
    local repo_dir="svsm"
    local fw_file="$working_dir/edk2/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd"
    
    # Navigate to the working directory
    cd "$working_dir" || { echo "Failed to change directory to $working_dir"; exit 1; }

    # Remove existing directory if it exists
    if [ -d "$repo_dir" ]; then
        echo "Directory '$repo_dir' already exists. Removing it..."
        rm -rf "$repo_dir" || { echo "Failed to remove existing $repo_dir"; exit 1; }
    fi

    # Clone the SVSM repository
    echo "Cloning SVSM repository from $repo_url..."
    git clone "$repo_url" "$repo_dir" || { echo "Failed to clone SVSM repository"; exit 1; }

    # Navigate into the SVSM directory
    cd "$repo_dir" || { echo "Failed to change directory to $repo_dir"; exit 1; }

    # Initialize and update submodules
    echo "Initializing and updating submodules..."
    git submodule update --init || { echo "Failed to initialize or update submodules"; exit 1; }

    # Install necessary tools
    echo "Installing bindgen CLI..."
    cargo install bindgen-cli || { echo "Failed to install bindgen-cli"; exit 1; }

    # Check if the firmware file exists
    if [ ! -f "$fw_file" ]; then
        echo "Firmware file '$fw_file' does not exist. Exiting..."
        exit 1
    fi

    # Build SVSM
    echo "Building SVSM..."
    FW_FILE="$fw_file" make || { echo "Failed to build SVSM"; exit 1; }

    echo "SVSM build completed successfully."
}



# Main function to parse command-line arguments and call appropriate functions
main() {
    if [ "$#" -ne 1 ]; then
        echo "Error: Exactly one argument is required."
        usage
        exit 1
    fi

    case "$1" in
        setup_install)
            install_all
            ;;
        build_host_kernel)
            build_host_kernel
            ;;
        build_guest_kernel)
            build_guest_kernel
            ;;
        install_igvm)
            install_igvm
            ;;
        build_qemu)
            build_qemu
            ;;
        build_edk2)
            build_edk2
            ;;
        build_svsm)
            build_svsm
            ;;
        build_all)
            install_all
            build_host_kernel
            build_guest_kernel
            install_igvm
            build_qemu
            build_edk2
            build_svsm
            ;;
        *)
            echo "Error: Invalid command."
            usage
            exit 1
            ;;
    esac
}

# Execute the main function with command-line arguments
main "$@"
