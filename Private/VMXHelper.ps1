# VMXHelper.ps1
# Generates VMware Workstation Pro .vmx configuration files for lab nodes.
# VMX files are plain-text key = "value" files - this is the most reliable way
# to create VMs on Workstation (vmcli is still v0.1 quality). Not exported.

function New-LabVMX {
    <#
    .SYNOPSIS
        Generate a .vmx file for a lab node.
    .DESCRIPTION
        Writes a complete VMware Workstation Pro VMX configuration for the node:
        EFI firmware (Secure Boot disabled, matching the original module's
        Set-VMFirmware -EnableSecureBoot Off behavior), hardware version 21
        (Workstation Pro 17.5+), NVMe system disk, two SATA CD-ROM drives
        (install ISO + autounattend ISO), a custom vmnet host-only NIC and
        vTPM-less Windows 11 support (the eval unattend bypasses TPM checks).
    .PARAMETER Node
        A node object produced by Import-LabConfiguration.
    .PARAMETER InstallISO
        Full path of the Windows installation ISO to attach.
    .PARAMETER UnattendISO
        Full path of the generated autounattend/bootstrap ISO to attach.
    .PARAMETER HardwareVersion
        virtualHW.version to write. Default 21 (Workstation Pro 17.5+). Use 20
        for 17.0/17.1 hosts.
    .EXAMPLE
        PS C:\> New-LabVMX -Node $node -InstallISO C:\AutolabVMware\ISOs\server2022.iso -UnattendISO C:\AutolabVMware\UnattendISOs\DC1-unattend.iso
    .OUTPUTS
        String. The path of the created .vmx file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Node,

        [Parameter(Mandatory)]
        [string]$InstallISO,

        [Parameter(Mandatory)]
        [string]$UnattendISO,

        [ValidateRange(14, 22)]
        [int]$HardwareVersion = 21
    )

    $vmFolder = Get-LabVMFolder -Node $Node -Create
    $vmxPath = Get-LabVMXPath -Node $Node
    $vmdkName = "$($Node.VMName).vmdk"
    $guestOS = ConvertTo-VMwareGuestOS -MediaId $Node.Media

    # Custom vmnet host-only network for the lab (LabNet equivalent).
    # Windows hosts name networks "VMnet<N>" (capital VM) - normalize the casing,
    # a lowercase "vmnet2" in ethernet0.vnet fails to resolve and the VM cannot
    # power on (vmrun reports only "Unknown error").
    $vmnet = $Node.VMnet -replace '^(?i)vmnet', 'VMnet'

    $vmx = @"
.encoding = "windows-1252"
config.version = "8"
virtualHW.version = "$HardwareVersion"
displayName = "$($Node.VMName)"
guestOS = "$guestOS"
annotation = "PSAutoLabVMware|Lab=$($Node.Lab)|Computername=$($Node.Computername)|Media=$($Node.Media)"

# Firmware: EFI with Secure Boot disabled (matches PSAutoLab Set-VMFirmware behavior)
firmware = "efi"
uefi.secureBoot.enabled = "FALSE"

# CPU / memory (from Lability_ProcessorCount / MemoryStartupBytes|Lability_MinimumMemory)
numvcpus = "$($Node.Processors)"
cpuid.coresPerSocket = "1"
memsize = "$($Node.MemoryMB)"
mem.hotadd = "TRUE"
vcpu.hotadd = "TRUE"

# Virtualization engine
vhv.enable = "FALSE"
hypervisor.cpuid.v0 = "TRUE"

# System disk (NVMe)
nvme0.present = "TRUE"
nvme0:0.present = "TRUE"
nvme0:0.fileName = "$vmdkName"
nvme0:0.deviceType = "disk"

# CD-ROM 1: Windows installation ISO
sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.deviceType = "cdrom-image"
sata0:0.fileName = "$InstallISO"
sata0:0.startConnected = "TRUE"

# CD-ROM 2: autounattend.xml + DSC bootstrap ISO
sata0:1.present = "TRUE"
sata0:1.deviceType = "cdrom-image"
sata0:1.fileName = "$UnattendISO"
sata0:1.startConnected = "TRUE"

