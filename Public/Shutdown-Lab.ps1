function Invoke-ShutdownLab {
    <#
    .SYNOPSIS
        Gracefully shut down all lab VMs.
    .DESCRIPTION
        The VMware equivalent of the original Shutdown-Lab. Shuts down every
        VM in the configuration with 'vmrun stop <vmx> soft' (a guest-OS
        initiated shutdown via VMware Tools), in reverse boot order - the DC
        goes down last, exactly like Lability's Stop-Lab. If a soft stop fails
        (e.g. VMware Tools not yet installed), the VM is powered off hard.
    .PARAMETER Path
        The path to the configuration folder. Default is the current location.
    .PARAMETER NoMessages
        Run the command but suppress all status messages.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Shutdown-Lab
    .LINK
        Invoke-RunLab
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Alias('Shutdown-Lab')]
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
    $lab = Import-LabConfiguration -Path $Path

    Write-LabMessage -Message "Shutting down the lab environment for $($lab.Name)" -Color Green -Quiet:$NoMessages

    # reverse boot order: clients first, DC last
    foreach ($node in ($lab.Nodes | Sort-Object BootOrder -Descending)) {
        $vmx = Get-LabVMXPath -Node $node
        if ((Get-LabVMState -Node $node) -ne 'Running') {
            Write-Verbose "$($node.VMName) is not running"
            continue
        }
        if ($PSCmdlet.ShouldProcess($node.VMName, 'vmrun stop soft')) {
            Write-LabMessage -Message "Stopping $($node.VMName)" -Quiet:$NoMessages
            $soft = Invoke-VMRun -Command stop -Arguments $vmx, 'soft' -IgnoreErrors
            if ($null -eq $soft -and ((Get-LabVMState -Node $node) -eq 'Running')) {
                Write-Warning "Soft shutdown of $($node.VMName) failed (VMware Tools may not be running). Powering off hard."
                [void](Invoke-VMRun -Command stop -Arguments $vmx, 'hard' -IgnoreErrors)
            }
        }
    }

    if (-not $NoMessages) {
        Microsoft.PowerShell.Utility\Write-Host -ForegroundColor Green -Object @"

    Next Steps:

    To save the current state of the lab VMs:
    Snapshot-Lab

    To quickly rebuild the labs from the snapshot:
    Refresh-Lab

    To start the lab again:
    Run-Lab

    To destroy the lab:
    Wipe-Lab

"@
    }
    Write-Verbose "Ending $($MyInvocation.MyCommand)"
}
