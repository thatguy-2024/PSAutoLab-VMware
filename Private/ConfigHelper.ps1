# ConfigHelper.ps1
# Adapter layer that parses the original PS-AutoLab-Env VMConfigurationData.psd1
# format and resolves it into VMware-ready node objects. Not exported.
#
# Field mapping (Lability/Hyper-V -> VMware Workstation):
#   NodeName                 -> guest computer name / VM folder name
#   IPAddress                -> static IPv4 pushed via autounattend.xml
#   Lability_SwitchName      -> host-only VMnet ($script:LabVMnet, default vmnet2)
#   Lability_Media           -> guestOS + install ISO (see MediaHelper.ps1)
#   Lability_ProcessorCount  -> numvcpus
#   Lability_MinimumMemory / MemoryStartupBytes -> memsize (MB)
#   Lability_BootOrder/BootDelay -> VM start ordering in Run-Lab
#   Lability_timeZone        -> autounattend.xml <TimeZone>
#   NonNodeData.Lability.EnvironmentPrefix -> VM display name prefix

function Import-LabConfiguration {
    <#
    .SYNOPSIS
        Parse a lab folder's VMConfigurationData.psd1 into a VMware-ready object.
    .DESCRIPTION
        Reads the configuration data file from the given lab configuration folder,
        merges the wildcard node (NodeName='*') defaults into each concrete node
        and maps every Lability_* setting onto its VMware equivalent. Returns a
        single object describing the lab: name, password, nodes, network settings,
        DSC resources and raw configuration data.
    .PARAMETER Path
        Path to the lab configuration folder (containing VMConfigurationData.psd1).
    .EXAMPLE
        PS C:\AutolabVMware\Configurations\MultiRole> Import-LabConfiguration -Path .
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path
    )

    $Path = Convert-Path -Path $Path
    $labName = Split-Path -Path $Path -Leaf

    $psd1 = Get-ChildItem -Path $Path -Filter *.psd1 | Select-Object -First 1
    if (-not $psd1) {
        throw "No VMConfigurationData.psd1 found in $Path. Run this command from a lab configuration folder."
    }

    $labData = Import-PowerShellDataFile -Path $psd1.FullName

    # wildcard defaults
    $defaults = $labData.AllNodes | Where-Object { $_.NodeName -eq '*' } | Select-Object -First 1
    if (-not $defaults) { $defaults = @{} }

    $prefix = $labData.NonNodeData.Lability.EnvironmentPrefix

    $nodes = foreach ($node in ($labData.AllNodes | Where-Object { $_.NodeName -ne '*' })) {

        # helper scriptblock: node value else wildcard default else fallback
        $pick = {
            param($key, $fallback)
            if ($node.ContainsKey($key) -and $null -ne $node[$key]) { $node[$key] }
            elseif ($defaults.ContainsKey($key) -and $null -ne $defaults[$key]) { $defaults[$key] }
            else { $fallback }
        }

        # memory: prefer MemoryStartupBytes, then Lability_StartupMemory, then minimum
        $memBytes = & $pick 'MemoryStartupBytes' $null
        if (-not $memBytes) { $memBytes = & $pick 'Lability_StartupMemory' $null }
        if (-not $memBytes) { $memBytes = & $pick 'Lability_MinimumMemory' 1GB }
        $memMB = [int]([int64]$memBytes / 1MB)

        $media = & $pick 'Lability_Media' '2016_x64_Standard_Core_EN_Eval'
        $mediaInfo = Get-LabMediaInfo -Id $media

        [PSCustomObject]@{
            PSTypeName     = 'PSAutoLabVMware.LabNode'
            Computername   = $node.NodeName
            VMName         = "$prefix$($node.NodeName)"
            Lab            = $labName
            IPAddress      = & $pick 'IPAddress' $null
            SubnetMask     = & $pick 'SubnetMask' 24
            DefaultGateway = & $pick 'DefaultGateway' $script:LabVMnetHostIP
            DnsServer      = & $pick 'DnsServerAddress' '4.2.2.2'
            InterfaceAlias = & $pick 'InterfaceAlias' 'Ethernet'
            Role           = @(& $pick 'Role' @())
            Media          = $media
            MediaInfo      = $mediaInfo
            GuestOS        = $mediaInfo.GuestOS
            MemoryMB       = $memMB
            Processors     = [int](& $pick 'Lability_ProcessorCount' 1)
            BootOrder      = [int](& $pick 'Lability_BootOrder' 99)
            BootDelay      = [int](& $pick 'Lability_BootDelay' 0)
            TimeZone       = & $pick 'Lability_timeZone' 'Pacific Standard Time'
            SecureBoot     = [bool](& $pick 'SecureBoot' $false)
            DomainName     = & $pick 'DomainName' $null
            VMnet          = $script:LabVMnet
            Description    = $mediaInfo.Description
        }
    }

    [PSCustomObject]@{
        PSTypeName   = 'PSAutoLabVMware.LabConfiguration'
        Name         = $labName
        Path         = $Path
        DataFile     = $psd1.FullName
        Password     = "$($labData.AllNodes.LabPassword | Select-Object -First 1)"
        Prefix       = $prefix
        Nodes        = @($nodes | Sort-Object BootOrder, Computername)
        DSCResources = @($labData.NonNodeData.Lability.DSCResource)
        IPNetwork    = ($labData.AllNodes | Where-Object { $_.IPNetwork }).IPNetwork | Select-Object -First 1
        IPNatName    = ($labData.AllNodes | Where-Object { $_.IPNatName }).IPNatName | Select-Object -First 1
        RawData      = $labData
    }
}