# Network: host-only lab vmnet (Lability_SwitchName 'LabNet' -> $vmnet)
ethernet0.present = "TRUE"
ethernet0.connectionType = "custom"
ethernet0.vnet = "$vmnet"
ethernet0.virtualDev = "e1000e"
ethernet0.addressType = "generated"
ethernet0.startConnected = "TRUE"

# Boot: boot from CD-ROM first on the initial run
bios.bootOrder = "cdrom,hdd"
bios.bootDelay = "2000"

# Peripherals
usb.present = "TRUE"
usb_xhci.present = "TRUE"
ehci.present = "TRUE"
sound.present = "FALSE"
serial0.present = "FALSE"
floppy0.present = "FALSE"

# Misc
tools.syncTime = "TRUE"
tools.upgrade.policy = "upgradeAtPowerCycle"
powerType.powerOff = "soft"
powerType.powerOn = "soft"
powerType.suspend = "soft"
powerType.reset = "soft"
msg.autoAnswer = "TRUE"
mks.enable3d = "FALSE"
cleanShutdown = "TRUE"
"@

    if ($PSCmdlet.ShouldProcess($vmxPath, 'Create VMX file')) {
        Set-Content -Path $vmxPath -Value $vmx -Encoding Ascii -Force
        Write-Verbose "Created VMX: $vmxPath"
    }
    $vmxPath
}

function ConvertTo-VMwareGuestOS {
    <#
    .SYNOPSIS
        Map a Lability media ID to a VMware guestOS identifier.
    .DESCRIPTION
        Uses the module media map (MediaHelper.ps1) to translate media IDs such
        as 2022_x64_Standard_EN_Core_Eval to VMware Workstation guestOS values
        such as windows2019srvnext-64.
    .PARAMETER MediaId
        The Lability media ID.
    .EXAMPLE
        PS C:\> ConvertTo-VMwareGuestOS -MediaId WIN11_x64_Enterprise_23H2_EN_Eval
        windows11-64
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$MediaId
    )
    (Get-LabMediaInfo -Id $MediaId).GuestOS
}

function Set-LabVMXBootOrder {
    <#
    .SYNOPSIS
        Switch a VM's boot order to hard disk first (post-install).
    .DESCRIPTION
        After Windows setup has completed, rewrites bios.bootOrder in the .vmx
        file so subsequent boots come from the installed disk rather than the
        install ISO, and disconnects the CD-ROM images.
    .PARAMETER VMXPath
        Path to the .vmx file.
    .PARAMETER DisconnectISO
        Also mark both CD-ROM drives as not connected at power on.
    .EXAMPLE
        PS C:\> Set-LabVMXBootOrder -VMXPath $vmx -DisconnectISO
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ })]
        [string]$VMXPath,

        [switch]$DisconnectISO
    )

    $content = Get-Content -Path $VMXPath
    $content = $content -replace '^bios\.bootOrder\s*=.*$', 'bios.bootOrder = "hdd,cdrom"'
    if ($DisconnectISO) {
        $content = $content -replace '^sata0:0\.startConnected\s*=.*$', 'sata0:0.startConnected = "FALSE"'
        $content = $content -replace '^sata0:1\.startConnected\s*=.*$', 'sata0:1.startConnected = "FALSE"'
    }
    if ($PSCmdlet.ShouldProcess($VMXPath, 'Update boot order')) {
        Set-Content -Path $VMXPath -Value $content -Encoding Ascii
    }
}

function Get-LabVMState {
    <#
    .SYNOPSIS
        Return the power state of a lab VM.
    .DESCRIPTION
        Compares the node's .vmx path against 'vmrun list' output. Returns
        'Running', 'Off' or 'NotCreated'.
    .PARAMETER Node
        A node object produced by Import-LabConfiguration.
    .EXAMPLE
        PS C:\> Get-LabVMState -Node $node
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Node
    )

    $vmx = Get-LabVMXPath -Node $Node
    if (-not (Test-Path -Path $vmx)) { return 'NotCreated' }
    $running = Get-RunningVMX
    if ($running -contains $vmx) { 'Running' } else { 'Off' }
}
