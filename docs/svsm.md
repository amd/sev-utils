# SVSM  Utility Script (Launch_SVSM.sh)

This 'Launch_SVSM.sh'  utility script is a provisioning and test script that performs three tasks:

1. Sets up an AMD EPYC CPU powered server by building host kernel, guest kernel, IGVM,  qemu, ovmf builds

2. Direct boot launch a SNP enabled guest with qemu using IGVM file

3. Attest the SNP guest using the [virtee/snpguest](https://github.com/virtee/snpguest) 
CLI tool.

4. Verify measurement - igvmmeasure tool and snp attestation report

Tested on the following OS distributions:
- Ubuntu 24.04


Image formats supported:
- qcow2

WARNING: 
This script installs developer packages on the system it is run on. 
Beware and check 'install_dependencies' if there are any admin concerns.



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

Download the script:
```
git clone https://github.com/AMDEPYC/Coconut-SVSM.git

```

Setup the host by building SVSM  patched versions of IGVM, qemu, ovmf and the host and guest linux kernels:
```
./Launch_SVSM.sh setup-host
```


A reboot will be necessary with SVSM enabled host kernel:
```
sudo reboot
```

When the system has finished rebooting back into the OS, launch a guest using 
the following command:
```
./Launch_SVSM.sh launch-guest
```

This will download a cloud-init ubuntu server jammy image that will be used as the 
guest disk. The guest is launched by passing qemu direct boot command line options 
for IGVM, initrd, kernel and the kernel append parameters.


Attest the guest using the following command:
```
./Launch_SVSM.sh attest-guest
```

The above result will show the contents of the SNP report and perform the 
report signature and certificate CA verification. It uses the igvmmeasure tool 
output from SVSM build to calculate the 
expected launch measurement by measuring the IGVM file(SVSM,ovmf). This expected measurement 
is then checked and verified against the launch measurement that is output from the 
[virtee/snpguest](https://github.com/virtee/snpguest) tool. If the two measurements 
match, then the test returns with a successful output.

## Stopping all Guests

All script created guests can be stopped by running the following command:
```
./Launch_SVSM.sh stop-guests
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
./Launch_SVSM.sh launch-guest
```

## Accessing the Guest via SSH

Once launched, the guest can be accessed with the following SSH command:
```
ssh -p <10022> -i <snp-guest-key> amd@localhost
```

'10022' is the default qemu mapped port for network access. This can be changed 
by exporting HOST_SSH_PORT.

'snp-guest-key' is the path to the SSH private key.

'amd' is the default user to access the guest. This can be changed by exporting 
GUEST_USER.
