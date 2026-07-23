#
# Module manifest for module 'PSAutoLabVMware'
#
# A port of the Pluralsight PS-AutoLab-Env project (PSAutoLab) from Hyper-V/Lability
# to VMware Workstation Pro. Same lab configurations, same DSC configurations,
# VMware Workstation as the hypervisor.
#

@{
    RootModule           = 'PSAutoLabVMware.psm1'
    ModuleVersion        = '1.0.0'
    CompatiblePSEditions = @('Desktop')
    GUID                 = 'f3f2b4a1-6f7e-4c9a-9c1d-2e8a5b7d4c10'
    Author               = 'PSAutoLabVMware Project'
    CompanyName          = 'Community'
    Copyright            = '(c) 2026 PSAutoLabVMware Project. MIT License.'
    Description          = 'Control scripts to build, snapshot, validate and remove Windows lab environments on VMware Workstation Pro using DSC configurations. A VMware port of the PSAutoLab (PS-AutoLab-Env) module.'
    PowerShellVersion    = '5.1'

    # Pester 5.x is required for Validate-Lab / Invoke-PesterTest
    # (not listed in RequiredModules so the module can load before Setup-Host installs it)

    FunctionsToExport    = @(
        'Invoke-SetupHost',
        'Invoke-SetupLab',
        'Invoke-RunLab',
        'Enable-Internet',
        'Invoke-ValidateLab',
        'Invoke-ShutdownLab',
        'Invoke-WipeLab',
        'Invoke-UnattendLab',
        'Invoke-SnapshotLab',
        'Invoke-RefreshLab',
        'Get-LabStatus',
        'Get-LabSummary',
        'Invoke-PesterTest',
        'Test-LabDSCResource'
    )

    AliasesToExport      = @(
        'Setup-Host',
        'Setup-Lab',
        'Run-Lab',
        'Validate-Lab',
        'Shutdown-Lab',
        'Wipe-Lab',
        'Unattend-Lab',
        'Snapshot-Lab',
        'Refresh-Lab',
        'Run-Pester'
    )

    CmdletsToExport      = @()
    VariablesToExport    = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @('Lab', 'VMware', 'Workstation', 'DSC', 'Training', 'AutoLab', 'PSAutoLab')
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            ProjectUri   = 'https://github.com/pluralsight/PS-AutoLab-Env'
            ReleaseNotes = @'
## 1.0.0
- Initial release: full port of PS-AutoLab-Env v5.1.0 to VMware Workstation Pro.
- VM provisioning via generated VMX files + vmware-vdiskmanager VMDKs.
- Unattended Windows installation via autounattend.xml secondary ISO.
- DSC configurations pushed over WinRM (replaces PowerShell Direct).
- Power/snapshot management via vmrun.
'@
        }
    }
}
