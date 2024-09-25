# SNP Utility Script (snp.sh)

This SNP utility script is a provisioning and test script that performs three tasks:

1. Sets up an AMD EPYC CPU powered server by building the required patched versions 
of qemu, ovmf and the linux kernel.

2. Direct boot launch a SNP enabled guest with qemu.

3. Attest the SNP guest using the [virtee/snpguest](https://github.com/virtee/snpguest) 
CLI tool.

Tested on the following OS distributions:
- Ubuntu 20.04
- Ubuntu 22.04

Image formats supported:
- qcow2

WARNING: 
This script installs developer packages on the system it is run on. 
Beware and check 'install_dependencies' if there are any admin concerns.

WARNING: 
This script sets the default grub entry to the SNP kernel version that is 
built for the host in this script. Modifying the system grub can cause 
booting issues.

## Enable Host SNP Options in the System BIOS

These options will differ depending on the server manufacturer and BIOS version. 
The following steps show an example of the necessary changes required for a CRB 
system BIOS:
```
CBS -> CPU Common ->
            SEV-ES ASID Space Limit -> 100
            SNP Memory Coverage -> Enabled 
            SMEE -> Enabled
    -> NBIO Common ->
            SEV-SNP -> Enabled
```

For more information, see the 'Enabling/Disabling SNP' section of the following document:

[58207-using-sev-with-amd-epyc-processors.pdf](https://www.amd.com/content/dam/amd/en/documents/developer/58207-using-sev-with-amd-epyc-processors.pdf)

## Using the Script Utility

Download the script and add the execute permission:
```
wget https://github.com/amd/sev-utils/raw/main/tools/snp.sh
chmod +x snp.sh
```

Setup the host by building SNP patched versions of qemu, ovmf and the linux kernel:
```
./snp.sh setup-host
```

The `--svsm` option can be specified with the above command to set-up the host for SVSM. 
This will build a Coconut-SVSM kernel as well as the IGVM, SVSM, OVMF and QEMU launch dependencies.

The `--non-upm` option can be specified with the above command if a non-upm version 
of the kernel is desired.

The above step will also change the default grub entry to the newly installed 
host kernel.

A reboot will be necessary:
```
sudo reboot
```

When the system has finished rebooting back into the OS, launch a guest using 
the following command:
```
./snp.sh launch-guest
```

The `--svsm` option can be specified in the above command to launch a Coconut-SVSM guest. 
The `setup-host` command must be run with this same option in order to have the necessary dependencies to launch an SVSM guest.

This will download a cloud-init ubuntu server jammy image that will be used as the 
guest disk. The guest is launched by passing qemu direct boot command line options 
for ovmf, initrd, kernel and the kernel append parameters.

The `--non-upm` option can be specified with the above command if a non-upm version 
of the kernel is desired. The `setup-host` command must be run with this same option 
if launching the guest with a non-upm kernel.

Attest the guest using the following command:
```
./snp.sh attest-guest
```

Use the `--svsm` option in the above command to attest a Coconut-SVSM guest.

The above result will show the contents of the SNP report and perform the 
report signature and certificate CA verification. It uses the IBM 
[sev-snp-measure](https://github.com/IBM/sev-snp-measure) tool to calculate the 
expected launch measurement by measuring the ovmf, initrd, kernel, kernel append 
parameters, and additional qemu command line parameters. This expected measurement 
is then checked and verified against the launch measurement that is output from the 
[virtee/snpguest](https://github.com/virtee/snpguest) tool. If the two measurements 
match, then the test returns with a successful output.

In the case of Coconut-SVSM attestation, the [igvmmeasure](https://github.com/coconut-svsm/svsm/tree/main/igvmmeasure)
tool is used, which will only measure the IGVM file used to launch the guest. This expected measurement should match with the measurement on the attestation report of the SVSM guest.

## Stopping all Guests

All script created guests can be stopped by running the following command:
```
./snp.sh stop-guests
```

## BYO Image

The SNP script utility provides support for the user to provide their own image.

This image has the following requirements:
- debian/ubuntu based
- SSH must be installed
- The GUEST_USER must already be added
- The SSH public key must already be injected for the specified user
- There must be enough space for the kernel installation

Export the following environment variables:
```
export IMAGE="guest.img"
export GUEST_USER="user"
export GUEST_SSH_KEY_PATH="guest-key"
```

IMAGE is the path to the user supplied guest image.
GUEST_USER is the user required to access the guest.
GUEST_SSH_KEY_PATH is the path to the SSH private key.

Launch the guest:
```
./snp.sh launch-guest
```

## Accessing the Guest via SSH

Once launched, the guest can be accessed with the following SSH command:
```
ssh -p 10022 -i snp-guest-key amd@localhost
```

'10022' is the default qemu mapped port for network access. This can be changed 
by exporting HOST_SSH_PORT.

'snp-guest-key' is the path to the SSH private key.

'amd' is the default user to access the guest. This can be changed by exporting 
GUEST_USER.
