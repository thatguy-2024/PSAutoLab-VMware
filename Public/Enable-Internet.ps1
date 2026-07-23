function Enable-Internet {
    <#
    .SYNOPSIS
        Enable Internet access for the lab VMs through the host.
    .DESCRIPTION
        The VMware equivalent of the original Enable-Internet. The lab VMs sit
        on a host-only vmnet with the host adapter at 192.168.3.1 (their
        configured default gateway). This command creates a Windows NAT
        (WinNAT) rule on the host so traffic from the lab subnet is translated
        out of the host's Internet connection:

          * Ensures the host VMnet adapter carries the gateway IP
            (DefaultGateway from the configuration data, normally 192.168.3.1)
          * Creates a NetNat rule named from IPNatName (normally LabNat) for
            the IPNetwork prefix (normally 192.168.3.0/24)

        Values are read from the configuration data, so the SAME psd1 files
        work unchanged. Requires an elevated session.
    .PARAMETER Path
        The path to the configuration folder. Default is the current location.
    .PARAMETER NoMessages
        Run the command but suppress all status messages.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Enable-Internet
    .LINK
        Invoke-RunLab
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(HelpMessage = 'The path to the configuration folder. Normally, you should run all commands from within the configuration folder.')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path = '.',

        [Parameter(HelpMessage = 'Run the command but suppress all status messages.')]
        [Alias('Quiet')]
        [switch]$NoMessages
    )

    Write-Verbose "Starting $($MyInvocation.MyCommand)"

    if (-not (Test-IsAdministrator)) {
        throw 'Enable-Internet must be run from an elevated PowerShell session.'
    }

    $lab = Import-LabConfiguration -Path $Path

    $gateway = ($lab.Nodes | Select-Object -First 1).DefaultGateway
    if (-not $gateway) { $gateway = $script:LabVMnetHostIP }
    $ipNetwork = $lab.IPNetwork
    if (-not $ipNetwork) { $ipNetwork = "$script:LabVMnetSubnet/24" }
    $natName = $lab.IPNatName
    if (-not $natName) { $natName = 'LabNat' }
    $prefixLength = [int]($ipNetwork.Split('/')[1])

    Write-LabMessage -Message "Configuring NAT '$natName' for $ipNetwork (gateway $gateway)" -Quiet:$NoMessages

    # 1) host VMnet adapter must own the gateway IP
    $vmnetNumber = $script:LabVMnet -replace '\D', ''
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match "VMnet$vmnetNumber$" -or $_.Name -match "VMnet$vmnetNumber$" } |
        Select-Object -First 1
    if (-not $adapter) {
        throw "Host adapter for $script:LabVMnet not found. Run Setup-Host (or configure the vmnet in the Virtual Network Editor) first."
    }

    $hasIP = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $gateway }
    if (-not $hasIP) {
        if ($PSCmdlet.ShouldProcess($adapter.Name, "Assign $gateway/$prefixLength")) {
            [void](New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $gateway -PrefixLength $prefixLength -ErrorAction Stop)
        }
    }
    else {
        Write-Verbose "Adapter $($adapter.Name) already has $gateway"
    }

    # 2) WinNAT rule (same mechanism as the Hyper-V original)
    $existingNat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
    if ($existingNat) {
        Write-LabMessage -Message "NAT rule '$natName' already exists. No changes needed." -Color Green -Quiet:$NoMessages
    }
    elseif ($PSCmdlet.ShouldProcess($natName, "New-NetNat for $ipNetwork")) {
        try {
            [void](New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $ipNetwork -ErrorAction Stop)
        }
        catch {
            throw "Failed to create NAT rule '$natName': $($_.Exception.Message). If another NAT already covers this prefix, remove it with Remove-NetNat, or switch the lab vmnet to VMware NAT mode (vmnet8) instead."
        }
    }

    if (-not $NoMessages) {
        Microsoft.PowerShell.Utility\Write-Host -ForegroundColor Green -Object @"

    Internet access has been enabled for the lab subnet $ipNetwork.

    Next Steps:

    Run the following to validate when configurations have converged:
    Validate-Lab

    To stop the lab VMs:
    Shutdown-Lab

"@
    }
    Write-Verbose "Ending $($MyInvocation.MyCommand)"
}
