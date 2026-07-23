function Invoke-RunLab {
    <#
    .SYNOPSIS
        Power on the lab VMs, wait for Windows to install and apply DSC.
    .DESCRIPTION
        The VMware equivalent of the original Run-Lab, with extra work the
        Hyper-V version delegated to Lability's offline injection:

          * Powers on every lab VM with vmrun, honoring Lability_BootOrder and
            Lability_BootDelay from the configuration data
          * On first run, waits for the unattended Windows installation and
            first-logon bootstrap to complete (the guest starts answering WinRM
            on its static lab IP)
          * Switches each VM's boot order to hard disk and disconnects the
            install media once setup has finished
          * Pushes the compiled DSC configuration (MOF + resource modules) to
            each guest over WinRM; the LCM then converges (ApplyOnly mode with
            automatic reboots, exactly as in the Hyper-V labs)

        If DSC has already been published to a VM (marker file in the VM
        folder), the deployment step is skipped and the VMs are simply started.
    .PARAMETER Path
        The path to the configuration folder. Default is the current location.
    .PARAMETER SkipDSC
        Only power on the VMs; do not wait for WinRM or push DSC.
    .PARAMETER TimeoutMinutes
        Minutes to wait for each VM's unattended install to finish. Default 60.
    .PARAMETER NoMessages
        Run the command but suppress all status messages.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Run-Lab
        Starts the MultiRole lab, installing Windows and applying DSC on first run.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Run-Lab -SkipDSC
        Just powers the VMs on.
    .LINK
        Invoke-SetupLab
    .LINK
        Invoke-ValidateLab
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Alias('Run-Lab')]
    param(
        [Parameter(HelpMessage = 'The path to the configuration folder. Normally, you should run all commands from within the configuration folder.')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path = '.',

        [switch]$SkipDSC,

        [ValidateRange(5, 240)]
        [int]$TimeoutMinutes = 60,

        [Parameter(HelpMessage = 'Run the command but suppress all status messages.')]
        [Alias('Quiet')]
        [switch]$NoMessages
    )

    Write-Verbose "Starting $($MyInvocation.MyCommand)"
    $lab = Import-LabConfiguration -Path $Path

    Write-LabMessage -Message "Starting the lab environment for $($lab.Name)" -Color Green -Quiet:$NoMessages

    # 1) power on in boot order
    foreach ($node in $lab.Nodes) {
        $vmx = Get-LabVMXPath -Node $node
        if (-not (Test-Path -Path $vmx)) {
            Write-Warning "VM $($node.VMName) has not been created. Run Setup-Lab first."
            continue
        }
        if ((Get-LabVMState -Node $node) -eq 'Running') {
            Write-LabMessage -Message "$($node.VMName) is already running" -Quiet:$NoMessages
            continue
        }
        if ($PSCmdlet.ShouldProcess($node.VMName, 'vmrun start')) {
            Write-LabMessage -Message "Powering on $($node.VMName)" -Quiet:$NoMessages
            [void](Invoke-VMRun -Command start -Arguments $vmx, 'nogui')
            if ($node.BootDelay -gt 0) {
                Write-Verbose "Boot delay: waiting $($node.BootDelay) seconds before the next VM"
                Start-Sleep -Seconds $node.BootDelay
            }
        }
    }

    # 2) first-run deployment: wait for install, then push DSC
    if (-not $SkipDSC) {
        foreach ($node in $lab.Nodes) {
            $vmFolder = Get-LabVMFolder -Node $node
            $marker = Join-Path -Path $vmFolder -ChildPath 'dsc-published.txt'
            if (Test-Path -Path $marker) {
                Write-Verbose "DSC already published to $($node.Computername); skipping"
                continue
            }
            if (-not (Test-Path (Get-LabVMXPath -Node $node))) { continue }

            Write-LabMessage -Message "Waiting for Windows installation on $($node.Computername) ($($node.IPAddress)). This can take 20-40 minutes on first run." -Color Yellow -Quiet:$NoMessages

            # during first deployment the machine is standalone: local admin credential
            $secure = ConvertTo-SecureString -String $lab.Password -AsPlainText -Force
            $localCred = New-Object PSCredential ".\Administrator", $secure

            if (-not (Wait-LabVM -Node $node -Credential $localCred -TimeoutMinutes $TimeoutMinutes)) {
                Write-Warning "Skipping DSC deployment for $($node.Computername); it never became reachable. Re-run Run-Lab once the VM answers WinRM."
                continue
            }

            # install finished: boot from disk and detach install media going forward
            Set-LabVMXBootOrder -VMXPath (Get-LabVMXPath -Node $node) -DisconnectISO

            Write-LabMessage -Message "Publishing DSC configuration to $($node.Computername)" -Quiet:$NoMessages
            if ($PSCmdlet.ShouldProcess($node.Computername, 'Publish DSC configuration')) {
                try {
                    Publish-LabDSCConfiguration -Node $node -Lab $lab -Credential $localCred
                    Set-Content -Path $marker -Value (Get-Date -Format o)
                }
                catch {
                    Write-Warning "Failed to publish DSC to $($node.Computername): $($_.Exception.Message)"
                }
            }
        }
    }

    if (-not $NoMessages) {
        Microsoft.PowerShell.Utility\Write-Host -ForegroundColor Green -Object @"

    Next Steps:

    To enable Internet access for the VMs, run:
    Enable-Internet

    Run the following to validate when configurations have converged:
    Validate-Lab
    (configurations converge in the background and may reboot the VMs
    several times - this is normal)

    To stop the lab VMs:
    Shutdown-Lab

    When the configurations have finished, you can snapshot the VMs with:
    Snapshot-Lab

    To quickly rebuild the labs from the snapshot, run:
    Refresh-Lab

"@
    }
    Write-Verbose "Ending $($MyInvocation.MyCommand)"
}
