function Get-DiskUsage {
    <#
    .SYNOPSIS
        Interactive disk usage explorer, similar to ncdu.

    .DESCRIPTION
        Scans a path (or all drives if none given) and displays an interactive,
        navigable tree of folders and files sorted by size descending.

        The first level appears instantly via Get-ChildItem. Every subdirectory
        is then scanned in parallel background runspaces using fast .NET
        enumeration. Sizes fill in live as each subtree completes.

    .PARAMETER Path
        Root path to scan. Omit to scan all local fixed drives.

    .EXAMPLE
        Get-DiskUsage
        Get-DiskUsage -Path C:\Users
        Get-DiskUsage -Path D:\
    #>
    [CmdletBinding()]
    param([string]$Path)

    #region ── Colours ──────────────────────────────────────────────────────────
    $C = @{
        Header   = 'Cyan';      Selected = 'Yellow'; Dir      = 'Blue'
        File     = 'Gray';      Size     = 'White';  Help     = 'DarkCyan'
        Err      = 'Red';       Crumb    = 'Magenta'; Drive   = 'Green'
        Scanning = 'DarkYellow'
    }
    #endregion

    #region ── Display helpers ──────────────────────────────────────────────────
    function Format-Size([long]$Bytes) {
        switch ($Bytes) {
            { $_ -ge 1TB } { return "{0,7:F2} TB" -f ($_ / 1TB) }
            { $_ -ge 1GB } { return "{0,7:F2} GB" -f ($_ / 1GB) }
            { $_ -ge 1MB } { return "{0,7:F2} MB" -f ($_ / 1MB) }
            { $_ -ge 1KB } { return "{0,7:F2} KB" -f ($_ / 1KB) }
            default        { return "{0,7:F2}  B"  -f $_ }
        }
    }

    function Get-Bar([long]$Size, [long]$Max, [int]$Width = 20) {
        if ($Max -eq 0) { return "[" + (" " * $Width) + "]" }
        $fill = [math]::Max(0, [math]::Min([math]::Round(($Size / $Max) * $Width), $Width))
        return "[" + ("#" * $fill) + ("-" * ($Width - $fill)) + "]"
    }

    function Get-DriveStats([string]$FullPath) {
        if ([string]::IsNullOrWhiteSpace($FullPath)) { return $null }
        try {
            $root = [System.IO.Path]::GetPathRoot($FullPath)
            $drv  = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                    Where-Object { $_.Root -eq $root } | Select-Object -First 1
            if ($drv -and $null -ne $drv.Free) {
                return @{ Free = [long]$drv.Free; Total = [long]($drv.Used + $drv.Free) }
            }
        } catch {}
        return $null
    }

    function Get-SortedChildren([object]$Node) {
        if ($null -eq $Node.Children -or $Node.Children.Count -eq 0) { return @() }
        return @($Node.Children | Sort-Object Size -Descending)
    }
    #endregion

    #region ── Parallel scan scriptblock ────────────────────────────────────────
    #
    # Injected into every runspace via InitialSessionState so $PSduQueue is a
    # true shared reference - not a serialised copy.
    # Uses .NET DirectoryInfo for fast enumeration inside the runspace.
    #
    $ScanBlock = {
        param([string]$ScanPath)
        # $PSduQueue comes from the InitialSessionState variable injection below.

        function Scan-Dir([string]$DirPath) {
            $leaf = [System.IO.Path]::GetFileName($DirPath)
            $node = [PSCustomObject]@{
                Name     = if ($leaf) { $leaf } else { $DirPath }
                FullPath = $DirPath
                Size     = 0L
                IsDir    = $true
                Children = [System.Collections.Generic.List[object]]::new()
                Error    = $false
                Scanning = $false
            }
            try {
                $di = [System.IO.DirectoryInfo]::new($DirPath)
                try {
                    foreach ($f in $di.EnumerateFiles()) {
                        try {
                            $fc = [PSCustomObject]@{
                                Name=$f.Name; FullPath=$f.FullName; Size=$f.Length
                                IsDir=$false; Children=$null; Error=$false; Scanning=$false
                            }
                            $node.Children.Add($fc)
                            $node.Size += $f.Length
                        } catch {}
                    }
                } catch {}
                try {
                    foreach ($d in $di.EnumerateDirectories()) {
                        try {
                            $child = Scan-Dir $d.FullName
                            $node.Children.Add($child)
                            $node.Size += $child.Size
                        } catch {}
                    }
                } catch {}
            } catch { $node.Error = $true }
            return $node
        }

        try {
            $result = Scan-Dir $ScanPath
            $PSduQueue.Enqueue([PSCustomObject]@{ ScanPath = $ScanPath; Result = $result })
        } catch {}
    }
    #endregion

    #region ── Runspace pool with shared queue ───────────────────────────────────
    $ResultQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

    # Inject the queue as a named variable into every runspace so it is shared
    # by reference rather than serialised through AddParameter.
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Variables.Add(
        [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
            'PSduQueue', $ResultQueue, 'PSdu shared result queue'))

    $ThreadCount = [math]::Min(16, [math]::Max(4, [Environment]::ProcessorCount * 2))
    $RSPool      = [RunspaceFactory]::CreateRunspacePool(1, $ThreadCount, $iss, $Host)
    $RSPool.Open()

    $ActiveJobs = [System.Collections.Generic.List[hashtable]]::new()

    function Start-BackgroundScan([object]$Node) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $RSPool
        [void]$ps.AddScript($ScanBlock)
        [void]$ps.AddParameter('ScanPath', $Node.FullPath)
        $h = $ps.BeginInvoke()
        $ActiveJobs.Add(@{ PS = $ps; Handle = $h; Path = $Node.FullPath })
    }
    #endregion

    #region ── Tree building helpers ────────────────────────────────────────────
    # NodeIndex   : FullPath -> node   (fast lookup when a scan result arrives)
    # ParentIndex : child FullPath -> parent node  (for propagating sizes up)
    $NodeIndex   = @{}
    $ParentIndex = @{}

    # Build one level of the tree using Get-ChildItem (reliable on all PS versions).
    # Files get real sizes immediately; directories become scanning placeholders.
    function Build-ShallowNode([string]$DirPath, [string]$DisplayName) {
        $root = [PSCustomObject]@{
            Name     = $DisplayName
            FullPath = $DirPath
            Size     = 0L
            IsDir    = $true
            Children = [System.Collections.Generic.List[object]]::new()
            Error    = $false
            Scanning = $false
        }
        $NodeIndex[$DirPath] = $root

        try {
            $entries = Get-ChildItem -LiteralPath $DirPath -Force -ErrorAction Stop
            foreach ($e in $entries) {
                if ($e.PSIsContainer) {
                    $ph = [PSCustomObject]@{
                        Name     = $e.Name
                        FullPath = $e.FullName
                        Size     = 0L
                        IsDir    = $true
                        Children = $null     # populated when background scan completes
                        Error    = $false
                        Scanning = $true
                    }
                    $NodeIndex[$e.FullName]   = $ph
                    $ParentIndex[$e.FullName] = $root
                    $root.Children.Add($ph)
                    Start-BackgroundScan $ph
                } else {
                    $fc = [PSCustomObject]@{
                        Name     = $e.Name
                        FullPath = $e.FullName
                        Size     = $e.Length
                        IsDir    = $false
                        Children = $null
                        Error    = $false
                        Scanning = $false
                    }
                    $root.Children.Add($fc)
                    $root.Size += $e.Length
                }
            }
        } catch {
            $root.Error = $true
        }
        return $root
    }
    #endregion

    #region ── Root construction ────────────────────────────────────────────────
    $scanRoot = $null

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $scanRoot = [PSCustomObject]@{
            Name='This PC'; FullPath=''; Size=0L; IsDir=$true
            Children=[System.Collections.Generic.List[object]]::new()
            Error=$false; Scanning=$false
        }
        $drives = Get-PSDrive -PSProvider FileSystem |
                  Where-Object { $_.Root -and (Test-Path $_.Root) }
        foreach ($drv in $drives) {
            Write-Host ("  Indexing " + $drv.Root + " ...") -ForegroundColor $C.Help
            $dn = Build-ShallowNode $drv.Root ($drv.Name + ':\')
            $scanRoot.Children.Add($dn)
            $ParentIndex[$drv.Root] = $scanRoot   # roll drive totals up to "This PC"
        }
    } else {
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Error "Path not found: $Path"
            $RSPool.Close(); $RSPool.Dispose()
            return
        }
        $rp   = (Resolve-Path $Path).Path
        $name = Split-Path $rp -Leaf
        if (!$name) { $name = $rp }
        Write-Host ("  Indexing " + $rp + " ...") -ForegroundColor $C.Help
        $scanRoot = Build-ShallowNode $rp $name
    }
    #endregion

    #region ── Process completed scans ──────────────────────────────────────────
    function Update-FromQueue {
        $item = $null
        while ($ResultQueue.TryDequeue([ref]$item)) {
            $node = $NodeIndex[$item.ScanPath]
            if ($node) {
                # Graft the subtree result onto the live placeholder node.
                $node.Children = $item.Result.Children
                $node.Size     = $item.Result.Size
                $node.Error    = $item.Result.Error
                $node.Scanning = $false

                # Propagate the new size up through all ancestors.
                $cur    = $node
                $parent = $ParentIndex[$cur.FullPath]
                while ($parent) {
                    $sz = 0L
                    foreach ($c in $parent.Children) { $sz += $c.Size }
                    $parent.Size = $sz
                    $cur    = $parent
                    $parent = $ParentIndex[$cur.FullPath]
                }
            }
            $job = $ActiveJobs | Where-Object { $_.Path -eq $item.ScanPath } | Select-Object -First 1
            if ($job) {
                try { $job.PS.Dispose() } catch {}
                [void]$ActiveJobs.Remove($job)
            }
        }
    }
    #endregion

    #region ── Interactive viewer ────────────────────────────────────────────────
    $stack     = [System.Collections.Stack]::new()
    $current   = $scanRoot
    $selected  = 0
    $scrollTop = 0
    $spinChars = '|','/','-','\'
    $spinIdx   = 0

    [System.Console]::CursorVisible = $false
    Clear-Host

    try {
        while ($true) {

            Update-FromQueue

            $pageSize = [System.Console]::WindowHeight - 10
            $items    = @(Get-SortedChildren $current)
            $count    = $items.Count

            if ($count -eq 0) { $selected = 0 }
            else {
                if ($selected -ge $count)                   { $selected  = $count - 1 }
                if ($selected -lt $scrollTop)               { $scrollTop = $selected }
                if ($selected -ge ($scrollTop + $pageSize)) { $scrollTop = $selected - $pageSize + 1 }
            }

            [System.Console]::SetCursorPosition(0, 0)

            # ── Header ──────────────────────────────────────────────────────────
            $divider = "=" * [System.Console]::WindowWidth
            Write-Host $divider -ForegroundColor $C.Header
            $rem = $ActiveJobs.Count
            $status = if ($rem -gt 0) { "  [$($spinChars[$spinIdx % 4]) scanning $rem...]"; $spinIdx++ } else { "" }
            Write-Host (" PSdu  --  Disk Usage Explorer$status") -ForegroundColor $C.Header

            # ── Breadcrumb ───────────────────────────────────────────────────────
            $parts = @()
            foreach ($s in ($stack.ToArray() | Select-Object -Last 4)) { $parts += $s.Name }
            $parts += $current.Name
            $bc = " Path: " + ($parts -join " > ")
            $maxW = [System.Console]::WindowWidth - 2
            if ($bc.Length -gt $maxW) { $bc = " ..." + $bc.Substring($bc.Length - ($maxW - 4)) }
            Write-Host $bc -ForegroundColor $C.Crumb

            # ── Stats ────────────────────────────────────────────────────────────
            $sm = if ($current.Scanning) { "  (scanning...)" } else { "" }
            Write-Host (" Total: " + (Format-Size $current.Size).Trim() + "$sm   Items: $count") `
                -ForegroundColor $C.Size

            # ── Drive free / total ───────────────────────────────────────────────
            $ds = Get-DriveStats $current.FullPath
            if ($ds) {
                $free  = (Format-Size $ds.Free).Trim()
                $total = (Format-Size $ds.Total).Trim()
                $pct   = if ($ds.Total -gt 0) { "{0:F1}%" -f (100*($ds.Total-$ds.Free)/$ds.Total) } else { "N/A" }
                $dbar  = Get-Bar ($ds.Total - $ds.Free) $ds.Total 20
                Write-Host (" Drive: $free free of $total  $dbar  $pct used") -ForegroundColor $C.Drive
            } else { Write-Host "" }

            Write-Host $divider -ForegroundColor $C.Header

            # ── Listing ──────────────────────────────────────────────────────────
            if ($count -eq 0 -and $current.Scanning) {
                Write-Host "  Scanning, please wait..." -ForegroundColor $C.Scanning
            }

            $maxSz  = if ($count -gt 0) { [math]::Max(1L, $items[0].Size) } else { 1L }
            $barW   = 20
            $nameW  = [System.Console]::WindowWidth - $barW - 24
            $visEnd = [math]::Min($scrollTop + $pageSize, $count)

            for ($i = $scrollTop; $i -lt $visEnd; $i++) {
                $item = $items[$i]
                $icon = if ($item.IsDir) { "/" } else { " " }
                $tag  = if ($item.Scanning) { "~" } `
                        elseif ($item.IsDir -and $null -eq $item.Children) { "?" } `
                        else { " " }
                $name = $icon + $item.Name
                if ($name.Length -gt $nameW) { $name = $name.Substring(0, $nameW - 1) + "~" }
                $name = $name.PadRight($nameW)
                $sz   = Format-Size $item.Size
                $bar  = Get-Bar $item.Size $maxSz $barW
                $line = "  $name  $sz  $bar$tag"

                if ($i -eq $selected) {
                    Write-Host $line -ForegroundColor $C.Selected -BackgroundColor DarkGray
                } elseif ($item.IsDir) {
                    $col = if ($item.Scanning) { $C.Scanning } else { $C.Dir }
                    Write-Host $line -ForegroundColor $col
                } else {
                    Write-Host $line -ForegroundColor $C.File
                }
            }
            for ($p = ($visEnd - $scrollTop); $p -lt $pageSize; $p++) {
                Write-Host ("".PadRight([System.Console]::WindowWidth))
            }

            # ── Footer ───────────────────────────────────────────────────────────
            Write-Host $divider -ForegroundColor $C.Header
            Write-Host "  [Up/Dn] Navigate  [Enter/Right] Open  [Bksp/Left] Back  [d] Delete  [c] Clear  [q] Quit" `
                -ForegroundColor $C.Help

            # ── Key input ─────────────────────────────────────────────────────────
            # Poll briefly so the display updates as scans complete.
            # Always read a keypress if one is waiting - never skip it.
            $deadline = [DateTime]::UtcNow.AddMilliseconds(200)
            while (-not [System.Console]::KeyAvailable) {
                if ([DateTime]::UtcNow -ge $deadline) { break }
                if ($ResultQueue.Count -gt 0) { break }   # new data - redraw
                [System.Threading.Thread]::Sleep(30)
            }

            # Redraw first if new scan data arrived, THEN handle any key.
            # This way keypresses are never silently dropped.
            if (-not [System.Console]::KeyAvailable) { continue }

            $key = [System.Console]::ReadKey($true)

            switch ($key.Key) {

                'UpArrow'   { if ($selected -gt 0) { $selected-- } }
                'DownArrow' { if ($selected -lt ($count - 1)) { $selected++ } }

                { $_ -in 'Enter', 'RightArrow' } {
                    if ($count -gt 0) {
                        $target = $items[$selected]
                        if ($target.IsDir) {
                            if ($null -eq $target.Children -and -not $target.Scanning) {
                                # Fallback: lazily scan a node we missed (shouldn't normally happen).
                                $target.Scanning = $true
                                Start-BackgroundScan $target
                            }
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
                            -ForegroundColor $C.Err -NoNewline
                        [System.Console]::CursorVisible = $true
                        $confirm = Read-Host
                        [System.Console]::CursorVisible = $false
                        if ($confirm -eq 'YES') {
                            try {
                                Remove-Item -LiteralPath $target.FullPath -Recurse -Force -ErrorAction Stop
                                [void]$current.Children.Remove($target)
                                $current.Size -= $target.Size
                                foreach ($anc in $stack) { $anc.Size -= $target.Size }
                                if ($selected -ge $current.Children.Count -and $selected -gt 0) { $selected-- }
                            } catch {
                                Write-Host ("  ERROR: " + $_) -ForegroundColor $C.Err
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
                                -ForegroundColor $C.Err -NoNewline
                            [System.Console]::CursorVisible = $true
                            $confirm = Read-Host
                            [System.Console]::CursorVisible = $false
                            if ($confirm -eq 'YES') {
                                try {
                                    Get-ChildItem -LiteralPath $target.FullPath -Force -ErrorAction Stop |
                                        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop }
                                    $target.Children = [System.Collections.Generic.List[object]]::new()
                                    $freed = $target.Size; $target.Size = 0L
                                    $current.Size -= $freed
                                    foreach ($anc in $stack) { $anc.Size -= $freed }
                                } catch {
                                    Write-Host ("  ERROR: " + $_) -ForegroundColor $C.Err
                                    Start-Sleep -Seconds 2
                                }
                            }
                        }
                    }
                }

                'Q' {
                    [System.Console]::CursorVisible = $true
                    Clear-Host
                    Write-Host "  Exited PSdu." -ForegroundColor $C.Help
                    return
                }
            }
        }
    } finally {
        foreach ($job in $ActiveJobs) {
            try { $job.PS.Stop()    } catch {}
            try { $job.PS.Dispose() } catch {}
        }
        $RSPool.Close()
        $RSPool.Dispose()
        [System.Console]::CursorVisible = $true
    }
    #endregion
}
