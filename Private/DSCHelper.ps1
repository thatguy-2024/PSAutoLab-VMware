# DSCHelper.ps1
# Compiles DSC MOF files on the host (using the ORIGINAL, unmodified
# VMConfiguration.ps1 files) and pushes them to the guests over WinRM.
# This replaces Lability's offline MOF injection + PowerShell Direct with a
# network push model. Not exported.

function Invoke-LabDSCCompile {
    <#
    .SYNOPSIS
        Compile the lab's DSC configuration into per-node MOF files.
    .DESCRIPTION
        Dot-sources the configuration folder's VMConfiguration.ps1 - the exact
        same file used by the original Hyper-V module - which defines and
        invokes the AutoLab DSC configuration against VMConfigurationData.psd1,
        producing <Node>.mof and <Node>.meta.mof in the configuration folder.
    .PARAMETER Path
        Path to the lab configuration folder.
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Invoke-LabDSCCompile -Path .
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path
    )

    $Path = Convert-Path $Path
    $vmConfig = Join-Path -Path $Path -ChildPath 'VMConfiguration.ps1'
    if (-not (Test-Path -Path $vmConfig)) {
        throw "VMConfiguration.ps1 not found in $Path"
    }
    Write-Verbose "Compiling DSC MOFs from $vmConfig"
    # the script compiles into $PSScriptRoot (= the configuration folder)
    . $vmConfig
}

function Install-LabDSCResource {
    <#
    .SYNOPSIS
        Install the DSC resource modules a lab requires on the host.
    .DESCRIPTION
        Reads NonNodeData.Lability.DSCResource from the configuration data and
        installs each module at its pinned RequiredVersion from the PSGallery,
        matching the original Setup-Lab behavior. Modules already present at the
        correct version are skipped.
    .PARAMETER Lab
        A lab object from Import-LabConfiguration.
    .PARAMETER Quiet
        Suppress status messages.
    .EXAMPLE
        PS C:\> Install-LabDSCResource -Lab $lab
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object]$Lab,
        [switch]$Quiet
    )

    if (-not $Lab.DSCResources -or $Lab.DSCResources.Count -eq 0) {
        Write-Verbose 'No DSC resources listed in configuration data.'
        return
    }

    [void](Install-PackageProvider -Name NuGet -Force -ForceBootstrap -ErrorAction SilentlyContinue)

    foreach ($resource in $Lab.DSCResources) {
        $existing = Get-Module -FullyQualifiedName @{ ModuleName = $resource.Name; RequiredVersion = $resource.RequiredVersion } -ListAvailable
        if ($existing) {
            Write-LabMessage -Message "$($resource.Name) [v$($resource.RequiredVersion)] requires no updates." -Color Green -Quiet:$Quiet
        }
        else {
            Write-LabMessage -Message "Installing $($resource.Name) version $($resource.RequiredVersion)" -Color Yellow -Quiet:$Quiet
            if ($PSCmdlet.ShouldProcess($resource.Name, "Install-Module v$($resource.RequiredVersion)")) {
                Install-Module -Name $resource.Name -RequiredVersion $resource.RequiredVersion -Force -SkipPublisherCheck -AllowClobber
            }
        }
    }
}

