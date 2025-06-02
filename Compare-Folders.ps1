<#
This script compares two folders and identifies differences between files.

Requirements:
- dotnet-ildasm must be installed and accessible via PATH
　Install it with:
    dotnet tool install --global dotnet-ildasm

How it works:
- For .pdb, .cache, .log files: these are ignored and considered identical
- For .dll and .exe files: compares IL code using `dotnet-ildasm`
- For .ps1, .bat, .md, .txt, .yml, .json, .csproj, .sln, .cs, .config files: compares raw text content
- For all others: compares MD5 hashes

Outputs:
- A diff_report.md in the same directory as the script
- Categorizes added, removed, and modified files

Useful for validating release differences in .NET-based deployments.
#>

param(
    [string]$Old = "C:\ModuleSet\Old",
    [string]$New = "C:\ModuleSet\New",
    [bool]$IncludeSame = $false,
    [bool]$ShowDetailedDiff = $false
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogPath = Join-Path $scriptDir "diff_report.md"

# Write to both log file and console
# Appends text to the diff_report.md file
function Write-Log {
    param([string]$text)
    $text | Out-File -Append -FilePath $LogPath -Encoding UTF8
    Write-Output $text
}

# Returns a Markdown-formatted diff between two line arrays using LCS.
# Unchanged lines start with ' ', deletions with '-', and additions with '+'.
function Compare-IL($lines1, $lines2) {
    $indent = '    '
    Write-Host ("{0}Performing intermediate language comparison..." -f $indent)
    $output = @('{0}<details> <summary>View intermediate language diff</summary>' -f $indent)
    $output += ''
    $output += '{0}``` diff' -f $indent
    
    $m = $lines1.Count
    $n = $lines2.Count

    # Create LCS table
    $dp = @()
    for ($i = 0; $i -le $m; $i++) {
        $dp += ,(@(0) * ($n + 1))
    }

    for ($i = 1; $i -le $m; $i++) {
        if ($i % 100 -eq 0) {
            Write-Host ("{0}Processing row $i of $m in LCS table..." -f $indent)
        }
        for ($j = 1; $j -le $n; $j++) {
            if ($lines1[$i - 1] -eq $lines2[$j - 1]) {
                $dp[$i][$j] = $dp[$i - 1][$j - 1] + 1
            } else {
                $dp[$i][$j] = [Math]::Max($dp[$i - 1][$j], $dp[$i][$j - 1])
            }
        }
    }

    # Trace back differences
    Write-Host ("{0}Tracing back differences..." -f $indent)
    $i = $m
    $j = $n
    $actions = New-Object System.Collections.Generic.List[string]
    while ($i -gt 0 -or $j -gt 0) {
        if ($step % 100 -eq 0) {
            Write-Host ("{0}Tracing step $step... (i=$i, j=$j)" -f $indent)
        }
        if ($i -gt 0 -and $j -gt 0 -and $lines1[$i - 1] -ceq $lines2[$j - 1]) {
            $actions.Add("$indent  {0}" -f $lines1[$i - 1])
            $i--; $j--
        }
        elseif ($j -gt 0 -and ($i -eq 0 -or $dp[$i][$j - 1] -ge $dp[$i - 1][$j])) {
            $actions.Add("$indent+ {0}" -f $lines2[$j - 1])
            $j--
        }
        else {
            $actions.Add("$indent- {0}" -f $lines1[$i - 1])
            $i--
        }
    }

    Write-Host ("{0}Assembling final diff output..." -f $indent)

    $actions = $actions.ToArray()
    for ($k = $actions.Count - 1; $k -ge 0; $k--) {
        $output += $actions[$k]
    }

    $output += '{0}```' -f $indent
    $output += '{0}</details>' -f $indent
    return $output -join "`n"
}

# Check if folder exists, is a directory, and can be read
function Confirm-Folder {
    param ([string]$path)
    if (-Not (Test-Path $path)) {
        throw "Folder not found: $path"
    }
    if (-Not (Get-Item $path).PSIsContainer) {
        throw "Not a folder: $path"
    }
    try {
        Get-ChildItem -Path $path -Recurse -File -ErrorAction Stop | Out-Null
    } catch {
        throw "Access denied or unreadable: $path"
    }
}

# Get relative file paths and their MD5 hashes from the given folder
function Get-FileHashes {
    param (
        [string]$basePath,
        [int]$FileHashProgressInterval = 1000
    )
    $map = @{}
    Write-Host "Scanning: $basePath"

    $files = Get-ChildItem -Path $basePath -Recurse -File
    $count = 0

    foreach ($file in $files) {
        $relPath = $file.FullName.Substring($basePath.Length).TrimStart('\')
        $hash = Get-FileHash -Path $file.FullName -Algorithm MD5
        $map[$relPath] = @{ Hash = $hash.Hash; FullPath = $file.FullName }

        $count++
        if ($count % $FileHashProgressInterval -eq 0) {
            Write-Host "  Scanned $count files..."
        }
    }

    Write-Host "  Scanned $count files total."
    return $map
}

# Compare two folders and log added, removed, and modified files
# Compares two files based on their extension
# Uses IL disassembly, text, or hash comparison depending on file type
function Compare-FileContents {
    param (
        [object]$oldInfo,
        [object]$newInfo,
        [string]$extension
    )
    $diffText = ""
    switch ($extension.ToLower()) {

        # Ignored file types: always considered identical
        { @('.pdb', '.cache', '.log') -contains $_ } {
            return @{ Same = $true; Diff = "" }
        }

        # Text-based files: compare as raw text
        { @('.ps1', '.bat', '.md', '.txt', '.yml', '.json', '.csproj', '.sln', '.cs', '.config') -contains $_ } {
            return @{ Same = (Get-Content $oldInfo.FullPath -Raw) -eq (Get-Content $newInfo.FullPath -Raw); Diff = "" }
        }

        # .NET assemblies: compare via IL
        { @('.dll', '.exe') -contains $_ } {
            if (-not (Get-Command dotnet-ildasm -ErrorAction SilentlyContinue)) {
                Write-Warning "dotnet-ildasm is not installed or not in PATH. Treating files as different."
                return @{ Same = $false; Diff = "" }
            }
            $temp1 = [System.IO.Path]::GetTempFileName() + ".il"
            $temp2 = [System.IO.Path]::GetTempFileName() + ".il"
            try {
                & dotnet-ildasm $oldInfo.FullPath | Out-File -FilePath $temp1 -Encoding UTF8 -Force
                & dotnet-ildasm $newInfo.FullPath | Out-File -FilePath $temp2 -Encoding UTF8 -Force

                $il1Lines = Get-Content $temp1 | Where-Object {
                    ($_ -notmatch "^// MVID:")
                }

                $il2Lines = Get-Content $temp2 | Where-Object {
                    ($_ -notmatch "^// MVID:")
                }

                $same = ($il1Lines -join "`n") -eq ($il2Lines -join "`n")

                if ($ShowDetailedDiff -and -not $same) {
                    Write-Host "   $($oldInfo.FullPath) vs $($newInfo.FullPath)"
                    $diffText = Compare-IL $il1Lines $il2Lines
                }
            } catch {
                if ($_ -match 'access is denied|cannot disassemble|disassembly of global methods is not allowed') {
                    Write-Warning "Cannot disassemble '$($oldInfo.FullPath)' or '$($newInfo.FullPath)'. SuppressIldasm may be applied."
                } else {
                    Write-Warning "Error running dotnet-ildasm: $_"
                }
                $same = $false
            } finally {
                Remove-Item $temp1, $temp2 -ErrorAction SilentlyContinue
            }

            return @{ Same = $same; Diff = $diffText }
        }

        # Binary or unknown files: compare by cached MD5 hash
        default {
            $same = $oldInfo.Hash -eq $newInfo.Hash
            return @{ Same = $same; Diff = "" }
        }
    }
}

# Main function: compares all files between two folders and generates a difference report
function Compare-Folders {
    param (
        [string]$oldPath,
        [string]$newPath,
        [bool]$IncludeSame = $false,
        [int]$FileHashProgressInterval = 1000,
        [int]$CompareProgressInterval = 10
    )
    Confirm-Folder $oldPath
    Confirm-Folder $newPath

    $oldMap = Get-FileHashes $oldPath $FileHashProgressInterval
    $newMap = Get-FileHashes $newPath $FileHashProgressInterval

    $onlyNew = @()
    $onlyOld = @()
    $common = @()

    foreach ($key in $newMap.Keys) {
        if (-not $oldMap.ContainsKey($key)) {
            $onlyNew += $key
        } else {
            $common += $key
        }
    }

    foreach ($key in $oldMap.Keys) {
        if (-not $newMap.ContainsKey($key)) {
            $onlyOld += $key
        }
    }

    # Progress-aware comparison
    $modified = @()
    $unchanged = @()
    $count = 0
    $sameCount = 0

    Write-Host "Comparing files ($($common.Count) candidates)..."

    foreach ($key in $common) {
        $ext = [System.IO.Path]::GetExtension($key)
        $oldInfo = $oldMap[$key]
        $newInfo = $newMap[$key]

        # Skip full comparison if hashes already match
        if ($oldInfo.Hash -eq $newInfo.Hash) {
            $sameCount++
            if ($IncludeSame) { $unchanged += $key }
            continue
        }

        $result = Compare-FileContents $oldInfo $newInfo $ext
        if ($result.Same) {
            $sameCount++
            if ($IncludeSame) { $unchanged += $key }
            continue
        } else {
            $modified += @{ Key = $key; Diff = $result.Diff }
        }

        $count++
        if ($count % $CompareProgressInterval -eq 0) {
            Write-Host "  Compared $count files... ($sameCount unchanged so far)"
        }
    }

    Write-Host "  Compared $count files total. ($sameCount unchanged so far)"

    Write-Log ""
    if ($IncludeSame) {
        Write-Log "## [ = ] Unchanged Files"
        foreach ($f in $unchanged | Sort-Object) {
            Write-Log "- [ = ] $f"
        }
        Write-Log ""
    }

    Write-Log "## [ + ] Added Files"
    foreach ($f in $onlyNew | Sort-Object) {
        Write-Log "- [ + ] $($newMap[$f].FullPath)"
    }
    Write-Log ""

    Write-Log "## [ - ] Removed Files"
    foreach ($f in $onlyOld | Sort-Object) {
        Write-Log "- [ - ] $($oldMap[$f].FullPath)"
    }
    Write-Log ""

    Write-Log "## [ * ] Modified Files"
    foreach ($item in $modified | Sort-Object Key) {
        Write-Log "- [ * ] $($item.Key)"
        # Output if not an empty string or $null
        if ($ShowDetailedDiff -and $item.Diff) {
            Write-Log ($item.Diff)
        }
    }
    Write-Log ""

    Write-Log "`## Summary"
    if ($IncludeSame) { Write-Log "- Unchanged: $($unchanged.Count)" }
    Write-Log "- Added    : $($onlyNew.Count)"
    Write-Log "- Removed  : $($onlyOld.Count)"
    Write-Log "- Modified : $($modified.Count)"
    Write-Log "- Compared : $($oldMap.Count) (old) vs $($newMap.Count) (new)"
}

# Clean previous log
if (Test-Path $LogPath) { Remove-Item $LogPath }

try {
    Write-Host "Starting folder diff..."

    # Log header with timestamp and paths
    "# Folder Diff Report [$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]" | Out-File -FilePath $LogPath -Encoding UTF8
    "- Old: $Old" | Out-File -Append -FilePath $LogPath -Encoding UTF8
    "- New: $New" | Out-File -Append -FilePath $LogPath -Encoding UTF8

    Compare-Folders -oldPath $Old -newPath $New -IncludeSame $IncludeSame -FileHashProgressInterval 1000 -CompareProgressInterval 10

    Write-Host ""
    Write-Host "Report saved to: $LogPath"
} catch {
    Write-Host ""
    Write-Host "[Error] $_"
    "`n[Error] $_" | Out-File -FilePath $LogPath -Encoding UTF8 -Append
    exit 1
}