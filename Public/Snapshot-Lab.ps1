function Invoke-SnapshotLab {
    <#
    .SYNOPSIS
        Create a snapshot of every lab VM.
    .DESCRIPTION
        The VMware equivalent of the original Snapshot-Lab. Gracefully shuts
        down all lab VMs (so the snapshot is consistent, matching the
        original's Stop-Lab-then-Checkpoint-Lab behavior) and then takes a
        snapshot of each VM with 'vmrun snapshot'. The default snapshot name
        is LabConfigured, the same default as the Hyper-V module.
    .PARAMETER Path
        The path to the configuration folder. Default is the current location.
    .PARAMETER SnapshotName
        Name of the snapshot to create. Default LabConfigured.
    .PARAMETER NoMessages
        Run the command but suppress all status messages.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Snapshot-Lab
        Snapshots all MultiRole VMs as 'LabConfigured'.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Snapshot-Lab -SnapshotName BeforeExercise2
    .LINK
        Invoke-RefreshLab
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Alias('Snapshot-Lab')]
    param(
        [Parameter(HelpMessage = 'The path to the configuration folder. Normally, you should run all commands from within the configuration folder.')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path = '.',

        [Parameter(HelpMessage = 'Specify a name for the snapshot.')]
        [ValidateNotNullOrEmpty()]
        [string]$SnapshotName = 'LabConfigured',

        [Parameter(HelpMessage = 'Run the command but suppress all status messages.')]
        [Alias('Quiet')]
        [switch]$NoMessages
    )

    Write-Verbose "Starting $($MyInvocation.MyCommand)"
    $lab = Import-LabConfiguration -Path $Path

    Write-LabMessage -Message "Stopping the lab before snapshotting (for a consistent state)" -Quiet:$NoMessages
    Invoke-ShutdownLab -Path $Path -NoMessages

    foreach ($node in $lab.Nodes) {
        $vmx = Get-LabVMXPath -Node $node
        if (-not (Test-Path -Path $vmx)) {
            Write-Warning "VM $($node.VMName) has not been created; skipping."
            continue
        }
        if ($PSCmdlet.ShouldProcess($node.VMName, "vmrun snapshot '$SnapshotName'")) {
            Write-LabMessage -Message "Snapshotting $($node.VMName) as '$SnapshotName'" -Quiet:$NoMessages
            try {
                [void](Invoke-VMRun -Command snapshot -Arguments $vmx, $SnapshotName)
            }
            catch {
                Write-Warning "Failed to snapshot $($node.VMName): $($_.Exception.Message)"
            }
        }
    }

    if (-not $NoMessages) {
        Microsoft.PowerShell.Utility\Write-Host -ForegroundColor Green -Object @"

    Snapshots complete. Next Steps:

    To start the lab again:
    Run-Lab

    To restore the lab to this snapshot later:
    Refresh-Lab -SnapshotName $SnapshotName

"@
    }
    Write-Verbose "Ending $($MyInvocation.MyCommand)"
}
