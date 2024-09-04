#!/bin/bash
#  SPDX-License-Identifier: MIT
#
#  Copyright (C) 2023 Advanced Micro Devices, Inc.  


set -eE
set -o pipefail
[ "$DEBUG" == 'true' ] && set -x

#trap cleanup EXIT

# Working directory setup
WORKING_DIR="${WORKING_DIR:-$HOME/coconut-svsm}"
SETUP_WORKING_DIR="${SETUP_WORKING_DIR:-${WORKING_DIR}/setup}"
LAUNCH_WORKING_DIR="${LAUNCH_WORKING_DIR:-${WORKING_DIR}/launch}"
ATTESTATION_WORKING_DIR="${ATTESTATION_WORKING_DIR:-${WORKING_DIR}/attest}"

# Export environment variables
COMMAND="help"
SKIP_IMAGE_CREATE=false
HOST_SSH_PORT="${HOST_SSH_PORT:-10022}"
GUEST_NAME="${GUEST_NAME:-snp-guest}"
GUEST_SIZE_GB="${GUEST_SIZE_GB:-50}"
GUEST_MEM_SIZE_MB="${GUEST_MEM_SIZE_MB:-2048}"
GUEST_SMP="${GUEST_SMP:-4}"
CPU_MODEL="${CPU_MODEL:-EPYC-v4}"
GUEST_USER="${GUEST_USER:-amd}"
GUEST_PASS="${GUEST_PASS:-amd}"
GUEST_SSH_KEY_PATH="${GUEST_SSH_KEY_PATH:-${LAUNCH_WORKING_DIR}/${GUEST_NAME}-key}"
GUEST_ROOT_LABEL="${GUEST_ROOT_LABEL:-cloudimg-rootfs}"
GUEST_KERNEL_APPEND="root=LABEL=${GUEST_ROOT_LABEL} ro console=ttyS0"
QEMU_CMDLINE_FILE="${QEMU_CMDLINE:-${LAUNCH_WORKING_DIR}/qemu.cmdline}"
IMAGE="${IMAGE:-${LAUNCH_WORKING_DIR}/${GUEST_NAME}.img}"
GENERATED_INITRD_BIN="${SETUP_WORKING_DIR}/initrd.img"

# URLs and repos
CLOUD_INIT_IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

usage() {
  >&2 echo "Usage: $0 [OPTIONS] [COMMAND]"
  >&2 echo "  where COMMAND must be one of the following:"
  >&2 echo "    setup-host            Build required SNP components and set up host"
  >&2 echo "    launch-guest          Launch a SNP guest"
  >&2 echo "    attest-guest          Use virtee/snpguest and sev-snp-measure to attest a SNP guest"
  >&2 echo "    stop-guests           Stop all SNP guests started by this script"  
  return 1
}

generate_guest_ssh_keypair() {
  if [[ -f "${GUEST_SSH_KEY_PATH}" \
    && -f "${GUEST_SSH_KEY_PATH}.pub" ]]; then
    echo -e "Guest SSH key pair already generated"
    return 0
  fi

  # Create ssh key to access vm
  ssh-keygen -q -t ed25519 -N '' -f "${GUEST_SSH_KEY_PATH}" <<<y
}

cloud_init_create_data() {
  if [[ -f "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-metadata.yaml" && \
    -f "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-user-data.yaml"  && \
    -f "${IMAGE}" ]]; then
    echo -e "cloud-init data already generated"
    return 0
  fi

  local pub_key=$(cat "${GUEST_SSH_KEY_PATH}.pub")

# Seed image metadata
cat > "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-metadata.yaml" <<EOF
instance-id: "${GUEST_NAME}"
local-hostname: "${GUEST_NAME}"
EOF

# Seed image user data
cat > "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-user-data.yaml" <<EOF
#cloud-config
chpasswd:
  expire: false
ssh_pwauth: true
users:
  - default
  - name: ${GUEST_USER}
    plain_text_passwd: ${GUEST_PASS}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - ${pub_key}
EOF

  # Create the seed image with metadata and user data
  cloud-localds "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-seed.img" \
    "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-user-data.yaml" \
    "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-metadata.yaml"

  # Download ubuntu 20.04 and change name
  wget "${CLOUD_INIT_IMAGE_URL}" -O "${IMAGE}"
  qemu-img info "${IMAGE}"
}

