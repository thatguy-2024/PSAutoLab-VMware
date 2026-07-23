# NetworkHelper.ps1
# VMware virtual network management for the lab. The Hyper-V 'LabNet' internal
# switch becomes a VMware host-only network (default vmnet2) on 192.168.3.0/24
# with the host adapter at 192.168.3.1 - the same addresses the original
# configurations expect. Internet access is provided with Windows NAT (WinNAT)
# on the host, exactly like the original Enable-Internet. Not exported.

function Set-LabVMnet {
    <#
    .SYNOPSIS
        Create/configure the host-only lab vmnet (LabNet equivalent).
    .DESCRIPTION
        Uses vnetlib64.exe to add a host-only virtual network (default vmnet2),
        assign the 192.168.3.0/255.255.255.0 subnet, disable the VMware DHCP
        service on it (labs use static IPs / their own DHCP role) and create the
        host virtual adapter. The host adapter is then given the gateway address
        192.168.3.1. Requires elevation.
    .PARAMETER VMnet
        The vmnet name. Default is the module setting (vmnet2).
    .PARAMETER Subnet
        Network address. Default 192.168.3.0.
    .PARAMETER Mask
        Subnet mask. Default 255.255.255.0.
    .PARAMETER HostIP
        Host adapter IP (lab gateway). Default 192.168.3.1.
    .EXAMPLE
        PS C:\> Set-LabVMnet
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$VMnet = $script:LabVMnet,
        [string]$Subnet = $script:LabVMnetSubnet,
        [string]$Mask = $script:LabVMnetMask,
        [string]$HostIP = $script:LabVMnetHostIP
    )

    if (-not (Test-IsAdministrator)) {
        throw 'Configuring VMware virtual networks requires an elevated PowerShell session.'
    }

    $vmware = Get-VMwarePath
    if (-not (Test-Path -Path $vmware.VNetLib)) {
        Write-Warning "vnetlib64.exe not found. Configure $VMnet manually in the Virtual Network Editor: host-only, subnet $Subnet/$Mask, DHCP disabled."
        return
    }

    $vmnetNumber = $VMnet -replace '\D', ''

    if ($PSCmdlet.ShouldProcess($VMnet, "Configure host-only network $Subnet/$Mask")) {
        # vnetlib64 -- <command> syntax; each call is idempotent enough to re-run
        $commands = @(
            "add adapter $VMnet",
            "set vnet $VMnet addr $Subnet",
            "set vnet $VMnet mask $Mask",
            "remove adapter $VMnet dhcp",       # no VMware DHCP - labs use static IPs
            "update adapter $VMnet",
            "start dhcp",                        # restart services so settings apply
            "stop dhcp"
        )
        foreach ($cmd in $commands) {
            Write-Verbose "vnetlib64 -- $cmd"
            $null = & $vmware.VNetLib '--' $cmd.Split(' ') 2>&1
        }
        # nat/dhcp service refresh
        $null = & $vmware.VNetLib '--' 'stop', 'nat' 2>&1
        $null = & $vmware.VNetLib '--' 'start', 'nat' 2>&1
    }

    # Give the host's VMnet adapter the lab gateway address
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match "VMnet$vmnetNumber$" -or $_.Name -match "VMnet$vmnetNumber$" } |
        Select-Object -First 1

    if ($adapter) {
        $prefix = ConvertTo-PrefixLength -Mask $Mask
        $existing = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $HostIP }
        if (-not $existing) {
            if ($PSCmdlet.ShouldProcess($adapter.Name, "Assign $HostIP/$prefix")) {
                Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                [void](New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $HostIP -PrefixLength $prefix -ErrorAction Stop)
            }
        }
        # make the lab network Private so WinRM from the host works
        Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue |
            Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
    }
    else {
        Write-Warning "Host adapter 'VMware Network Adapter VMnet$vmnetNumber' not found yet. If you just created the vmnet, reboot or open the Virtual Network Editor and apply, then re-run Setup-Host."
    }
}

function ConvertTo-PrefixLength {
    <#
    .SYNOPSIS
        Convert a dotted subnet mask (or prefix number) to a prefix length.
    .PARAMETER Mask
        e.g. 255.255.255.0 or 24.
    .EXAMPLE
        PS C:\> ConvertTo-PrefixLength -Mask 255.255.255.0
        24
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Mask
    )
    if ($Mask -match '^\d{1,2}$') { return [int]$Mask }
    $bits = ($Mask.Split('.') | ForEach-Object { [Convert]::ToString([int]$_, 2) }) -join ''
    ($bits.ToCharArray() | Where-Object { $_ -eq '1' }).Count
}

function Test-LabVMnet {
    <#
    .SYNOPSIS
        Test whether the lab vmnet host adapter is present with the gateway IP.
    .EXAMPLE
        PS C:\> Test-LabVMnet
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $vmnetNumber = $script:LabVMnet -replace '\D', ''
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match "VMnet$vmnetNumber$" -or $_.Name -match "VMnet$vmnetNumber$" } |
        Select-Object -First 1
    if (-not $adapter) { return $false }

    $ip = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $script:LabVMnetHostIP }
    [bool]$ip
}
