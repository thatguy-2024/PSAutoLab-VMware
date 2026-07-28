<#
    PSAutoLabVMware validation test — Pester v4 AND v5 compatible.

    Connects to each lab VM over WinRM (static IP from VMConfigurationData.psd1)
    and validates: WinRM reachability, computer name, static IP, DNS server,
    OS version, domain membership (if applicable), DSC state.
#>
#requires -version 5.1

# ---------------------------------------------------------------------------
# Build node list from VMConfigurationData.psd1 in this folder.
# This top-level block runs in both Pester v4 and v5.
# ---------------------------------------------------------------------------
$_dataFile = Join-Path -Path $PSScriptRoot -ChildPath 'VMConfigurationData.psd1'
$_labData  = Import-PowerShellDataFile -Path $_dataFile
$_allNodes = @($_labData.AllNodes)
$_default  = $_allNodes | Where-Object { $_.NodeName -eq '*' } | Select-Object -First 1
if (-not $_default) { $_default = @{} }

$script:TestNodes = [System.Collections.Generic.List[object]]::new()
foreach ($n in ($_allNodes | Where-Object { $_.NodeName -ne '*' })) {
    $pick = {
        param($key, $fallback)
        if ($n.ContainsKey($key))          { return $n[$key] }
        if ($_default.ContainsKey($key))   { return $_default[$key] }
        return $fallback
    }
    $script:TestNodes.Add([pscustomobject]@{
        Computername = $n.NodeName
        IPAddress    = & $pick 'IPAddress'       $null
        DnsServer    = & $pick 'DnsServerAddress' (& $pick 'IPAddress' $null)
        Role         = @(& $pick 'Role'          @())
        Media        = & $pick 'Lability_Media'  '2022_Core'
        DomainName   = & $pick 'DomainName'      'Company.pri'
        Password     = & $pick 'LabPassword'     'P@ssw0rd'
    })
}

# ---------------------------------------------------------------------------
# Helper: open a WinRM session to a node (domain cred first, local fallback)
# ---------------------------------------------------------------------------
function Connect-LabNode {
    param([pscustomobject]$Node)
    $secure = ConvertTo-SecureString -String $Node.Password -AsPlainText -Force
    $isDC     = $Node.Role -contains 'DC'
    $isDomain = $Node.Role -contains 'DomainJoin'
    if ($isDC -or $isDomain) {
        $nb   = ($Node.DomainName -split '\.')[0]
        $user = "$nb\Administrator"
    } else {
        $user = ".\Administrator"
    }
    $cred = [pscredential]::new($user, $secure)
    $localCred = [pscredential]::new(".\Administrator", $secure)
    try   { return New-PSSession -ComputerName $Node.IPAddress -Credential $cred      -Authentication Negotiate -ErrorAction Stop }
    catch { }
    try   { return New-PSSession -ComputerName $Node.IPAddress -Credential $localCred -Authentication Negotiate -ErrorAction SilentlyContinue }
    catch { }
    return $null
}

# ---------------------------------------------------------------------------
# Helper: expected OS caption fragment from media ID
# ---------------------------------------------------------------------------
function Get-ExpectedOS {
    param([string]$Media)
    switch -Wildcard ($Media) {
        '2016*'  { return 'Server 2016' }
        '2019*'  { return 'Server 2019' }
        '2022*'  { return 'Server 2022' }
        'WIN10*' { return 'Windows 10'  }
        'WIN11*' { return 'Windows 11'  }
        default  { return 'Windows'     }
    }
}

# ---------------------------------------------------------------------------
# Tests — one Describe per node, written in plain Pester v4/v5 syntax
# (no BeforeDiscovery, no -ForEach on Describe)
# ---------------------------------------------------------------------------
foreach ($testNode in $script:TestNodes) {

    Describe "Lab VM $($testNode.Computername)" {

        BeforeAll {
            $script:node    = $testNode
            $script:session = Connect-LabNode -Node $testNode
            $script:osMatch = Get-ExpectedOS -Media $testNode.Media
        }

        AfterAll {
            if ($script:session) {
                Remove-PSSession -Session $script:session -ErrorAction SilentlyContinue
            }
        }

        It "Accepts a WinRM connection at $($testNode.IPAddress)" {
            $script:session            | Should -Not -BeNullOrEmpty
            $script:session.State      | Should -Be 'Opened'
        }

        It 'Has the expected computer name' {
            $name = Invoke-Command -Session $script:session -ScriptBlock { $env:COMPUTERNAME }
            $name | Should -Be $script:node.Computername
        }

        It 'Has the expected static IP address' {
            $ips = Invoke-Command -Session $script:session -ScriptBlock {
                (Get-NetIPAddress -AddressFamily IPv4).IPAddress
            }
            $ips | Should -Contain $script:node.IPAddress
        }

        It 'Uses the expected DNS server' {
            $dns = Invoke-Command -Session $script:session -ScriptBlock {
                (Get-DnsClientServerAddress -AddressFamily IPv4 |
                    Where-Object { $_.ServerAddresses } |
                    Select-Object -First 1).ServerAddresses
            }
            $dns | Should -Contain $script:node.DnsServer
        }

        It 'Is running the expected operating system' {
            $caption = Invoke-Command -Session $script:session -ScriptBlock {
                (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
            }
            $caption | Should -BeLike "*$script:osMatch*"
        }

        $skipDomain = -not (($testNode.Role -contains 'DC') -or ($testNode.Role -contains 'DomainJoin'))
        It 'Is joined to the lab domain' -Skip:$skipDomain {
            $cs = Invoke-Command -Session $script:session -ScriptBlock {
                Get-CimInstance -ClassName Win32_ComputerSystem
            }
            $cs.PartOfDomain | Should -BeTrue
            $cs.Domain       | Should -Be $script:node.DomainName
        }

        $skipADWS = -not ($testNode.Role -contains 'DC')
        It 'Is running Active Directory Web Services' -Skip:$skipADWS {
            $svc = Invoke-Command -Session $script:session -ScriptBlock {
                Get-Service -Name ADWS -ErrorAction SilentlyContinue
            }
            $svc.Status | Should -Be 'Running'
        }

        It 'Has completed the DSC configuration without pending reboots' {
            $lcm = Invoke-Command -Session $script:session -ScriptBlock {
                Get-DscLocalConfigurationManager
            }
            $lcm.LCMState | Should -Not -Be 'PendingReboot'
        }
    }
}
