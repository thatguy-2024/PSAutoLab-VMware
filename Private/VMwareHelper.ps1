# VMwareHelper.ps1
# Internal helpers for locating and invoking the VMware Workstation Pro tool chain
# (vmrun.exe, vmware-vdiskmanager.exe, vnetlib64.exe). Not exported.

function Get-VMwarePath {
    <#
    .SYNOPSIS
        Locate the VMware Workstation Pro installation and its CLI tools.
    .DESCRIPTION
        Checks the registry (HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation
        and HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation) and well-known install
        locations for VMware Workstation Pro. Returns a PSCustomObject with the paths
        of vmrun.exe, vmware-vdiskmanager.exe, vmware.exe and vnetlib64.exe plus the
        detected product version.
    .EXAMPLE
        PS C:\> Get-VMwarePath
        Returns the resolved tool paths or throws if Workstation is not installed.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $installPath = $null
    $regPaths = @(
        'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation',
        'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation'
    )
    foreach ($reg in $regPaths) {
        if (Test-Path -Path $reg) {
            $props = Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue
            if ($props.InstallPath) {
                $installPath = $props.InstallPath
                break
            }
        }
    }

    if (-not $installPath) {
        # fall back to well-known locations
        $candidates = @(
            "$env:ProgramFiles\VMware\VMware Workstation",
            "${env:ProgramFiles(x86)}\VMware\VMware Workstation"
        )
        $installPath = $candidates | Where-Object { $_ -and (Test-Path -Path (Join-Path $_ 'vmrun.exe')) } | Select-Object -First 1
    }

    if (-not $installPath) {
        throw 'VMware Workstation Pro does not appear to be installed. Install VMware Workstation Pro 17 or later and re-run Setup-Host.'
    }

    $vmrun = Join-Path $installPath 'vmrun.exe'
    $vdiskmanager = Join-Path $installPath 'vmware-vdiskmanager.exe'
    $vnetlib = Join-Path $installPath 'vnetlib64.exe'
    if (-not (Test-Path $vnetlib)) { $vnetlib = Join-Path $installPath 'vnetlib.exe' }

    foreach ($tool in $vmrun, $vdiskmanager) {
        if (-not (Test-Path -Path $tool)) {
            throw "Required VMware tool not found: $tool. Verify your VMware Workstation Pro installation."
        }
    }

    $version = $null
    try {
        $version = (Get-Item (Join-Path $installPath 'vmware.exe') -ErrorAction Stop).VersionInfo.ProductVersion
    }
    catch {
        Write-Verbose "Could not determine VMware Workstation version: $($_.Exception.Message)"
    }

    [PSCustomObject]@{
        PSTypeName   = 'PSAutoLabVMware.VMwarePath'
        InstallPath  = $installPath
        VMRun        = $vmrun
        VDiskManager = $vdiskmanager
        VNetLib      = $vnetlib
        VMwareExe    = Join-Path $installPath 'vmware.exe'
        Version      = $version
    }
}

function Invoke-VMRun {
    <#
    .SYNOPSIS
        Invoke vmrun.exe with the given command and arguments.
    .DESCRIPTION
        Wrapper around vmrun.exe (host type 'ws'). Captures stdout/stderr, throws a
        descriptive error when vmrun returns a non-zero exit code unless
        -IgnoreErrors is specified. Returns the trimmed stdout lines.
    .PARAMETER Command
        The vmrun command, e.g. start, stop, snapshot, revertToSnapshot, list,
        listSnapshots, deleteVM, runProgramInGuest, CopyFileFromHostToGuest.
    .PARAMETER Arguments
        Additional arguments (typically the .vmx path first).
    .PARAMETER GuestCredential
        Optional credential; when supplied, -gu/-gp guest options are inserted
        before the command (required for guest operations).
    .PARAMETER IgnoreErrors
        Return $null instead of throwing when vmrun fails.
    .EXAMPLE
        PS C:\> Invoke-VMRun -Command start -Arguments 'C:\AutolabVMware\VMs\DC1\DC1.vmx', 'nogui'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [string[]]$Arguments = @(),

        [PSCredential]$GuestCredential,

        [switch]$IgnoreErrors
    )

    $vmware = Get-VMwarePath
    $argList = @('-T', 'ws')
    if ($GuestCredential) {
        $argList += @('-gu', $GuestCredential.UserName, '-gp', $GuestCredential.GetNetworkCredential().Password)
    }
    $argList += $Command
    $argList += $Arguments

    Write-Verbose "vmrun $Command $($Arguments -join ' ')"
    $output = & $vmware.VMRun @argList 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $msg = "vmrun $Command failed (exit code $exitCode): $($output -join '; ')"
        if ($IgnoreErrors) {
            Write-Verbose $msg
            return $null
        }
        throw $msg
    }
    $output | ForEach-Object { "$_".Trim() } | Where-Object { $_ }
}

function Get-RunningVMX {
    <#
    .SYNOPSIS
        Return the list of .vmx paths for currently running VMware VMs.
    .DESCRIPTION
        Wraps 'vmrun list'. The first line of output is a count header which is
        stripped. Returns an array of fully-qualified vmx paths (may be empty).
    .EXAMPLE
        PS C:\> Get-RunningVMX
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $lines = Invoke-VMRun -Command list -IgnoreErrors
    @($lines | Where-Object { $_ -match '\.vmx$' })
}

function Test-IsAdministrator {
    <#
    .SYNOPSIS
        Test whether the current PowerShell session is elevated.
    .EXAMPLE
        PS C:\> Test-IsAdministrator
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $user).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Write-LabMessage {
    <#
    .SYNOPSIS
        Write a colored status message unless suppressed.
    .PARAMETER Message
        Text to display.
    .PARAMETER Color
        Console color (default Cyan).
    .PARAMETER Quiet
        Suppress output.
    .EXAMPLE
        PS C:\> Write-LabMessage -Message 'Building lab...' -Color Green
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ConsoleColor]$Color = 'Cyan',
        [switch]$Quiet
    )
    if (-not $Quiet) {
        Microsoft.PowerShell.Utility\Write-Host $Message -ForegroundColor $Color
    }
}
