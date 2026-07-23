# VMDKHelper.ps1
# Creates VMware virtual disks (VMDK) with vmware-vdiskmanager.exe. Replaces
# Lability's master/differencing VHDX pipeline: each VM gets its own growable
# sparse VMDK and Windows is installed from ISO instead of image-applied.
# Not exported.

function New-LabVMDK {
    <#
    .SYNOPSIS
        Create a virtual disk for a lab node using vmware-vdiskmanager.
    .DESCRIPTION
        Creates a growable (thin-provisioned), single-file VMDK (-t 0) with an
        lsilogic adapter. The default size of 127GB matches Lability's default
        VHDX size, so guests see the same disk layout as the Hyper-V labs.
        Existing disks are left untouched unless -Force is used.
    .PARAMETER Node
        A node object produced by Import-LabConfiguration.
    .PARAMETER SizeGB
        Disk size in GB. Default 127 (Lability default media disk size).
    .PARAMETER Force
        Recreate the disk if it already exists (destroys existing data).
    .EXAMPLE
        PS C:\> New-LabVMDK -Node $node
    .OUTPUTS
        String. The path of the VMDK file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Node,

        [ValidateRange(20, 2048)]
        [int]$SizeGB = 127,

        [switch]$Force
    )

    $vmFolder = Get-LabVMFolder -Node $Node -Create
    $vmdkPath = Join-Path -Path $vmFolder -ChildPath "$($Node.VMName).vmdk"

    if (Test-Path -Path $vmdkPath) {
        if ($Force) {
            if ($PSCmdlet.ShouldProcess($vmdkPath, 'Delete existing VMDK')) {
                Remove-LabVMDK -Path $vmdkPath
            }
        }
        else {
            Write-Verbose "VMDK already exists: $vmdkPath"
            return $vmdkPath
        }
    }

    $vmware = Get-VMwarePath
    if ($PSCmdlet.ShouldProcess($vmdkPath, "Create ${SizeGB}GB VMDK")) {
        # -c create, -s size, -a adapter type, -t 0 growable single file
        $output = & $vmware.VDiskManager -c -s "${SizeGB}GB" -a lsilogic -t 0 $vmdkPath 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -Path $vmdkPath)) {
            throw "vmware-vdiskmanager failed to create $vmdkPath : $($output -join '; ')"
        }
        Write-Verbose "Created VMDK: $vmdkPath"
    }
    $vmdkPath
}

function Remove-LabVMDK {
    <#
    .SYNOPSIS
        Delete a VMDK using vmware-vdiskmanager (falls back to file deletion).
    .DESCRIPTION
        Uses 'vmware-vdiskmanager -U' to properly delete all extents of the
        disk. If the tool fails (e.g. disk descriptor damaged), removes the
        matching files directly.
    .PARAMETER Path
        Path of the .vmdk descriptor file.
    .EXAMPLE
        PS C:\> Remove-LabVMDK -Path C:\AutolabVMware\VMs\DC1\DC1.vmdk
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) { return }

    if ($PSCmdlet.ShouldProcess($Path, 'Delete VMDK')) {
        try {
            $vmware = Get-VMwarePath
            [void](& $vmware.VDiskManager -U $Path 2>&1)
        }
        catch {
            Write-Verbose "vmware-vdiskmanager -U failed, deleting files directly: $($_.Exception.Message)"
        }
        # remove any leftover extent files (name.vmdk, name-s001.vmdk, ...)
        $base = [IO.Path]::GetFileNameWithoutExtension($Path)
        $dir = Split-Path -Path $Path -Parent
        Get-ChildItem -Path $dir -Filter "$base*.vmdk" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
