function Invoke-RefreshLab {
    <#
    .SYNOPSIS
        Restore all lab VMs from a snapshot.
    .DESCRIPTION
        The VMware equivalent of the original Refresh-Lab. Gracefully shuts
        down the lab VMs and then reverts each one to the named snapshot with
        'vmrun revertToSnapshot'. The default snapshot name is LabConfigured,
        matching Snapshot-Lab's default. VMs are left powered off after the
        revert (same as the Hyper-V version); use Run-Lab to start them.
    .PARAMETER Path
        The path to the configuration folder. Default is the current location.
    .PARAMETER SnapshotName
        Name of the snapshot to restore. Default LabConfigured.
    .PARAMETER NoMessages
        Run the command but suppress all status messages.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Refresh-Lab
        Reverts all MultiRole VMs to the 'LabConfigured' snapshot.
    .LINK
        Invoke-SnapshotLab
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Alias('Refresh-Lab')]
    param(
        [Parameter(HelpMessage = 'The path to the configuration folder. Normally, you should run all commands from within the configuration folder.')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path = '.',

        [Parameter(HelpMessage = 'Specify the name of the snapshot to restore.')]
        [ValidateNotNullOrEmpty()]
        [string]$SnapshotName = 'LabConfigured',

        [Parameter(HelpMessage = 'Run the command but suppress all status messages.')]
        [Alias('Quiet')]
        [switch]$NoMessages
    )

    Write-Verbose "Starting $($MyInvocation.MyCommand)"
    $lab = Import-LabConfiguration -Path $Path

    Write-LabMessage -Message 'Stopping the lab before restoring snapshots' -Quiet:$NoMessages
    Invoke-ShutdownLab -Path $Path -NoMessages

    foreach ($node in $lab.Nodes) {
        $vmx = Get-LabVMXPath -Node $node
        if (-not (Test-Path -Path $vmx)) {
            Write-Warning "VM $($node.VMName) has not been created; skipping."
            continue
        }

        # verify the snapshot exists
        $snapshots = @(Invoke-VMRun -Command listSnapshots -Arguments $vmx -IgnoreErrors)
        if ($snapshots -notcontains $SnapshotName) {
            Write-Warning "VM $($node.VMName) has no snapshot named '$SnapshotName'. Available: $(($snapshots | Where-Object { $_ -notmatch 'Total snapshots' }) -join ', ')"
            continue
        }

        if ($PSCmdlet.ShouldProcess($node.VMName, "vmrun revertToSnapshot '$SnapshotName'")) {
            Write-LabMessage -Message "Reverting $($node.VMName) to '$SnapshotName'" -Quiet:$NoMessages
            try {
                [void](Invoke-VMRun -Command revertToSnapshot -Arguments $vmx, $SnapshotName)
            }
            catch {
                Write-Warning "Failed to revert $($node.VMName): $($_.Exception.Message)"
            }
        }
    }

    if (-not $NoMessages) {
        Microsoft.PowerShell.Utility\Write-Host -ForegroundColor Green -Object @"

    Refresh complete. The VMs are powered off. Next Steps:

    To start the lab:
    Run-Lab

    To stop the lab VMs:
    Shutdown-Lab

    To destroy the lab:
    Wipe-Lab

"@
    }
    Write-Verbose "Ending $($MyInvocation.MyCommand)"
}
