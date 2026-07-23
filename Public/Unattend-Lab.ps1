function Invoke-UnattendLab {
    <#
    .SYNOPSIS
        Run the full lab build sequence unattended.
    .DESCRIPTION
        The VMware equivalent of the original Unattend-Lab. Runs, in order:

          1. Setup-Lab       - build disks, VMX files, unattend ISOs, MOFs
          2. Run-Lab         - power on, install Windows, push DSC over WinRM
          3. Enable-Internet - host NAT for the lab subnet
          4. (20 minute pause for configurations to converge)
          5. Validate-Lab    - Pester convergence loop

        Go get coffee - the first run downloads ISOs and performs full
        unattended Windows installations, which takes a while.
    .PARAMETER Path
        The path to the configuration folder. Default is the current location.
    .PARAMETER UseLocalTimeZone
        Override any configuration-specified time zone with this computer's.
    .PARAMETER AsJob
        Run the sequence in a background job. Manage it with the standard
        *-Job cmdlets; receive output with Receive-Job -Keep.
    .PARAMETER NoMessages
        Run the command but suppress all status messages.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Unattend-Lab
        Builds, starts, networks and validates the lab with no interaction.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\SingleServer> Unattend-Lab -AsJob
        Runs the whole build in a background job.
    .LINK
        Invoke-SetupLab
    .LINK
        Invoke-RunLab
    .LINK
        Invoke-ValidateLab
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Alias('Unattend-Lab')]
    param(
        [Parameter(HelpMessage = 'The path to the configuration folder. Normally, you should run all commands from within the configuration folder.')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path = '.',

        [Parameter(HelpMessage = 'Override any configuration specified time zone and use the local time zone on this computer.')]
        [switch]$UseLocalTimeZone,

        [switch]$AsJob,

        [Parameter(HelpMessage = 'Run the command but suppress all status messages.')]
        [Alias('Quiet')]
        [switch]$NoMessages
    )

    Write-Verbose "Starting $($MyInvocation.MyCommand)"
    $Path = Convert-Path -Path $Path

    $sequence = {
        param($Path, $UseLocalTimeZone, $NoMessages)

        Import-Module PSAutoLabVMware -Force

        Invoke-SetupLab -Path $Path -UseLocalTimeZone:$UseLocalTimeZone -NoMessages:$NoMessages
        Invoke-RunLab -Path $Path -NoMessages:$NoMessages
        Enable-Internet -Path $Path -NoMessages:$NoMessages

        # give configurations time to converge before validating (matches original)
        if (-not $NoMessages) {
            Microsoft.PowerShell.Utility\Write-Host 'Waiting 20 minutes for configurations to converge before validating...' -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 1200

        Invoke-ValidateLab -Path $Path -NoMessages:$NoMessages
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Unattended lab build')) {
        if ($AsJob) {
            Start-Job -ScriptBlock $sequence -ArgumentList $Path, $UseLocalTimeZone.IsPresent, $NoMessages.IsPresent -Name "UnattendLab-$(Split-Path $Path -Leaf)"
        }
        else {
            & $sequence $Path $UseLocalTimeZone.IsPresent $NoMessages.IsPresent
        }
    }
    Write-Verbose "Ending $($MyInvocation.MyCommand)"
}