function Get-LabNodeCredential {
    <#
    .SYNOPSIS
        Build the PSCredential used to connect to a lab VM over WinRM.
    .DESCRIPTION
        For nodes holding the DC or DomainJoin role the domain Administrator
        credential (<Domain>\Administrator) is returned; for all other nodes the
        local Administrator credential is returned. The password comes from the
        lab's LabPassword setting (typically P@ssw0rd).
    .PARAMETER Node
        A node object produced by Import-LabConfiguration.
    .PARAMETER Password
        The lab password in plain text (from configuration data).
    .EXAMPLE
        PS C:\> Get-LabNodeCredential -Node $lab.Nodes[0] -Password $lab.Password
    #>
    [CmdletBinding()]
    [OutputType([PSCredential])]
    param(
        [Parameter(Mandatory)]
        [object]$Node,

        [Parameter(Mandatory)]
        [string]$Password
    )

    $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
    $roles = @($Node.Role) | ForEach-Object { "$_".ToLower() }

    if ($Node.DomainName -and (($roles -contains 'dc') -or ($roles -contains 'domainjoin'))) {
        $user = "$($Node.DomainName.Split('.')[0])\Administrator"
    }
    else {
        $user = "$($Node.Computername)\Administrator"
    }
    New-Object -TypeName PSCredential -ArgumentList $user, $secure
}

function Get-LabVMFolder {
    <#
    .SYNOPSIS
        Return (and optionally create) the per-VM folder for a lab node.
    .PARAMETER Node
        A node object produced by Import-LabConfiguration.
    .PARAMETER Create
        Create the folder if it does not exist.
    .EXAMPLE
        PS C:\> Get-LabVMFolder -Node $node -Create
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Node,
        [switch]$Create
    )

    $folder = Join-Path -Path $script:AutoLabFolders.VMPath -ChildPath $Node.VMName
    if ($Create -and -not (Test-Path -Path $folder)) {
        [void](New-Item -Path $folder -ItemType Directory -Force)
    }
    $folder
}

function Get-LabVMXPath {
    <#
    .SYNOPSIS
        Return the .vmx file path for a lab node.
    .PARAMETER Node
        A node object produced by Import-LabConfiguration.
    .EXAMPLE
        PS C:\> Get-LabVMXPath -Node $node
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Node
    )
    Join-Path -Path (Get-LabVMFolder -Node $Node) -ChildPath "$($Node.VMName).vmx"
}
