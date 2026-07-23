[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

#region Guard - Windows PowerShell 5.1 only
if ($PSEdition -ne 'Desktop') {
    Write-Warning @"

    This module is not supported in PowerShell $($PSVersionTable.PSVersion).
    Please use Windows PowerShell 5.1 for the best experience.

    The PSAutoLabVMware module will still be imported into this session but
    will not have any commands. You can manually remove it:

    Remove-Module PSAutoLabVMware

"@
    return
}
#endregion

#region Module-scope variables (referenced by public/private functions)

# Root folder for everything the module creates on the host
$AutoLabRoot = 'C:\AutolabVMware'

# Standard directory layout under $AutoLabRoot (mirrors Lability's Set-LabHostDefault layout)
$AutoLabFolders = @{
    ConfigurationPath = Join-Path $AutoLabRoot 'Configurations'   # lab configuration folders
    VMPath            = Join-Path $AutoLabRoot 'VMs'              # per-VM folders (vmx, vmdk, nvram)
    IsoPath           = Join-Path $AutoLabRoot 'ISOs'             # Windows evaluation ISOs
    UnattendIsoPath   = Join-Path $AutoLabRoot 'UnattendISOs'     # generated autounattend ISOs
    ResourcePath      = Join-Path $AutoLabRoot 'Resources'        # extra resources copied to guests
    LogPath           = Join-Path $AutoLabRoot 'Logs'             # module logs
}

# Configurations shipped with the module (copied to $AutoLabRoot\Configurations by Setup-Host)
$ConfigurationPath = Join-Path $PSScriptRoot 'Configurations'

# Autounattend.xml templates shipped with the module
$TemplatePath = Join-Path $PSScriptRoot 'Templates'

# Generic Pester validation test shipped with the module
$ModuleTestPath = Join-Path $PSScriptRoot 'Tests'

# Minimum supported Pester version for Validate-Lab
$PesterVersion = '5.5.0'

# VMware host-only virtual network used for the lab (LabNet equivalent).
# All shipped configurations use the 192.168.3.0/24 subnet with the host at .1.
$LabVMnet = 'vmnet2'
$LabVMnetSubnet = '192.168.3.0'
$LabVMnetMask = '255.255.255.0'
$LabVMnetHostIP = '192.168.3.1'

# Force TLS 1.2 for downloads from Microsoft
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#endregion

#region Dot-source private then public functions
foreach ($scope in 'Private', 'Public') {
    Get-ChildItem -Path (Join-Path $PSScriptRoot $scope) -Filter *.ps1 -ErrorAction SilentlyContinue |
        ForEach-Object { . $_.FullName }
}
#endregion

#region Pester check (advisory only)
$pesterModule = Get-Module -Name Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not ($pesterModule -and $pesterModule.Version -ge [version]$PesterVersion)) {
    Write-Warning "Pester v$PesterVersion or later is recommended for Validate-Lab. Install it with: Install-Module Pester -Force -SkipPublisherCheck"
}
#endregion

$publicFunctions = @(
    'Invoke-SetupHost', 'Invoke-SetupLab', 'Invoke-RunLab', 'Enable-Internet',
    'Invoke-ValidateLab', 'Invoke-ShutdownLab', 'Invoke-WipeLab', 'Invoke-UnattendLab',
    'Invoke-SnapshotLab', 'Invoke-RefreshLab', 'Get-LabStatus', 'Get-LabSummary',
    'Invoke-PesterTest', 'Test-LabDSCResource'
)
Export-ModuleMember -Function $publicFunctions -Alias *