get_guest_kernel_version() {    
  local guest_kernel_config="${SETUP_WORKING_DIR}/guest/linux/vmlinux"
  local kernel_version=$(strings guest_kernel_config | grep -a "Linux version" | head -n 1 | awk '{print $3}')
  local guest_kernel="${kernel_version}"
  echo "${guest_kernel}"
}

save_binary_paths() {
  local guest_kernel_version=$(strings "${SETUP_WORKING_DIR}"/guest/linux/vmlinux | grep -a "Linux version" | head -n 1 | awk '{print $3}')
  GENERATED_INITRD_BIN="${SETUP_WORKING_DIR}/initrd.img-${guest_kernel_version}"
  GENERATED_KERNEL_BIN="${SETUP_WORKING_DIR}/vmlinuz-${guest_kernel_version}"

# Save binary paths in source file
cat > "${SETUP_WORKING_DIR}/source-bins" <<EOF
QEMU_BIN="${SETUP_WORKING_DIR}/qemu/build/qemu-system-x86_64"
OVMF_BIN="${SETUP_WORKING_DIR}/edk2/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd"
IGVM_FILE="${SETUP_WORKING_DIR}/svsm/bin/coconut-qemu.igvm"
INITRD_BIN="${GENERATED_INITRD_BIN}"
KERNEL_BIN="${GENERATED_KERNEL_BIN}"
EOF
}

copy_launch_binaries() {
  # Source the bins generated from setup
  source "${SETUP_WORKING_DIR}/source-bins"

  # Skip if task previously completed
  if [ -f "${LAUNCH_WORKING_DIR}/source-bins" ]; then
    echo -e "Guest launch binaries previously copied"
    return 0
  fi

  # Create directory
  mkdir -p "${LAUNCH_WORKING_DIR}"

# Save binary paths in source file
cat > "${LAUNCH_WORKING_DIR}/source-bins" <<EOF
INITRD_BIN="${LAUNCH_WORKING_DIR}/$(basename "${INITRD_BIN}")"
KERNEL_BIN="${LAUNCH_WORKING_DIR}/$(basename "${KERNEL_BIN}")"
EOF
}

add_qemu_cmdline_opts() {
  echo -e "\\" >> "${QEMU_CMDLINE_FILE}"
  echo -n "$* " >> "${QEMU_CMDLINE_FILE}"
}

