function Invoke-WipeLab {
    <#
    .SYNOPSIS
        Destroy the lab VMs and all of their files.
    .DESCRIPTION
        The VMware equivalent of the original Wipe-Lab:

          * Powers off every lab VM (hard stop via vmrun)
          * Deletes each VM with 'vmrun deleteVM' (removes vmx, vmdk, nvram,
            snapshots) and removes the per-VM folder
          * Deletes the generated .mof files in the configuration folder and
            the per-node autounattend ISOs
          * With -RemoveSwitch, also removes the WinNAT rule (IPNatName) and
            the gateway IP from the host's VMnet adapter

        Downloaded Windows evaluation ISOs are always retained so the lab can
        be rebuilt without re-downloading, matching the original behavior.
    .PARAMETER Path
        The path to the configuration folder. Default is the current location.
    .PARAMETER RemoveSwitch
        Also remove the host NAT rule and the lab gateway IP from the VMnet
        host adapter.
    .PARAMETER Force
        Do not prompt for confirmation.
    .PARAMETER NoMessages
        Run the command but suppress all status messages.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Wipe-Lab
        Removes the MultiRole lab after prompting.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Wipe-Lab -Force -RemoveSwitch
        Removes everything including host networking artifacts without prompting.
    .LINK
        Invoke-SetupLab
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Alias('Wipe-Lab')]
    param(
        [Parameter(HelpMessage = 'The path to the configuration folder. Normally, you should run all commands from within the configuration folder.')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path = '.',

        [Parameter(HelpMessage = 'Also remove the host NAT rule and gateway IP.')]
        [switch]$RemoveSwitch,

        [Parameter(HelpMessage = 'Do not prompt for confirmation.')]
        [switch]$Force,

        [Parameter(HelpMessage = 'Run the command but suppress all status messages.')]
        [Alias('Quiet')]
        [switch]$NoMessages
    )

    Write-Verbose "Starting $($MyInvocation.MyCommand)"
    $lab = Import-LabConfiguration -Path $Path

    if (-not $Force) {
        $answer = Read-Host "This will destroy the VMs and files for the '$($lab.Name)' lab: $($lab.Nodes.VMName -join ', '). Continue? (y/n)"
        if ($answer -notmatch '^y') {
            Write-LabMessage -Message 'Wipe-Lab canceled.' -Color Yellow -Quiet:$NoMessages
            return
        }
    }

    Write-LabMessage -Message "Wiping the lab environment for $($lab.Name)" -Color Green -Quiet:$NoMessages

    foreach ($node in $lab.Nodes) {
        $vmx = Get-LabVMXPath -Node $node
        $vmFolder = Get-LabVMFolder -Node $node

        if (Test-Path -Path $vmx) {
            # power off (hard - we are deleting anyway)
            if ((Get-LabVMState -Node $node) -eq 'Running') {
                Write-LabMessage -Message "Powering off $($node.VMName)" -Quiet:$NoMessages
                if ($PSCmdlet.ShouldProcess($node.VMName, 'vmrun stop hard')) {
                    [void](Invoke-VMRun -Command stop -Arguments $vmx, 'hard' -IgnoreErrors)
                }
            }
            # delete VM (removes disks/snapshots registered to it)
            Write-LabMessage -Message "Deleting VM $($node.VMName)" -Quiet:$NoMessages
            if ($PSCmdlet.ShouldProcess($node.VMName, 'vmrun deleteVM')) {
                [void](Invoke-VMRun -Command deleteVM -Arguments $vmx -IgnoreErrors)
            }
        }

        # remove any leftover files/folder
        if (Test-Path -Path $vmFolder) {
            if ($PSCmdlet.ShouldProcess($vmFolder, 'Remove VM folder')) {
                Remove-Item -Path $vmFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # remove the node's autounattend ISO
        $unattendIso = Join-Path -Path $script:AutoLabFolders.UnattendIsoPath -ChildPath "$($node.VMName)-unattend.iso"
        if (Test-Path -Path $unattendIso) {
            Remove-Item -Path $unattendIso -Force -ErrorAction SilentlyContinue
        }
    }

    # remove generated MOFs
    Write-LabMessage -Message 'Removing generated .mof files' -Quiet:$NoMessages
    if ($PSCmdlet.ShouldProcess($lab.Path, 'Remove *.mof')) {
        Get-ChildItem -Path $lab.Path -Filter *.mof -ErrorAction SilentlyContinue | Remove-Item -Force
    }

    # optionally remove host networking artifacts
    if ($RemoveSwitch) {
        $natName = $lab.IPNatName
        if (-not $natName) { $natName = 'LabNat' }
        Write-LabMessage -Message "Removing NAT rule '$natName'" -Quiet:$NoMessages
        if ($PSCmdlet.ShouldProcess($natName, 'Remove-NetNat')) {
            Get-NetNat -Name $natName -ErrorAction SilentlyContinue | Remove-NetNat -Confirm:$false -ErrorAction SilentlyContinue
        }

        $vmnetNumber = $script:LabVMnet -replace '\D', ''
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceDescription -match "VMnet$vmnetNumber$" -or $_.Name -match "VMnet$vmnetNumber$" } |
            Select-Object -First 1
        if ($adapter) {
            $gateway = ($lab.Nodes | Select-Object -First 1).DefaultGateway
            if ($PSCmdlet.ShouldProcess($adapter.Name, "Remove $gateway")) {
                Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -eq $gateway } |
                    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $NoMessages) {
        Microsoft.PowerShell.Utility\Write-Host -ForegroundColor Green -Object @"

    The lab has been wiped. Downloaded evaluation ISOs were retained in
    $($script:AutoLabFolders.IsoPath) so the lab can be rebuilt quickly with:
    Setup-Lab

"@
    }
    Write-Verbose "Ending $($MyInvocation.MyCommand)"
}
