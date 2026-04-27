function Get-DiskUsage {
    <#
    .SYNOPSIS
        Interactive disk usage explorer, similar to ncdu.

    .DESCRIPTION
        Scans a path (or all drives if none given) and displays an interactive,
        navigable tree of folders and files sorted by size descending.

    .PARAMETER Path
        Root path to scan. If omitted, all local fixed drives are scanned.

    .PARAMETER MaxDepth
        How many directory levels deep to pre-scan. Default: unlimited (-1).

    .PARAMETER VerboseScan
        Print each directory path to the console as it is scanned.

    .EXAMPLE
        Get-DiskUsage
        Get-DiskUsage -Path C:\Users
        Get-DiskUsage -Path D:\ -MaxDepth 5
        Get-DiskUsage -Path C:\ -VerboseScan
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [int]$MaxDepth = -1,
        [switch]$VerboseScan
    )

    # --- Colour palette -------------------------------------------------------
    $Colors = @{
        Header     = 'Cyan'
        Selected   = 'Yellow'
        Dir        = 'Blue'
        File       = 'Gray'
        Size       = 'White'
        Help       = 'DarkCyan'
        Error      = 'Red'
        Breadcrumb = 'Magenta'
    }

    # --- Helper: human-readable size -----------------------------------------
    function Format-Size([long]$Bytes) {
        switch ($Bytes) {
            { $_ -ge 1TB } { return "{0,7:F2} TB" -f ($_ / 1TB) }
            { $_ -ge 1GB } { return "{0,7:F2} GB" -f ($_ / 1GB) }
            { $_ -ge 1MB } { return "{0,7:F2} MB" -f ($_ / 1MB) }
            { $_ -ge 1KB } { return "{0,7:F2} KB" -f ($_ / 1KB) }
            default        { return "{0,7:F2}  B" -f $_ }
        }
    }

    # --- Helper: draw a bar graphic ------------------------------------------
    function Get-Bar([long]$Size, [long]$Max, [int]$Width = 20) {
        if ($Max -eq 0) { return "[" + (" " * $Width) + "]" }
        $fill = [math]::Round(($Size / $Max) * $Width)
        $fill = [math]::Max(0, [math]::Min($fill, $Width))
        return "[" + ("#" * $fill) + ("-" * ($Width - $fill)) + "]"
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
                    # Shallow placeholder - scanned lazily when the user drills in
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

    # --- Helper: lazy-expand a node that has not been scanned yet ------------
    function Expand-Node([object]$Node) {
        if ($null -eq $Node.Children) {
            Write-Host ("`r  Scanning " + $Node.FullPath + "...") -NoNewline -ForegroundColor $Colors.Help
            $expanded    = Get-FolderSize -FolderPath $Node.FullPath -Depth 0 -MaxD 1 -Verbose $VerboseScan.IsPresent
            $Node.Children = $expanded.Children
            $Node.Size     = $expanded.Size
        }
    }

    # --- Helper: sort children by size descending ----------------------------
    function Get-SortedChildren([object]$Node) {
        return $Node.Children | Sort-Object Size -Descending
    }

    # --- Build root node -----------------------------------------------------
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
            Write-Host ("  Scanning " + $drv.Root + " ...") -ForegroundColor $Colors.Help
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
        Write-Host ("  Scanning " + $Path + " ...") -ForegroundColor $Colors.Help
        $scanRoot = Get-FolderSize -FolderPath (Resolve-Path $Path).Path -Depth 0 -MaxD $MaxDepth -Verbose $VerboseScan.IsPresent
    }

    # --- Interactive viewer --------------------------------------------------
    $stack     = [System.Collections.Stack]::new()
    $current   = $scanRoot
    $selected  = 0
    $scrollTop = 0
    $pageSize  = [System.Console]::WindowHeight - 9

    [System.Console]::CursorVisible = $false
    Clear-Host

    while ($true) {

        $items = @(Get-SortedChildren $current)
        $count = $items.Count

        # Clamp selection and scroll window
        if ($selected -ge $count)                   { $selected  = [math]::Max(0, $count - 1) }
        if ($selected -lt $scrollTop)               { $scrollTop = $selected }
        if ($selected -ge ($scrollTop + $pageSize)) { $scrollTop = $selected - $pageSize + 1 }

        [System.Console]::SetCursorPosition(0, 0)

        # -- Header -----------------------------------------------------------
        $divider = ("=" * [System.Console]::WindowWidth)
        Write-Host $divider -ForegroundColor $Colors.Header
        Write-Host " PSdu  --  Disk Usage Explorer" -ForegroundColor $Colors.Header

        # -- Breadcrumb -------------------------------------------------------
        $crumbParts = @()
        foreach ($s in ($stack.ToArray() | Select-Object -Last 4)) { $crumbParts += $s.Name }
        $crumbParts += $current.Name
        $bc = " Path: " + ($crumbParts -join " > ")
        $maxW = [System.Console]::WindowWidth - 2
        if ($bc.Length -gt $maxW) { $bc = " ..." + $bc.Substring($bc.Length - ($maxW - 4)) }
        Write-Host $bc -ForegroundColor $Colors.Breadcrumb

        # -- Stats line -------------------------------------------------------
        Write-Host (" Total: " + (Format-Size $current.Size).Trim() + "   Items: $count") `
            -ForegroundColor $Colors.Size
        Write-Host $divider -ForegroundColor $Colors.Header

        # -- Listing ----------------------------------------------------------
        $maxSz = if ($count -gt 0) { [math]::Max(1L, $items[0].Size) } else { 1L }
        $barW  = 20
        $nameW = [System.Console]::WindowWidth - $barW - 24

        $visEnd = [math]::Min($scrollTop + $pageSize, $count)
        for ($i = $scrollTop; $i -lt $visEnd; $i++) {
            $item = $items[$i]
            $icon = if ($item.IsDir) { "/" } else { " " }
            $name = $icon + $item.Name
            if ($name.Length -gt $nameW) { $name = $name.Substring(0, $nameW - 1) + "~" }
            $name = $name.PadRight($nameW)
            $sz   = Format-Size $item.Size
            $bar  = Get-Bar -Size $item.Size -Max $maxSz -Width $barW
            $tag  = if ($item.IsDir -and $null -eq $item.Children) { "?" } else { " " }
            $line = "  $name  $sz  $bar$tag"

            if ($i -eq $selected) {
                Write-Host $line -ForegroundColor $Colors.Selected -BackgroundColor DarkGray
            }
            elseif ($item.IsDir) {
                Write-Host $line -ForegroundColor $Colors.Dir
            }
            else {
                Write-Host $line -ForegroundColor $Colors.File
            }
        }

        # Blank remaining rows so old content does not bleed through
        for ($p = ($visEnd - $scrollTop); $p -lt $pageSize; $p++) {
            Write-Host ("".PadRight([System.Console]::WindowWidth))
        }

        # -- Footer -----------------------------------------------------------
        Write-Host $divider -ForegroundColor $Colors.Header
        Write-Host "  [Up/Dn] Navigate  [Enter/Right] Open  [Bksp/Left] Back  [d] Delete  [c] Clear contents  [q] Quit" `
            -ForegroundColor $Colors.Help

        # -- Read keystroke ---------------------------------------------------
        $key = [System.Console]::ReadKey($true)

        switch ($key.Key) {

            'UpArrow' {
                if ($selected -gt 0) { $selected-- }
            }

            'DownArrow' {
                if ($selected -lt ($count - 1)) { $selected++ }
            }

            { $_ -in 'Enter', 'RightArrow' } {
                if ($count -gt 0) {
                    $target = $items[$selected]
                    if ($target.IsDir) {
                        Expand-Node $target
                        $stack.Push($current)
                        $current   = $target
                        $selected  = 0
                        $scrollTop = 0
                    }
                }
            }

            { $_ -in 'Backspace', 'LeftArrow' } {
                if ($stack.Count -gt 0) {
                    $current   = $stack.Pop()
                    $selected  = 0
                    $scrollTop = 0
                }
            }

            'D' {
                if ($count -gt 0) {
                    $target = $items[$selected]
                    [System.Console]::SetCursorPosition(0, [System.Console]::WindowHeight - 2)
                    Write-Host ("  DELETE '" + $target.FullPath + "'? PERMANENT. Type YES to confirm: ") `
                        -ForegroundColor $Colors.Error -NoNewline
                    [System.Console]::CursorVisible = $true
                    $confirm = Read-Host
                    [System.Console]::CursorVisible = $false
                    if ($confirm -eq 'YES') {
                        try {
                            Remove-Item -LiteralPath $target.FullPath -Recurse -Force -ErrorAction Stop
                            $current.Children.Remove($target) | Out-Null
                            $current.Size -= $target.Size
                            foreach ($ancestor in $stack) { $ancestor.Size -= $target.Size }
                            if ($selected -ge $current.Children.Count) { $selected-- }
                        }
                        catch {
                            Write-Host ("  ERROR: " + $_) -ForegroundColor $Colors.Error
                            Start-Sleep -Seconds 2
                        }
                    }
                }
            }

            'C' {
                if ($count -gt 0) {
                    $target = $items[$selected]
                    if ($target.IsDir) {
                        [System.Console]::SetCursorPosition(0, [System.Console]::WindowHeight - 2)
                        Write-Host ("  CLEAR CONTENTS of '" + $target.FullPath + "'? Folder kept. Type YES to confirm: ") `
                            -ForegroundColor $Colors.Error -NoNewline
                        [System.Console]::CursorVisible = $true
                        $confirm = Read-Host
                        [System.Console]::CursorVisible = $false
                        if ($confirm -eq 'YES') {
                            try {
                                $children = Get-ChildItem -LiteralPath $target.FullPath -Force -ErrorAction Stop
                                foreach ($child in $children) {
                                    Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
                                }
                                # Reset node so it re-scans as empty
                                $target.Children = [System.Collections.Generic.List[object]]::new()
                                $sizeFreed = $target.Size
                                $target.Size = 0L
                                $current.Size -= $sizeFreed
                                foreach ($ancestor in $stack) { $ancestor.Size -= $sizeFreed }
                            }
                            catch {
                                Write-Host ("  ERROR: " + $_) -ForegroundColor $Colors.Error
                                Start-Sleep -Seconds 2
                            }
                        }
                    }
                }
            }

            'Q' {
                [System.Console]::CursorVisible = $true
                Clear-Host
                Write-Host "  Exited PSdu." -ForegroundColor $Colors.Help
                return
            }
        }
    }
}