build_base_qemu_cmdline() {
  # Return error if user specified file that doesn't exist
  qemu_bin="${1}"
  if [ ! -f "${qemu_bin}" ]; then
    >&2 echo -e "QEMU binary does not exist or was not specified"
    return 1
  fi

  # Create qemu files if they don't exist, set permissions
  touch "${LAUNCH_WORKING_DIR}/qemu.log"
  touch "${LAUNCH_WORKING_DIR}/qemu-trace.log"
  #touch "${LAUNCH_WORKING_DIR}/ovmf.log"
  touch "${QEMU_CMDLINE_FILE}"
  chmod +x "${QEMU_CMDLINE_FILE}"

  # Base cmdline
  echo -n "${qemu_bin} " > "${QEMU_CMDLINE_FILE}"
  add_qemu_cmdline_opts "--enable-kvm"
  add_qemu_cmdline_opts "-cpu ${CPU_MODEL}"
  add_qemu_cmdline_opts "-machine q35"
  add_qemu_cmdline_opts "-smp ${GUEST_SMP}"
  add_qemu_cmdline_opts "-m ${GUEST_MEM_SIZE_MB}M"
  add_qemu_cmdline_opts "-no-reboot"
  add_qemu_cmdline_opts "-vga std"
  add_qemu_cmdline_opts "-monitor pty"
  add_qemu_cmdline_opts "-daemonize"

  # Networking
  add_qemu_cmdline_opts "-netdev user,hostfwd=tcp::${HOST_SSH_PORT}-:22,id=vmnic"
  add_qemu_cmdline_opts "-device virtio-net-pci,disable-legacy=on,iommu_platform=true,netdev=vmnic,romfile="

  # Storage
  add_qemu_cmdline_opts "-device virtio-scsi-pci,id=scsi0,disable-legacy=on,iommu_platform=true"
  add_qemu_cmdline_opts "-device scsi-hd,drive=disk0"
  add_qemu_cmdline_opts "-drive if=none,id=disk0,format=qcow2,file=${IMAGE}"

  # qemu standard and trace logging
  add_qemu_cmdline_opts "-serial file:${LAUNCH_WORKING_DIR}/qemu.log"
  add_qemu_cmdline_opts "--trace \"kvm_sev*\""
  add_qemu_cmdline_opts "-D ${LAUNCH_WORKING_DIR}/qemu-trace.log"
  add_qemu_cmdline_opts "-global isa-debugcon.iobase=0x402"
  
}

stop_guests() {
  local qemu_processes=$(ps aux | grep "${WORKING_DIR}.*qemu.*${IMAGE}" | grep -v "tail.*qemu.log" | grep -v "grep.*qemu")
  [[ -n "${qemu_processes}" ]] || { echo -e "No qemu processes currently running"; return 0; }

  echo -e "Current running qemu process:"
  echo "${qemu_processes}"

  echo -e "\nKilling qemu process..."
  pkill -9 -f "${WORKING_DIR}.*qemu.*${IMAGE}" || true
  sleep 3

  echo -e "Verifying no qemu processes running..."
  qemu_processes=$(ps aux | grep "${WORKING_DIR}.*qemu.*${IMAGE}" | grep -v "tail.*qemu.log" | grep -v "grep.*qemu")

  [[ -z "${qemu_processes}" ]] || { >&2 echo -e "FAIL: qemu processes still exist:\n${qemu_processes}"; return 1; }
  echo -e "No qemu processes running!"
}

setup_and_install_SVSM_builds() {
  
 # Create directory
  mkdir -p "${SETUP_WORKING_DIR}"
  ./SVSM_setup.sh build_all   
  
  # Add the user to kvm group so that qemu can be run without root permissions
  sudo usermod -a -G kvm "${USER}" 

  # Save binary paths in source file
  save_binary_paths
}

