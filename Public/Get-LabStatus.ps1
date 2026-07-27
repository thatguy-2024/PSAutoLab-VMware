function Get-LabStatus {
    <#
    .SYNOPSIS
        Show the current state of the lab VMs.
    .DESCRIPTION
        Reports each VM defined in the configuration folder: power state
        (Running/Off/NotCreated, via vmrun), IP address, roles, media,
        snapshots, whether DSC has been published, and (when the VM is
        reachable and -IncludeDSC is used) the guest's DSC convergence status
        over WinRM.
    .PARAMETER Path
        The path to the configuration folder. Default is the current location.
    .PARAMETER IncludeDSC
        Also query each running VM's DSC status over WinRM (slower).
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Get-LabStatus

        Lab       Computername VMName Status  IPAddress     DSCPublished
        ---       ------------ ------ ------  ---------     ------------
        MultiRole DC1          DC1    Running 192.168.3.10  True
        ...
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Get-LabStatus -IncludeDSC
    .LINK
        Get-LabSummary
    #>
    [CmdletBinding()]
    param(
        [Parameter(HelpMessage = 'The path to the configuration folder. Normally, you should run all commands from within the configuration folder.')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path = '.',

        [switch]$IncludeDSC
    )

    Write-Verbose "Starting $($MyInvocation.MyCommand)"
    $lab = Import-LabConfiguration -Path $Path

    foreach ($node in $lab.Nodes) {
        $state = Get-LabVMState -Node $node
        $vmx = Get-LabVMXPath -Node $node
        $marker = Join-Path -Path (Get-LabVMFolder -Node $node) -ChildPath 'dsc-published.txt'

        $snapshots = @()
        if (Test-Path -Path $vmx) {
            $snapshots = @(Invoke-VMRun -Command listSnapshots -Arguments $vmx -IgnoreErrors |
                    Where-Object { $_ -and $_ -notmatch 'Total snapshots' })
        }

        $dscStatus = $null
        if ($IncludeDSC -and $state -eq 'Running') {
            $cred = Get-LabNodeCredential -Node $node -Password $lab.Password
            $dsc = Get-LabDSCStatus -Node $node -Credential $cred
            if ($dsc) { $dscStatus = $dsc.Status }
        }

        [PSCustomObject]@{
            PSTypeName   = 'PSAutoLabVMware.LabStatus'
            Lab          = $lab.Name
            Computername = $node.Computername
            VMName       = $node.VMName
            Status       = $state
            IPAddress    = $node.IPAddress
            Role         = $node.Role -join ', '
            Media        = $node.Media
            MemoryMB     = $node.MemoryMB
            Processors   = $node.Processors
            DSCPublished = (Test-Path -Path $marker)
            DSCStatus    = $dscStatus
            Snapshots    = $snapshots -join ', '
            VMXPath      = $vmx
        }
    }
    Write-Verbose "Ending $($MyInvocation.MyCommand)"
}

function Get-LabSummary {
    <#
    .SYNOPSIS
        Get a summary of the VMs defined in a lab configuration.
    .DESCRIPTION
        The VMware equivalent of the original Get-LabSummary. Parses
        VMConfigurationData.psd1 and emits one object per VM with the computer
        name, VM name (including any EnvironmentPrefix), install media and its
        description, roles, IP address, memory and processor count. Purely a
        configuration view - use Get-LabStatus for live VM state.
    .PARAMETER Path
        The path to the configuration folder. Default is the current location.
        Accepts pipeline input of folder paths.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\PowerShellLab> Get-LabSummary
    .EXAMPLE
        PS C:\> Get-ChildItem C:\AutolabVMware\Configurations -Directory | Get-LabSummary
        Summarizes every installed configuration.
    .LINK
        Get-LabStatus
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage = 'The path to the configuration folder.')]
        [Alias('FullName')]
        [ValidateNotNullOrEmpty()]
        [string]$Path = '.'
    )

    process {
        if (-not (Test-Path -Path $Path)) {
            Write-Warning "Path not found: $Path"
            return
        }
        $lab = Import-LabConfiguration -Path $Path
        foreach ($node in $lab.Nodes) {
            [PSCustomObject]@{
                PSTypeName   = 'PSAutolabVM'
                Computername = $node.Computername
                VMName       = $node.VMName
                InstallMedia = $node.Media
                Description  = $node.Description
                Role         = $node.Role
                IPAddress    = $node.IPAddress
                MemoryGB     = [math]::Round($node.MemoryMB / 1024, 2)
                Processors   = $node.Processors
                Lab          = $lab.Name
            }
        }
    }
}

function Invoke-PesterTest {
    <#
    .SYNOPSIS
        Run the lab's Pester validation test once with full output.
    .DESCRIPTION
        The VMware equivalent of the original Run-Pester. Starts any lab VM
        that is powered off, then runs the configuration folder's
        VMValidate.test.ps1 a single time showing all results. Use this to
        check convergence without the retry loop of Validate-Lab.
    .PARAMETER Path
        The path to the configuration folder. Default is the current location.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Run-Pester
    .LINK
        Invoke-ValidateLab
    #>
    [CmdletBinding()]
    [Alias('Run-Pester')]
    param(
        [Parameter(HelpMessage = 'The path to the configuration folder.')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path = '.'
    )

    $lab = Import-LabConfiguration -Path $Path
    $testFile = Join-Path -Path $lab.Path -ChildPath 'VMValidate.test.ps1'
    if (-not (Test-Path -Path $testFile)) {
        throw "No VMValidate.test.ps1 found in $($lab.Path)."
    }

    foreach ($node in $lab.Nodes) {
        if ((Get-LabVMState -Node $node) -eq 'Off') {
            Write-LabMessage -Message "Starting $($node.VMName)"
            try { Start-LabVM -VMXPath (Get-LabVMXPath -Node $node) } catch { Write-Warning "Could not start $($node.VMName): $($_.Exception.Message)" }
        }
    }

    Import-Module -Name Pester -MinimumVersion $script:PesterVersion -Force -Global -ErrorAction Stop
    Invoke-Pester -Path $testFile -Show All -WarningAction SilentlyContinue
}

function Test-LabDSCResource {
    <#
    .SYNOPSIS
        Verify the DSC resource modules a lab requires are installed on the host.
    .DESCRIPTION
        The VMware port of the original Test-LabDSCResource. Reads
        NonNodeData.Lability.DSCResource from the configuration data and
        reports, for each module, whether the pinned RequiredVersion is
        installed locally and which versions are present.
    .PARAMETER Path
        The path to the configuration folder. Default is the current location.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Test-LabDSCResource
    .LINK
        Invoke-SetupLab
    #>
    [CmdletBinding()]
    param(
        [Parameter(HelpMessage = 'The path to the configuration folder.')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path = '.'
    )

    $lab = Import-LabConfiguration -Path $Path
    foreach ($resource in $lab.DSCResources) {
        $installed = Get-Module -Name $resource.Name -ListAvailable
        [PSCustomObject]@{
            PSTypeName        = 'PSAutolabResource'
            ModuleName        = $resource.Name
            RequiredVersion   = $resource.RequiredVersion
            Installed         = [bool]($installed | Where-Object { $_.Version -eq [version]$resource.RequiredVersion })
            InstalledVersions = $installed.Version
            Configuration     = $lab.Name
        }
    }
}
