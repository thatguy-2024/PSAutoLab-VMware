# Syntax-validate every .ps1/.psm1/.psd1 in the module using the PowerShell AST parser
$root = '/home/ubuntu/PSAutoLabVMware'
# NOTE: VMConfiguration.ps1 files are the original, unmodified PS-AutoLab-Env DSC
# configuration scripts (verified byte-identical to upstream). They use the DSC
# 'configuration' keyword which the PowerShell parser can only resolve on systems
# with a DSC schema store (Windows PS 5.1), so they are excluded from parsing here.
$files = Get-ChildItem -Path $root -Recurse -Include *.ps1, *.psm1, *.psd1 |
    Where-Object { $_.Name -notlike '*.hyperv' -and $_.Name -ne 'VMConfiguration.ps1' }
$failed = 0
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $failed++
        Write-Host "FAIL: $($f.FullName)" -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host ("  [{0},{1}] {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message)
        }
    }
}
Write-Host "Checked $($files.Count) files, $failed failed."

# Additionally verify the module manifest is loadable data
try {
    $m = Import-PowerShellDataFile -Path (Join-Path $root 'PSAutoLabVMware.psd1')
    Write-Host "Manifest OK: version $($m.ModuleVersion), $(@($m.FunctionsToExport).Count) functions, $(@($m.AliasesToExport).Count) aliases"
} catch {
    Write-Host "Manifest FAILED: $_" -ForegroundColor Red
    $failed++
}

# Verify every configuration psd1 parses as data
Get-ChildItem "$root/Configurations" -Directory | ForEach-Object {
    $psd1 = Join-Path $_.FullName 'VMConfigurationData.psd1'
    try {
        $d = Import-PowerShellDataFile -Path $psd1
        $n = @($d.AllNodes | Where-Object { $_.NodeName -ne '*' }).Count
        Write-Host ("Config OK: {0} ({1} nodes)" -f $_.Name, $n)
    } catch {
        Write-Host "Config FAILED: $($_.Name): $_" -ForegroundColor Red
        $failed++
    }
}

if ($failed -gt 0) { exit 1 } else { exit 0 }