setup_and_launch_svsm_guest() {
  # Return error if user specified file that doesn't exist
  if [ ! -f "${IMAGE}" ] && ${SKIP_IMAGE_CREATE}; then
    >&2 echo -e "Image file specified, but doesn't exist"
    return 1
  fi

  
  # Build base qemu cmdline and add direct boot bins
  build_base_qemu_cmdline "${QEMU_BIN}"

  # If the image file doesn't exist, setup
  if [ ! -f "${IMAGE}" ]; then
    generate_guest_ssh_keypair
    cloud_init_create_data

    
    # For the cloud-init image, just resize the image
    qemu-img resize "$IMAGE" "${GUEST_SIZE_GB}G"

    # Add seed image option to qemu cmdline
    add_qemu_cmdline_opts "-device scsi-hd,drive=disk1"
    add_qemu_cmdline_opts "-drive if=none,id=disk1,format=raw,file=${LAUNCH_WORKING_DIR}/${GUEST_NAME}-seed.img"
  fi

  local guest_kernel_installed_file="${LAUNCH_WORKING_DIR}/guest_kernel_already_installed"
   
  if [ ! -f "${guest_kernel_installed_file}" ]; then
    # Launch qemu cmdline
    "${QEMU_CMDLINE_FILE}"

    # Install the guest kernel, retrieve the initrd and then reboot
    local guest_kernel_version=$(strings "${SETUP_WORKING_DIR}"/guest/linux/vmlinux | grep -a "Linux version" | head -n 1 | awk '{print $3}')
    local guest_kernel_deb=$(echo "$(realpath "${SETUP_WORKING_DIR}"/guest/linux-image*snp-guest*.deb)" | grep -v dbg)
    local guest_initrd_basename="initrd.img-${guest_kernel_version}"
    local guest_vmlinuz_basename="vmlinuz-${guest_kernel_version}"
    wait_and_retry_command "scp_guest_command ${guest_kernel_deb} ${GUEST_USER}@localhost:/home/${GUEST_USER}"
    ssh_guest_command "sudo dpkg -i /home/${GUEST_USER}/$(basename "${guest_kernel_deb}")"
    scp_guest_command "${GUEST_USER}@localhost:/boot/${guest_initrd_basename}" "${LAUNCH_WORKING_DIR}"
    scp_guest_command "${GUEST_USER}@localhost:/boot/${guest_vmlinuz_basename}" "${LAUNCH_WORKING_DIR}"
    ssh_guest_command "sudo shutdown now" || true
    echo "true" > "${guest_kernel_installed_file}"

    # Update the initrd file path and name in the guest launch source-bins file
    sed -i -e "s|^\(INITRD_BIN=\).*$|\1\"${LAUNCH_WORKING_DIR}/${guest_initrd_basename}\"|g" "${LAUNCH_WORKING_DIR}/source-bins"    

    # A few seconds for shutdown to complete
    sleep 10    
    return 0
  fi
  
}

# Function to launch QEMU VM with Coconut SVSM
launch_qemu_svsm() {
    echo "Launching final QEMU VM with Coconut SVSM..."
    sudo "$QEMU_BIN" \
      --enable-kvm \
      -cpu EPYC-v4 \
      -machine q35,confidential-guest-support=sev0,memory-backend=mem0 \
      -smp 4 \
      -m 2048 \
      -no-reboot \
      -vga std \
      -nographic \
      -object memory-backend-memfd,size=2G,id=mem0,share=true,prealloc=false,reserve=off \
      -object sev-snp-guest,id=sev0,cbitpos=51,reduced-phys-bits=1,init-flags=5,igvm-file="$IGVM_FILE" \
      -netdev user,hostfwd=tcp::10022-:22,id=vmnic  \
      -netdev user,id=vmnic2 -device e1000,netdev=vmnic,romfile= \
      -device virtio-scsi-pci,id=scsi0,disable-legacy=on,iommu_platform=true \
      -device scsi-hd,drive=disk0 \
      -drive if=none,id=disk0,format=qcow2,file="$IMAGE" \
      -kernel "$KERNEL_BIN" \
      -initrd "$INITRD_BIN" \
      -append "$GUEST_KERNEL_APPEND" \
      -serial stdio \
      --trace "kvm_sev*" \
      -D /home/amd/snp/launch/qemu-trace.log \
      -monitor none 
      

}

ssh_guest_command() {
  [ -n "${1}" ] || { >&2 echo -e "No guest command specified"; return 1; }

  # Remove fail on error
  set +eE; set +o pipefail

  {
    IFS=$'\n' read -r -d '' CAPTURED_STDERR;
    IFS=$'\n' read -r -d '' CAPTURED_STDOUT;
    (IFS=$'\n' read -r -d '' _ERRNO_; return "${_ERRNO_}");
  } < <((printf '\0%s\0%d\0' "$(ssh -p "${HOST_SSH_PORT}" \
    -i "${GUEST_SSH_KEY_PATH}" \
    -o "StrictHostKeyChecking no" \
    -o "PasswordAuthentication=no" \
    -o ConnectTimeout=1 \
    -t "${GUEST_USER}"@localhost \
    "${1}")" "${?}" 1>&2) 2>&1)

  local return_code=$?

  # Reset fail on error
  set -eE; set -o pipefail

  [[ $return_code -eq 0 ]] \
    || { >&2 echo "${CAPTURED_STDOUT}"; >&2 echo "${CAPTURED_STDERR}"; return ${return_code}; }
  echo "${CAPTURED_STDOUT}"
}