function Wait-LabVM {
    <#
    .SYNOPSIS
        Wait for a lab VM to finish installing Windows and answer WinRM.
    .DESCRIPTION
        Polls the node's IP address with Test-WSMan and then attempts an
        authenticated session until the guest responds or the timeout expires.
        This is how the module knows unattended setup + first-logon bootstrap
        have completed.
    .PARAMETER Node
        A node object produced by Import-LabConfiguration.
    .PARAMETER Credential
        Credential to authenticate with (from Get-LabNodeCredential).
    .PARAMETER TimeoutMinutes
        Maximum minutes to wait. Default 60.
    .EXAMPLE
        PS C:\> Wait-LabVM -Node $node -Credential $cred -TimeoutMinutes 45
    .OUTPUTS
        Boolean. True when the VM became reachable.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object]$Node,

        [Parameter(Mandatory)]
        [PSCredential]$Credential,

        [int]$TimeoutMinutes = 60
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $ip = $Node.IPAddress
    Write-Verbose "Waiting up to $TimeoutMinutes minutes for $($Node.Computername) ($ip) to answer WinRM"

    while ((Get-Date) -lt $deadline) {
        if (Test-WSMan -ComputerName $ip -ErrorAction SilentlyContinue) {
            try {
                $session = New-PSSession -ComputerName $ip -Credential $Credential -ErrorAction Stop
                Remove-PSSession -Session $session
                Write-Verbose "$($Node.Computername) is answering WinRM."
                return $true
            }
            catch {
                Write-Verbose "WinRM up on $ip but authentication not ready yet: $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds 30
    }
    Write-Warning "$($Node.Computername) ($ip) did not answer WinRM within $TimeoutMinutes minutes."
    $false
}

function Publish-LabDSCConfiguration {
    <#
    .SYNOPSIS
        Push a node's compiled DSC configuration to the guest over WinRM.
    .DESCRIPTION
        Copies the DSC resource modules the lab requires from the host's module
        path into the guest's Program Files module path (over the PSSession),
        copies <Node>.mof / <Node>.meta.mof to C:\AutoLabDSC in the guest, then
        applies the LCM meta-configuration (Set-DscLocalConfigurationManager)
        and starts the configuration (Start-DscConfiguration -Force). The LCM's
        ApplyOnly/RebootNodeIfNeeded settings from the original configurations
        drive convergence from there.
    .PARAMETER Node
        A node object produced by Import-LabConfiguration.
    .PARAMETER Lab
        The lab object from Import-LabConfiguration.
    .PARAMETER Credential
        Credential for the guest (local Administrator during first deployment).
    .EXAMPLE
        PS C:\> Publish-LabDSCConfiguration -Node $node -Lab $lab -Credential $cred
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object]$Node,

        [Parameter(Mandatory)]
        [object]$Lab,

        [Parameter(Mandatory)]
        [PSCredential]$Credential
    )

    $mof = Join-Path -Path $Lab.Path -ChildPath "$($Node.Computername).mof"
    $metaMof = Join-Path -Path $Lab.Path -ChildPath "$($Node.Computername).meta.mof"
    if (-not (Test-Path -Path $mof)) {
        Write-Warning "No MOF found for $($Node.Computername) at $mof. Run Setup-Lab first."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Node.Computername, 'Publish DSC configuration')) { return }

    $session = New-PSSession -ComputerName $Node.IPAddress -Credential $Credential -ErrorAction Stop
    try {
        # stage folder in guest
        Invoke-Command -Session $session -ScriptBlock {
            if (-not (Test-Path C:\AutoLabDSC)) { [void](New-Item -Path C:\AutoLabDSC -ItemType Directory -Force) }
        }

        # copy required DSC resource modules into the guest
        foreach ($resource in $Lab.DSCResources) {
            $hostModule = Get-Module -FullyQualifiedName @{ ModuleName = $resource.Name; RequiredVersion = $resource.RequiredVersion } -ListAvailable |
                Select-Object -First 1
            if (-not $hostModule) {
                Write-Warning "Module $($resource.Name) v$($resource.RequiredVersion) is not installed on the host; guest may fail to converge."
                continue
            }
            $sourceDir = Split-Path -Path $hostModule.Path -Parent
            $destDir = "C:\Program Files\WindowsPowerShell\Modules\$($resource.Name)\$($resource.RequiredVersion)"

            $already = Invoke-Command -Session $session -ScriptBlock { Test-Path $using:destDir }
            if (-not $already) {
                Write-Verbose "Copying module $($resource.Name) v$($resource.RequiredVersion) to $($Node.Computername)"
                Copy-Item -Path $sourceDir -Destination $destDir -ToSession $session -Recurse -Force
            }
        }

        # copy the MOFs. LCM expects localhost.mof naming for -Path based pushes,
        # so stage them in a dedicated folder using the node name it was compiled for.
        Copy-Item -Path $mof -Destination "C:\AutoLabDSC\$($Node.Computername).mof" -ToSession $session -Force
        if (Test-Path -Path $metaMof) {
            Copy-Item -Path $metaMof -Destination "C:\AutoLabDSC\$($Node.Computername).meta.mof" -ToSession $session -Force
        }

        # apply the LCM settings then start the configuration
        Invoke-Command -Session $session -ScriptBlock {
            param($nodeName)
            $ErrorActionPreference = 'Stop'
            $staging = 'C:\AutoLabDSC\Apply'
            if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
            [void](New-Item -Path $staging -ItemType Directory -Force)

            # DSC push expects localhost.mof / localhost.meta.mof in the -Path folder
            Copy-Item "C:\AutoLabDSC\$nodeName.mof" (Join-Path $staging 'localhost.mof') -Force
            if (Test-Path "C:\AutoLabDSC\$nodeName.meta.mof") {
                Copy-Item "C:\AutoLabDSC\$nodeName.meta.mof" (Join-Path $staging 'localhost.meta.mof') -Force
                Set-DscLocalConfigurationManager -Path $staging -Force
            }
            Start-DscConfiguration -Path $staging -Force -Wait:$false
        } -ArgumentList $Node.Computername

        Write-Verbose "DSC configuration published to $($Node.Computername). The LCM will now converge (may include reboots)."
    }
    finally {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

function Get-LabDSCStatus {
    <#
    .SYNOPSIS
        Query a guest's DSC convergence status over WinRM.
    .PARAMETER Node
        A node object produced by Import-LabConfiguration.
    .PARAMETER Credential
        Credential for the guest.
    .EXAMPLE
        PS C:\> Get-LabDSCStatus -Node $node -Credential $cred
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Node,

        [Parameter(Mandatory)]
        [PSCredential]$Credential
    )

    try {
        Invoke-Command -ComputerName $Node.IPAddress -Credential $Credential -ScriptBlock {
            $status = Get-DscConfigurationStatus -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                Status       = $status.Status
                RebootNeeded = $status.RebootRequested
                StartDate    = $status.StartDate
                Type         = $status.Type
            }
        } -ErrorAction Stop
    }
    catch {
        Write-Verbose "Could not query DSC status on $($Node.Computername): $($_.Exception.Message)"
        $null
    }
}
