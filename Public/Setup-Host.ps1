function Invoke-SetupHost {
    <#
    .SYNOPSIS
        Prepare the host computer for building VMware Workstation lab environments.
    .DESCRIPTION
        One-time host preparation (VMware equivalent of the original Setup-Host):

          * Verifies VMware Workstation Pro 17+ is installed (vmrun.exe and
            vmware-vdiskmanager.exe must be present)
          * Enables PowerShell remoting on the host and sets WSMan TrustedHosts
            so the host can talk to workgroup lab VMs by IP address
          * Installs/updates the Pester module (v5.5+) needed by Validate-Lab
          * Creates the C:\AutolabVMware directory structure
            (Configurations, VMs, ISOs, UnattendISOs, Resources, Logs)
          * Configures the host-only lab virtual network (vmnet2 by default,
            192.168.3.0/24 with the host adapter at 192.168.3.1 - the same
            subnet all original lab configurations use)
          * Copies the lab configurations shipped with this module to
            C:\AutolabVMware\Configurations

        Unlike the Hyper-V original, no reboot is normally required.
    .PARAMETER DestinationPath
        The parent folder for all lab files. Default C:\AutolabVMware.
    .PARAMETER SkipNetworkSetup
        Skip the vmnet configuration step (configure the host-only network
        manually with the Virtual Network Editor instead).
    .EXAMPLE
        PS C:\> Setup-Host
        Prepares the host with all defaults.
    .EXAMPLE
        PS C:\> Setup-Host -DestinationPath D:\AutolabVMware -SkipNetworkSetup
        Uses an alternate folder and leaves vmnet configuration to the user.
    .LINK
        Invoke-SetupLab
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Alias('Setup-Host')]
    param(
        [Parameter(HelpMessage = 'Specify the parent path. The default is C:\AutolabVMware.')]
        [string]$DestinationPath = 'C:\AutolabVMware',

        [switch]$SkipNetworkSetup
    )

    Write-Verbose "Starting $($MyInvocation.MyCommand)"

    if (-not (Test-IsAdministrator)) {
        throw 'Setup-Host must be run from an elevated PowerShell session.'
    }

    Microsoft.PowerShell.Utility\Write-Host -ForegroundColor Green -Object @"

    This is the Setup-Host command for PSAutoLabVMware. It will:

    * Verify VMware Workstation Pro is installed
    * Configure PowerShell remoting and the host TrustedHosts value
    * Install/verify the Pester module
    * Create the $DestinationPath folder structure (DO NOT DELETE)
    * Configure the host-only lab network ($script:LabVMnet, 192.168.3.0/24)
    * Copy lab configurations to $DestinationPath\Configurations

"@

    Microsoft.PowerShell.Utility\Write-Host -ForegroundColor Yellow -Object @"

    !!IMPORTANT SECURITY NOTE!!

    This module will set TrustedHosts so the host can connect to lab VMs
    over WinRM by IP address. This is NOT a recommended security practice
    for production machines. It is assumed you are installing this module
    on a non-production machine and accept this risk for a lab environment.

    If you do not want to proceed, press Ctrl-C.
