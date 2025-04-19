<#
This script compares two folders and identifies differences between files.

Requirements:
- dotnet-ildasm must be installed and accessible via PATH
　Install it with:
    dotnet tool install --global dotnet-ildasm

How it works:
- For .pdb, .cache, .log files: these are ignored and considered identical
- For .dll and .exe files: compares IL code using `dotnet-ildasm`
- For .ps1, .bat, .md, .txt, .json, .csproj, .sln, .cs, .config files: compares raw text content
- For all others: compares MD5 hashes

Outputs:
- A diff_report.txt in the same directory as the script
- Categorizes added, removed, and modified files

Useful for validating release differences in .NET-based deployments.
#>

param(
    [string]$Old = "C:\ModuleSet\Old",
    [string]$New = "C:\ModuleSet\New"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogPath = Join-Path $scriptDir "diff_report.txt"

# Write to both log file and console
# Appends text to the diff_report.txt file
function Write-Log {
    param([string]$text)
    $text | Out-File -Append -FilePath $LogPath -Encoding UTF8
    Write-Output $text
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
    switch ($extension.ToLower()) {

        # Ignored file types: always considered identical
        { @('.pdb', '.cache', '.log') -contains $_ } {
            return $true
        }

        # Text-based files: compare as raw text
        { @('.ps1', '.bat', '.md', '.txt', '.json', '.csproj', '.sln', '.cs', '.config') -contains $_ } {
            return (Get-Content $oldInfo.FullPath -Raw) -eq (Get-Content $newInfo.FullPath -Raw)
        }

        # .NET assemblies: compare via IL
        { @('.dll', '.exe') -contains $_ } {
            if (-not (Get-Command dotnet-ildasm -ErrorAction SilentlyContinue)) {
                Write-Warning "dotnet-ildasm is not installed or not in PATH. Treating files as different."
                return $false
            }

            $temp1 = [System.IO.Path]::GetTempFileName() + ".il"
            $temp2 = [System.IO.Path]::GetTempFileName() + ".il"
            try {
                & dotnet-ildasm $oldInfo.FullPath > $temp1
                & dotnet-ildasm $newInfo.FullPath > $temp2
                $same = (Get-Content $temp1 -Raw) -eq (Get-Content $temp2 -Raw)
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

            return $same
        }

        # Binary or unknown files: compare by cached MD5 hash
        default {
            return $oldInfo.Hash -eq $newInfo.Hash
        }
    }
}

# Main function: compares all files between two folders and generates a difference report
function Compare-Folders {
    param (
        [string]$oldPath,
        [string]$newPath,
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
            continue
        }

        if (Compare-FileContents $oldInfo $newInfo $ext) {
            $sameCount++
            continue
        } else {
            $modified += $key
        }

        $count++
        if ($count % $CompareProgressInterval -eq 0) {
            Write-Host "  Compared $count files... ($sameCount unchanged so far)"
        }
    }

    Write-Host "  Compared $count files total. ($sameCount unchanged so far)"

    Write-Log "`n[+] Added"
    foreach ($f in $onlyNew | Sort-Object) {
        Write-Log "  + $($newMap[$f].FullPath)"
    }

    Write-Log "`n[-] Removed"
    foreach ($f in $onlyOld | Sort-Object) {
        Write-Log "  - $($oldMap[$f].FullPath)"
    }

    Write-Log "`n[*] Modified"
    foreach ($f in $modified | Sort-Object) {
        Write-Log "  * $f"
    }

    Write-Log "`n[=] Summary"
    Write-Log "  Added   : $($onlyNew.Count)"
    Write-Log "  Removed : $($onlyOld.Count)"
    Write-Log "  Modified: $($modified.Count)"
    Write-Log "  Compared: $($oldMap.Count) (old) vs $($newMap.Count) (new)"
}

# Clean previous log
if (Test-Path $LogPath) { Remove-Item $LogPath }

try {
    Write-Host "Starting folder diff..."

    # Log header with timestamp and paths
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Folders Compared" | Out-File -FilePath $LogPath -Encoding UTF8
    "  Old: $Old" | Out-File -Append -FilePath $LogPath -Encoding UTF8
    "  New: $New" | Out-File -Append -FilePath $LogPath -Encoding UTF8

    Compare-Folders -oldPath $Old -newPath $New -FileHashProgressInterval 1000 -CompareProgressInterval 10

    Write-Host ""
    Write-Host "Report saved to: $LogPath"
} catch {
    Write-Host ""
    Write-Host "[Error] $_"
    "`n[Error] $_" | Out-File -FilePath $LogPath -Encoding UTF8 -Append
    exit 1
}