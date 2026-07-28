function Invoke-ValidateLab {
    <#
    .SYNOPSIS
        Validate that the lab's DSC configurations have converged.
    .DESCRIPTION
        The VMware equivalent of the original Validate-Lab. Runs the Pester
        test file (VMValidate.test.ps1) in the configuration folder in a loop
        until all tests pass or 65 minutes elapse - the same convergence loop
        as the Hyper-V version. The shipped tests are VMware adaptations of the
        original tests: they connect to each guest over WinRM (by lab IP
        address) instead of PowerShell Direct and verify computer names,
        network settings, roles and domain membership.

        Any lab VM that is powered off is started first. On loop passes 4 and
        7, VMs that are still failing are reset (vmrun reset) to nudge stuck
        configurations, mirroring the original's Restart-VM behavior.
    .PARAMETER Path
        The path to the configuration folder. Default is the current location.
    .PARAMETER NoMessages
        Run the command but suppress all status messages.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Validate-Lab
    .LINK
        Invoke-PesterTest
    #>
    [CmdletBinding()]
    [Alias('Validate-Lab')]
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
    $testFile = Join-Path -Path $lab.Path -ChildPath 'VMValidate.test.ps1'
    if (-not (Test-Path -Path $testFile)) {
        throw "No VMValidate.test.ps1 found in $($lab.Path)."
    }

    Write-LabMessage -Message "Validating the $($lab.Name) lab. This may take some time while configurations converge." -Color Green -Quiet:$NoMessages

    # make sure every VM is running
    foreach ($node in $lab.Nodes) {
        if ((Get-LabVMState -Node $node) -eq 'Off') {
            Write-LabMessage -Message "Starting $($node.VMName)" -Quiet:$NoMessages
            try { Start-LabVM -VMXPath (Get-LabVMXPath -Node $node) } catch { Write-Warning "Could not start $($node.VMName): $($_.Exception.Message)" }
        }
    }

    # Load a modern Pester (v5 or v6 - installed by Setup-Host). The tests use
    # the data-driven syntax (BeforeDiscovery / -ForEach) that only exists in
    # Pester 5+, and this command drives them through New-PesterConfiguration,
    # which is the supported API across Pester 5.2 -> 6.x (the legacy -Show
    # parameter was deprecated in v5 and removed in v6).
    #
    # IMPORTANT: Windows PowerShell 5.1 ships with Pester 3.4.0 auto-loaded.
    # If we simply Import-Module -Force a newer version, the old one stays
    # loaded too, so 'Invoke-Pester' can still resolve to the v3 command while
    # (Get-Module Pester).Version returns an ARRAY of every loaded version. We
    # therefore unload ALL Pester modules first, then import exactly one modern
    # version and read that single module's version.
    Get-Module -Name Pester -All | Remove-Module -Force -ErrorAction SilentlyContinue

    $pesterModule = Get-Module -Name Pester -ListAvailable |
        Where-Object { $_.Version.Major -ge 5 } |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pesterModule) {
        throw 'Pester 5.0 or later is required (found only older versions). Run Setup-Host, then open a NEW PowerShell session and retry. Setup-Host runs: Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck.'
    }
    Import-Module -Name Pester -RequiredVersion $pesterModule.Version -Force -Global -ErrorAction Stop

    # Read the version from the single module we just imported (not an array).
    $loadedPester = @(Get-Module -Name Pester | Sort-Object Version -Descending)[0]
    Write-LabMessage -Message "Using Pester $($loadedPester.Version)" -Quiet:$NoMessages

    # Helper: build a fresh Pester configuration object for each run.
    function New-LabPesterConfig {
        param([string]$TestPath, [string]$Verbosity, [switch]$PassThru)
        $cfg = New-PesterConfiguration
        $cfg.Run.Path = $TestPath
        $cfg.Output.Verbosity = $Verbosity
        if ($PassThru) { $cfg.Run.PassThru = $true }
        return $cfg
    }

    $startTime = Get-Date
    $timeoutMinutes = 65
    $pass = 0
    $complete = $false

    do {
        $pass++
        Write-LabMessage -Message "[$(Get-Date -Format 'HH:mm:ss')] Validation pass $pass" -Quiet:$NoMessages

        $cfg = New-LabPesterConfig -TestPath $testFile -Verbosity 'None' -PassThru
        $result = Invoke-Pester -Configuration $cfg -WarningAction SilentlyContinue

        if ($result.FailedCount -eq 0 -and $result.PassedCount -gt 0) {
            $complete = $true
            break
        }

        Write-LabMessage -Message "$($result.FailedCount) test(s) still failing. Waiting 5 minutes before retrying. Press Ctrl+C to cancel (the lab keeps converging; validate later with Run-Pester)." -Color Yellow -Quiet:$NoMessages

        # on passes 4 and 7, reset VMs to nudge stuck configurations
        if ($pass -in 4, 7) {
            Write-LabMessage -Message 'Restarting lab VMs to nudge convergence' -Color Yellow -Quiet:$NoMessages
            foreach ($node in $lab.Nodes) {
                if ((Get-LabVMState -Node $node) -eq 'Running') {
                    [void](Invoke-VMRun -Command reset -Arguments (Get-LabVMXPath -Node $node), 'soft' -IgnoreErrors)
                }
            }
        }

        Start-Sleep -Seconds 300
    } while (((Get-Date) - $startTime).TotalMinutes -lt $timeoutMinutes)

    if ($complete) {
        Write-LabMessage -Message 'All validation tests passed. Re-running with full output:' -Color Green -Quiet:$NoMessages
        $cfgFull = New-LabPesterConfig -TestPath $testFile -Verbosity 'Detailed'
        Invoke-Pester -Configuration $cfgFull -WarningAction SilentlyContinue
        if (-not $NoMessages) {
            Microsoft.PowerShell.Utility\Write-Host -ForegroundColor Green -Object @"

    The lab has converged. Suggested next steps:

    Snapshot-Lab   - checkpoint the configured lab
    Shutdown-Lab   - stop the lab VMs
"@
        }
    }
    else {
        Write-Warning "Validation did not complete within $timeoutMinutes minutes. The lab may still be converging. Run Run-Pester later to re-test, and check VM state with Get-LabStatus."
    }
    Write-Verbose "Ending $($MyInvocation.MyCommand)"
}