scp_guest_command() {
  [ -n "${1}" ] || { >&2 echo -e "No scp source specified"; return 1; }
  [ -n "${2}" ] || { >&2 echo -e "No scp target specified"; return 1; }

  scp -r -P "${HOST_SSH_PORT}" \
    -i "${GUEST_SSH_KEY_PATH}" \
    -o "StrictHostKeyChecking no" \
    -o "PasswordAuthentication=no" \
    -o ConnectTimeout=1 \
    "${1}" "${2}"
}

verify_snp_guest() {
  # Exit if SSH private key does not exist
  if [ ! -f "${GUEST_SSH_KEY_PATH}" ]; then
    >&2 echo -e "SSH key not present [${GUEST_SSH_KEY_PATH}], cannot verify guest SNP enabled"
    return 1
  fi

  # Look for SNP enabled in guest dmesg output
  local snp_dmesg_grep_text="Memory Encryption Features active:.*SEV-SNP"
  local snp_enabled=$(ssh_guest_command "sudo dmesg | grep \"${snp_dmesg_grep_text}\"")

  [[ -n "${snp_enabled}" ]] \
    && { echo "DMESG REPORT: ${snp_enabled}"; echo -e "SNP is Enabled"; } \
    || { >&2 echo -e "SNP is NOT Enabled"; return 1; }
}

wait_and_verify_snp_guest() {
  local max_tries=30
  
  for ((i=1; i<=${max_tries}; i++)); do
    if ! (verify_snp_guest >/dev/null 2>&1); then
      sleep 1
      continue
    fi
    verify_snp_guest
    return 0
  done
  
  >&2 echo -e "ERROR: Timed out trying to connect to guest"
  return 1
}

