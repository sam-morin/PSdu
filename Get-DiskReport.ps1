function Get-DiskReport {
    <#
    .SYNOPSIS
        Non-interactive disk usage report, suitable for pasting into tickets or logs.

    .DESCRIPTION
        Scans a path (or all fixed drives if none given) and prints a sorted,
        tree-style report of folder/file sizes to the console. Output can be
        captured, copied, or redirected to a file.

    .PARAMETER Path
        Root path to scan. If omitted, all local fixed drives are scanned.

    .PARAMETER MaxDepth
        How many levels deep to display in the report. Default: 3.

    .PARAMETER MinSizeMB
        Skip items smaller than this many MB in the output. Default: 1.

    .PARAMETER VerboseScan
        Print each directory as it is scanned.

    .PARAMETER OutFile
        If specified, writes the report to this file path in addition to stdout.

    .EXAMPLE
        Get-DiskReport
        Get-DiskReport -Path C:\Users
        Get-DiskReport -Path C:\ -MaxDepth 4 -MinSizeMB 50
        Get-DiskReport -Path C:\ -OutFile C:\Temp\report.txt
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [int]$MaxDepth   = 3,
        [double]$MinSizeMB = 1,
        [switch]$VerboseScan,
        [string]$OutFile
    )

    # --- Helper: human-readable size -----------------------------------------
    function Format-Size([long]$Bytes) {
        switch ($Bytes) {
            { $_ -ge 1TB } { return "{0,8:F2} TB" -f ($_ / 1TB) }
            { $_ -ge 1GB } { return "{0,8:F2} GB" -f ($_ / 1GB) }
            { $_ -ge 1MB } { return "{0,8:F2} MB" -f ($_ / 1MB) }
            { $_ -ge 1KB } { return "{0,8:F2} KB" -f ($_ / 1KB) }
            default        { return "{0,8:F2}  B" -f $_ }
        }
    }

    # --- Helper: recursive size scanner --------------------------------------
    function Get-FolderSize([string]$FolderPath, [int]$Depth, [int]$MaxD, [bool]$Verbose = $false) {
        $node = [PSCustomObject]@{
            Name     = Split-Path $FolderPath -Leaf
            FullPath = $FolderPath
            Size     = 0L
            IsDir    = $true
            Children = [System.Collections.Generic.List[object]]::new()
            Error    = $false
        }

        try {
            if ($Verbose) {
                Write-Host ("  [scan] " + $FolderPath) -ForegroundColor DarkGray
            }

            $files = Get-ChildItem -LiteralPath $FolderPath -File -Force -ErrorAction Stop
            foreach ($f in $files) {
                $fileNode = [PSCustomObject]@{
                    Name     = $f.Name
                    FullPath = $f.FullName
                    Size     = $f.Length
                    IsDir    = $false
                    Children = $null
                    Error    = $false
                }
                $node.Children.Add($fileNode)
                $node.Size += $f.Length
            }

            $dirs = Get-ChildItem -LiteralPath $FolderPath -Directory -Force -ErrorAction Stop
            foreach ($d in $dirs) {
                if ($MaxD -eq -1 -or $Depth -lt $MaxD) {
                    $child = Get-FolderSize -FolderPath $d.FullName -Depth ($Depth + 1) -MaxD $MaxD -Verbose $Verbose
                } else {
                    $child = [PSCustomObject]@{
                        Name     = $d.Name
                        FullPath = $d.FullName
                        Size     = 0L
                        IsDir    = $true
                        Children = $null
                        Error    = $false
                    }
                }
                $node.Children.Add($child)
                $node.Size += $child.Size
            }
        }
        catch {
            $node.Error = $true
        }

        return $node
    }

    # --- Helper: render tree into a string list ------------------------------
    function Write-Tree {
        param(
            [object]$Node,
            [string]$Prefix     = '',
            [bool]  $IsLast     = $true,
            [int]   $Depth      = 0,
            [int]   $MaxD       = 3,
            [long]  $MinBytes   = 0,
            [long]  $RootSize   = 1L,
            [System.Collections.Generic.List[string]]$Lines
        )

        $connector = if ($IsLast) { '+-- ' } else { '+-- ' }
        $childPfx  = if ($IsLast) { $Prefix + '    ' } else { $Prefix + '|   ' }

        $icon     = if ($Node.IsDir) { '[D]' } else { '[F]' }
        $sz       = Format-Size $Node.Size
        $pct      = if ($RootSize -gt 0) { "{0,5:F1}%" -f (($Node.Size / $RootSize) * 100) } else { "  0.0%" }
        $errFlag  = if ($Node.Error) { ' [ERR]' } else { '' }
        $unscan   = if ($Node.IsDir -and $null -eq $Node.Children) { ' [?]' } else { '' }

        $Lines.Add($Prefix + $connector + $icon + " " + $sz + "  " + $pct + "  " + $Node.Name + $errFlag + $unscan)

        if ($null -ne $Node.Children -and $Depth -lt $MaxD) {
            $sorted = $Node.Children | Sort-Object Size -Descending |
                      Where-Object { $_.Size -ge $MinBytes }
            $total  = @($sorted).Count
            for ($i = 0; $i -lt $total; $i++) {
                $last = ($i -eq $total - 1)
                Write-Tree -Node $sorted[$i] -Prefix $childPfx -IsLast $last `
                           -Depth ($Depth + 1) -MaxD $MaxD -MinBytes $MinBytes `
                           -RootSize $RootSize -Lines $Lines
            }
        }
    }

    # --- Scan ----------------------------------------------------------------
    $minBytes = [long]($MinSizeMB * 1MB)
    $scanRoot = $null

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $drives = Get-PSDrive -PSProvider FileSystem |
                  Where-Object { $_.Root -and (Test-Path $_.Root) }
        $scanRoot = [PSCustomObject]@{
            Name     = 'This PC'
            FullPath = ''
            Size     = 0L
            IsDir    = $true
            Children = [System.Collections.Generic.List[object]]::new()
            Error    = $false
        }
        foreach ($drv in $drives) {
            Write-Host ("  Scanning " + $drv.Root + " ...") -ForegroundColor DarkCyan
            $driveNode      = Get-FolderSize -FolderPath $drv.Root -Depth 0 -MaxD $MaxDepth -Verbose $VerboseScan.IsPresent
            $driveNode.Name = $drv.Name + ":\"
            $scanRoot.Children.Add($driveNode)
            $scanRoot.Size += $driveNode.Size
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Error "Path not found: $Path"
            return
        }
        Write-Host ("  Scanning " + $Path + " ...") -ForegroundColor DarkCyan
        $scanRoot = Get-FolderSize -FolderPath (Resolve-Path $Path).Path -Depth 0 -MaxD $MaxDepth -Verbose $VerboseScan.IsPresent
    }

    # --- Build report lines --------------------------------------------------
    $lines = [System.Collections.Generic.List[string]]::new()

    $stamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $host_name = $env:COMPUTERNAME
    $scanPath  = if ([string]::IsNullOrWhiteSpace($Path)) { 'All Drives' } else { (Resolve-Path $Path).Path }

    $lines.Add("")
    $lines.Add("====================================================================")
    $lines.Add("  Disk Usage Report")
    $lines.Add("  Host      : " + $host_name)
    $lines.Add("  Scan Path : " + $scanPath)
    $lines.Add("  Generated : " + $stamp)
    $lines.Add("  Min Size  : " + $MinSizeMB + " MB  |  Max Depth: " + $MaxDepth)
    $lines.Add("====================================================================")
    $lines.Add("")
    $lines.Add("  Legend:  [D] Directory   [F] File   [?] Not fully scanned   [ERR] Access denied")
    $lines.Add("  Columns: Size   % of root   Name")
    $lines.Add("")
    $lines.Add("+-- [D] " + (Format-Size $scanRoot.Size).Trim() + "  100.0%  " + $scanRoot.Name)

    if ($null -ne $scanRoot.Children) {
        $sorted = $scanRoot.Children | Sort-Object Size -Descending |
                  Where-Object { $_.Size -ge $minBytes }
        $total  = @($sorted).Count
        for ($i = 0; $i -lt $total; $i++) {
            $last = ($i -eq $total - 1)
            Write-Tree -Node $sorted[$i] -Prefix '' -IsLast $last `
                       -Depth 1 -MaxD $MaxDepth -MinBytes $minBytes `
                       -RootSize $scanRoot.Size -Lines $lines
        }
    }

    $lines.Add("")
    $lines.Add("====================================================================")
    $lines.Add("  Total: " + (Format-Size $scanRoot.Size).Trim() + "  |  Report end")
    $lines.Add("====================================================================")
    $lines.Add("")

    # --- Output --------------------------------------------------------------
    $report = $lines -join "`r`n"
    Write-Output $report

    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        try {
            $report | Out-File -FilePath $OutFile -Encoding utf8 -Force
            Write-Host ("  Report saved to: " + $OutFile) -ForegroundColor DarkCyan
        }
        catch {
            Write-Host ("  ERROR saving file: " + $_) -ForegroundColor Red
        }
    }
}