"@
    Pause

    # 1) VMware Workstation check
    $vmware = Get-VMwarePath
    Write-LabMessage -Message "Found VMware Workstation $($vmware.Version) at $($vmware.InstallPath)" -Color Green
    if ($vmware.Version -and ([version]($vmware.Version -replace '[^\d\.].*$', '')).Major -lt 17) {
        Write-Warning "VMware Workstation 17 or later is recommended. Detected version: $($vmware.Version). Generated VMX files target hardware version 21."
    }

    # 2) PowerShell remoting + TrustedHosts
    Write-LabMessage -Message 'Enabling PowerShell remoting on the host'
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Enable-PSRemoting')) {
        Enable-PSRemoting -Force -SkipNetworkProfileCheck
    }

    $trust = Get-Item -Path WSMan:\localhost\Client\TrustedHosts
    if (($trust.Value -eq '*') -or ($trust.Value -match '192\.168\.3\.\*')) {
        Write-LabMessage -Message 'TrustedHosts already includes the lab network. No changes needed.' -Color Green
    }
    else {
        $add = '192.168.3.*'
        Write-LabMessage -Message "Adding $add to TrustedHosts"
        if ($PSCmdlet.ShouldProcess('TrustedHosts', "Add $add")) {
            Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value $add -Concatenate -Force
        }
    }

    # 3) NuGet + Pester
    Write-Verbose 'Bootstrapping NuGet provider'
    [void](Install-PackageProvider -Name NuGet -ForceBootstrap -ErrorAction SilentlyContinue)
    Get-PackageSource -Name PSGallery -ErrorAction SilentlyContinue |
        Set-PackageSource -Trusted -Force -ForceBootstrap -ErrorAction SilentlyContinue | Out-Null

    $pester = Get-Module -Name Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pester -or $pester.Version -lt [version]$script:PesterVersion) {
        Write-LabMessage -Message "Installing Pester v$($script:PesterVersion)+" -Color Yellow
        if ($PSCmdlet.ShouldProcess('Pester', 'Install-Module')) {
            Install-Module -Name Pester -Force -SkipPublisherCheck
        }
    }
    else {
        Write-LabMessage -Message "Pester v$($pester.Version) verified" -Color Green
    }

    # 4) Folder structure
    Write-LabMessage -Message "Creating folder structure under $DestinationPath"
    # honor an alternate destination for this run
    if ($DestinationPath -ne $script:AutoLabRoot) {
        $script:AutoLabRoot = $DestinationPath
        $script:AutoLabFolders = @{
            ConfigurationPath = Join-Path $DestinationPath 'Configurations'
            VMPath            = Join-Path $DestinationPath 'VMs'
            IsoPath           = Join-Path $DestinationPath 'ISOs'
            UnattendIsoPath   = Join-Path $DestinationPath 'UnattendISOs'
            ResourcePath      = Join-Path $DestinationPath 'Resources'
            LogPath           = Join-Path $DestinationPath 'Logs'
        }
    }
    foreach ($folder in $script:AutoLabFolders.Values) {
        if (-not (Test-Path -Path $folder)) {
            if ($PSCmdlet.ShouldProcess($folder, 'Create directory')) {
                [void](New-Item -Path $folder -ItemType Directory -Force)
            }
        }
    }

    # 5) Lab virtual network
    if (-not $SkipNetworkSetup) {
        Write-LabMessage -Message "Configuring host-only lab network $script:LabVMnet (192.168.3.0/24, host at 192.168.3.1)"
        try {
            Set-LabVMnet
        }
        catch {
            Write-Warning "Automatic vmnet configuration failed: $($_.Exception.Message)"
            Write-Warning "Configure it manually: Edit > Virtual Network Editor > Add Network $script:LabVMnet > Host-only, subnet 192.168.3.0/255.255.255.0, DHCP disabled. Then set the host adapter IP to 192.168.3.1."
        }
    }

    # 6) Copy configurations
    Write-LabMessage -Message "Copying lab configurations to $($script:AutoLabFolders.ConfigurationPath)"
    if ($PSCmdlet.ShouldProcess($script:AutoLabFolders.ConfigurationPath, 'Copy configurations')) {
        Copy-Item -Path (Join-Path $script:ConfigurationPath '*') -Destination $script:AutoLabFolders.ConfigurationPath -Recurse -Force
    }

    Microsoft.PowerShell.Utility\Write-Host -ForegroundColor Green -Object @"

    Setup-Host is complete. Next steps:

    Open a Windows PowerShell prompt, navigate to a configuration folder:
    cd $($script:AutoLabFolders.ConfigurationPath)\<YourConfigFolder>

    And run:
    Setup-Lab
    or
    Unattend-Lab

"@
    Write-Verbose "Ending $($MyInvocation.MyCommand)"
}