wait_and_retry_command() {
  local command="${1}"
  local max_tries=30
  
  for ((i=1; i<=${max_tries}; i++)); do
    if ! (${command} >/dev/null 2>&1); then
      sleep 1
      continue
    fi
    ${command}
    return 0
  done
  
  >&2 echo -e "ERROR: Timed out trying to connect to guest"
  return 1
}
setup_guest_attestation() {
  ssh_guest_command "
   
    # Update and install necessary packages
    echo 'Updating package list...'
    sudo apt-get update

    echo 'Installing necessary packages...'
    sudo apt-get install -y git build-essential libtss2-dev tpm2-tools

    echo 'Installing Rust...'
    source ""${HOME}"/.cargo/env" 2>/dev/null || true

    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -sSf | sh -s -- -y
    source ""${HOME}"/.cargo/env" 2>/dev/null
    "    

  # Check if 'snpguest' directory exists and remove it if it does
  ssh_guest_command "
    if [ -d \"snpguest\" ]; then
        echo 'Directory snpguest exists. Removing it...'
        rm -rf snpguest
    else
        echo 'Directory snpguest does not exist.'
    fi
"

  # Clone the repository and build the project
  ssh_guest_command "git clone https://github.com/virtee/snpguest.git"
  ssh_guest_command "cd snpguest  &&  source \$HOME/.cargo/env &&  cargo build --release"
}


attest_guest() {
  local cpu_code_name="genoa"  

  # Request and display the snp attestation report with random data
  ssh_guest_command "
  cd $HOME/snpguest/target/release
  sudo ./snpguest report attestation-report.bin request-data.txt --random --vmpl 3;
  ./snpguest display report attestation-report.bin;
  ./snpguest fetch ca pem ${cpu_code_name} .;
  ./snpguest fetch vcek pem ${cpu_code_name} . attestation-report.bin;
  ./snpguest verify certs .;
  ./snpguest verify attestation . attestation-report.bin
"
}

Verify_measurement(){

    # Define the working directory and the output file
   OUTPUT_FILE="$SETUP_WORKING_DIR/make_output.txt"


# Define the firmware file path
FW_FILE="$SETUP_WORKING_DIR/edk2/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd"

cd "$SETUP_WORKING_DIR"/svsm

# Run the make command and save the output to a file
FW_FILE="$FW_FILE" make &> "$OUTPUT_FILE"

# Initialize the variable for Launch Digest
launch_digest=""

# Read the output file line by line to find the Launch Digest
while IFS= read -r line; do
  if [[ "$line" == *"Launch Digest:"* ]]; then
    launch_digest=$(echo "$line" | awk '{print $3}')
    break
  fi
done < "$OUTPUT_FILE"

# Output the Launch Digest to verify
echo "Launch Digest: $launch_digest"

  # Use sev-snp-measure utility to calculate the expected measurement
  local expected_measurement=$launch_digest
  echo -e "\nExpected Measurement (igvmmeasure):  ${expected_measurement}"

  # Parse the measurement out of the snp report
  scp_guest_command "${GUEST_USER}@localhost:$HOME/snpguest/target/release/attestation-report.bin" "$SETUP_WORKING_DIR/svsm"

  cd "$SETUP_WORKING_DIR"/svsm
  # Assign the output of the hexdump command to a variable
  snpguest_report_measurement=$(hexdump -s 0x90 -n 48 -v -e '48/1 "%02X"' attestation-report.bin)

    # Print the variable to verify its content
    echo "$snpguest_report_measurement"

   
   echo -e "Measurement from SNP Attestation Report: ${snpguest_report_measurement}\n"

   # Compare the expected measurement to the guest report measurement
  [[ "${expected_measurement}" == "${snpguest_report_measurement}" ]] \
    && echo -e "The expected measurement matches the snp guest report measurement!" \
    || { >&2 echo -e "FAIL: measurements do not match"; return 1; }


}


###############################################################################

# Main

main() {
  # A command must be specified
  if [ -z "${1}" ]; then
    usage
    return 1
  fi

  # Create working directory
  mkdir -p "${WORKING_DIR}"
  
  # Parse command args and options
  while [ -n "${1}" ]; do
    case "${1}" in
      -h|--help)
        usage
        ;;

      setup-host)
        COMMAND="setup-host"
        shift
        ;;

      launch-guest)
        COMMAND="launch-guest"
        shift
        ;;

      attest-guest)
        COMMAND="attest-guest"
        shift
        ;;

      stop-guests)
        COMMAND="stop-guests"
        shift
        ;;

      esac
  done
  
  

  # Execute command
  case "${COMMAND}" in
    help)
      usage
      return 1
      ;;

    setup-host)
            
      setup_and_install_SVSM_builds     

      source "${SETUP_WORKING_DIR}/source-bins"
      
      ;;

    launch-guest)
      if [ ! -d "${SETUP_WORKING_DIR}" ]; then
        echo -e "Setup directory does not exist, please run 'setup-host' prior to 'launch-guest'"
        return 1
      fi

      copy_launch_binaries
      source "${LAUNCH_WORKING_DIR}/source-bins"
      #verify_snp_host      
      setup_and_launch_svsm_guest
      launch_qemu_svsm      

      echo -e "Guest SSH port forwarded to host port: ${HOST_SSH_PORT}"
      echo -e "The guest is running in the background. Use the following command to access via SSH:"
      echo -e "ssh -p ${HOST_SSH_PORT} -i ${LAUNCH_WORKING_DIR}/snp-guest-key amd@localhost"
      ;;

    attest-guest)
      #install_rust
      wait_and_retry_command verify_snp_guest
      setup_guest_attestation
      attest_guest
      Verify_measurement
      ;;

    stop-guests)
      stop_guests
      ;;

    *)
      >&2 echo -e "Unsupported Command: [${1}]\n"
      usage
      return 1
      ;;
  esac
}
main "${@}"
