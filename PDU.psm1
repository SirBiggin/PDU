#Requires -Version 5.1

class PDUEntry {
    [string]   $Name
    [string]   $FullPath
    [bool]     $IsDirectory
    [long]     $DiskSize
    [long]     $FileSize
    [int]      $ItemCount
    [datetime] $LastWrite
    [bool]     $HasError
    [bool]     $IsParentLink
    [PDUEntry] $Parent
    [System.Collections.Generic.List[PDUEntry]] $Children

    PDUEntry() {
        $this.Children  = [System.Collections.Generic.List[PDUEntry]]::new()
        $this.LastWrite = [datetime]::MinValue
    }
}

#region ── Scan ────────────────────────────────────────────────────────────────

function script:New-PDUEntry {
    param(
        [string]   $Name,
        [string]   $FullPath,
        [bool]     $IsDir,
        [PDUEntry] $Parent
    )
    $e            = [PDUEntry]::new()
    $e.Name       = $Name
    $e.FullPath   = $FullPath
    $e.IsDirectory = $IsDir
    $e.Parent     = $Parent
    return $e
}

function script:Invoke-Scan {
    param(
        [string]   $Path,
        [PDUEntry] $Parent,
        [ref]      $Counter
    )

    $entry = New-PDUEntry -Name (Split-Path $Path -Leaf) -FullPath $Path -IsDir $true -Parent $Parent

    try {
        $di = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $entry.LastWrite = $di.LastWriteTime
    } catch { $entry.HasError = $true }

    try {
        $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        $entry.HasError = $true
        return $entry
    }

    foreach ($item in $items) {
        $Counter.Value++
        if ($Counter.Value % 200 -eq 0) {
            [Console]::SetCursorPosition(0, 1)
            [Console]::ForegroundColor = [ConsoleColor]::Gray
            $msg = ('  Scanning: {0} items found ...' -f $Counter.Value).PadRight([Console]::WindowWidth - 1)
            [Console]::Write($msg)
            [Console]::ResetColor()
        }

        if ($item.PSIsContainer) {
            $child = Invoke-Scan -Path $item.FullName -Parent $entry -Counter $Counter
        } else {
            $child            = New-PDUEntry -Name $item.Name -FullPath $item.FullName -IsDir $false -Parent $entry
            $child.LastWrite  = $item.LastWriteTime
            $child.ItemCount  = 1
            try {
                $child.FileSize = $item.Length
                # Estimate allocation in 4 KiB clusters; 0-byte files use 0
                if ($item.Length -gt 0) {
                    $child.DiskSize = [Math]::Ceiling($item.Length / 4096) * 4096
                }
            } catch { $child.HasError = $true }
        }

        $entry.Children.Add($child)
        $entry.DiskSize  += $child.DiskSize
        $entry.FileSize  += $child.FileSize
        $entry.ItemCount += $child.ItemCount
    }

    return $entry
}

#endregion

#region ── Formatting ──────────────────────────────────────────────────────────

function script:Format-Size {
    param([long]$Bytes)
    $units = @('  B','KiB','MiB','GiB','TiB','PiB')
    $val   = [double]$Bytes
    $idx   = 0
    while ($val -ge 1024.0 -and $idx -lt ($units.Count - 1)) { $val /= 1024.0; $idx++ }
    if ($idx -eq 0) { return '{0,6} {1}' -f [int]$val, $units[$idx] }
    return '{0,6:F1} {1}' -f $val, $units[$idx]
}

function script:Format-SizeShort {
    param([long]$Bytes)
    $units = @('B','K','M','G','T','P')
    $val   = [double]$Bytes
    $idx   = 0
    while ($val -ge 1024.0 -and $idx -lt ($units.Count - 1)) { $val /= 1024.0; $idx++ }
    if ($idx -eq 0) { return '{0,4} {1}' -f [int]$val, $units[$idx] }
    return '{0,4:F1}{1}' -f $val, $units[$idx]
}

#endregion

#region ── State ───────────────────────────────────────────────────────────────

$script:S = $null  # global TUI state

function script:Get-Sorted {
    param([PDUEntry]$Dir)
    $s    = $script:S
    $list = $Dir.Children | Where-Object { -not $_.IsParentLink }
    switch ($s.SortBy) {
        'name'  { return @($list | Sort-Object Name) }
        'asize' { return @($list | Sort-Object FileSize -Descending) }
        'count' { return @($list | Sort-Object ItemCount -Descending) }
        default { return @($list | Sort-Object DiskSize -Descending) }
    }
}

function script:Enter-Dir {
    param([PDUEntry]$Dir)
    $s = $script:S

    $children = Get-Sorted -Dir $Dir
    $maxSize  = 0
    foreach ($c in $children) { if ($c.DiskSize -gt $maxSize) { $maxSize = $c.DiskSize } }

    $entries = [System.Collections.Generic.List[PDUEntry]]::new()

    if ($null -ne $Dir.Parent) {
        $up              = [PDUEntry]::new()
        $up.Name         = '..'
        $up.FullPath     = $Dir.Parent.FullPath
        $up.IsDirectory  = $true
        $up.IsParentLink = $true
        $up.DiskSize     = $Dir.Parent.DiskSize
        $up.FileSize     = $Dir.Parent.FileSize
        $up.ItemCount    = $Dir.Parent.ItemCount
        $up.LastWrite    = $Dir.Parent.LastWrite
        $up.Parent       = $Dir.Parent.Parent
        $entries.Add($up)
    }

    foreach ($c in $children) { $entries.Add($c) }

    $s.CurrentDir    = $Dir
    $s.Entries       = $entries
    $s.SelectedIndex = 0
    $s.TopIndex      = 0
    $s.MaxSize       = $maxSize
}

#endregion

#region ── Rendering ───────────────────────────────────────────────────────────

$GRAPH_W = 10  # chars in the bar

function script:Draw-Screen {
    $s     = $script:S
    $W     = [Console]::WindowWidth
    $H     = [Console]::WindowHeight
    $bodyH = $H - 3   # 1 header + 2 footer

    # Keep selected in viewport
    if ($s.SelectedIndex -lt $s.TopIndex) {
        $s.TopIndex = $s.SelectedIndex
    }
    if ($s.SelectedIndex -ge ($s.TopIndex + $bodyH)) {
        $s.TopIndex = $s.SelectedIndex - $bodyH + 1
    }

    # ── Header ──────────────────────────────────────────────────────────────
    [Console]::SetCursorPosition(0, 0)
    [Console]::BackgroundColor = [ConsoleColor]::DarkBlue
    [Console]::ForegroundColor = [ConsoleColor]::White
    $pathStr = $s.CurrentDir.FullPath
    $hdr = ' PDU  {0}' -f $pathStr
    if ($hdr.Length -gt $W) { $hdr = ' PDU  ...{0}' -f $pathStr.Substring($pathStr.Length - ($W - 10)) }
    [Console]::Write($hdr.PadRight($W).Substring(0, $W))

    # ── Body ────────────────────────────────────────────────────────────────
    # Layout: [bar      ] size  /Name
    #          10 chars   6+4    rest
    $barCol  = 1
    $sizeCol = $barCol + $GRAPH_W + 3   # "[" + bar + "] "
    $typeCol = $sizeCol + 7             # "NNN.N X" = 7 chars
    $nameCol = $typeCol + 2             # " /" or "  "
    $nameW   = [Math]::Max(8, $W - $nameCol - 1)

    for ($row = 0; $row -lt $bodyH; $row++) {
        $idx = $s.TopIndex + $row
        [Console]::SetCursorPosition(0, $row + 1)
        [Console]::ResetColor()

        if ($idx -ge $s.Entries.Count) {
            [Console]::Write(' ' * $W)
            continue
        }

        $e   = $s.Entries[$idx]
        $sel = ($idx -eq $s.SelectedIndex)

        if ($sel) {
            [Console]::BackgroundColor = [ConsoleColor]::DarkCyan
            [Console]::ForegroundColor = [ConsoleColor]::White
        } elseif ($e.IsParentLink) {
            [Console]::ForegroundColor = [ConsoleColor]::DarkYellow
        } elseif ($e.IsDirectory) {
            [Console]::ForegroundColor = [ConsoleColor]::Cyan
        } elseif ($e.HasError) {
            [Console]::ForegroundColor = [ConsoleColor]::Red
        } else {
            [Console]::ForegroundColor = [ConsoleColor]::Gray
        }

        # Bar
        $pct    = if ($s.MaxSize -gt 0) { [Math]::Min(1.0, [double]$e.DiskSize / $s.MaxSize) } else { 0.0 }
        $filled = [Math]::Round($pct * $GRAPH_W)
        $bar    = '[' + ('#' * $filled) + ('.' * ($GRAPH_W - $filled)) + ']'

        # Size
        $szStr = Format-SizeShort -Bytes $e.DiskSize

        # Type flag
        if ($e.IsParentLink)      { $flag = '/^' }
        elseif ($e.IsDirectory)   { $flag = '/ ' }
        elseif ($e.HasError)      { $flag = '! ' }
        else                      { $flag = '  ' }

        # Name
        $nm = $e.Name
        if ($nm.Length -gt $nameW) { $nm = $nm.Substring(0, $nameW - 1) + '>' }

        $line = ' {0} {1} {2}{3}' -f $bar, $szStr, $flag, $nm
        if ($line.Length -lt $W) { $line = $line.PadRight($W) }
        [Console]::Write($line.Substring(0, $W))
    }

    [Console]::ResetColor()

    # ── Separator ───────────────────────────────────────────────────────────
    [Console]::SetCursorPosition(0, $H - 2)
    [Console]::BackgroundColor = [ConsoleColor]::DarkGray
    [Console]::ForegroundColor = [ConsoleColor]::White

    $sortLabel = switch ($s.SortBy) {
        'name'  { 'Name' }; 'asize' { 'Apparent' }; 'count' { 'Count' }; default { 'Size' }
    }
    $info = '  Sort:{0}  Total:{1}  Items:{2}  ' -f $sortLabel, (Format-SizeShort $s.CurrentDir.DiskSize), $s.CurrentDir.ItemCount
    [Console]::Write($info.PadRight($W).Substring(0, $W))

    # ── Key hints ───────────────────────────────────────────────────────────
    [Console]::SetCursorPosition(0, $H - 1)
    [Console]::BackgroundColor = [ConsoleColor]::Black
    [Console]::ForegroundColor = [ConsoleColor]::DarkGray
    $hints = ' n/s/a/c:Sort  Enter/Left:Nav  d:Del  i:Info  r:Rescan  ?:Help  q:Quit'
    [Console]::Write($hints.PadRight($W).Substring(0, $W))

    [Console]::ResetColor()
}

#endregion

#region ── Popups ──────────────────────────────────────────────────────────────

function script:Show-Popup {
    param([string[]]$Lines, [ConsoleColor]$BgColor = [ConsoleColor]::DarkBlue)
    $W     = [Console]::WindowWidth
    $H     = [Console]::WindowHeight
    $boxW  = [Math]::Min(62, $W - 4)
    $boxH  = $Lines.Count + 2
    $boxX  = [Math]::Floor(($W - $boxW) / 2)
    $boxY  = [Math]::Floor(($H - $boxH) / 2)
    $blank = ' ' * $boxW

    [Console]::BackgroundColor = $BgColor
    [Console]::ForegroundColor = [ConsoleColor]::White
    for ($r = 0; $r -lt $boxH; $r++) {
        [Console]::SetCursorPosition($boxX, $boxY + $r)
        [Console]::Write($blank)
    }
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        [Console]::SetCursorPosition($boxX + 2, $boxY + 1 + $i)
        $txt = $Lines[$i]
        if ($txt.Length -gt ($boxW - 4)) { $txt = $txt.Substring(0, $boxW - 4) }
        [Console]::Write($txt)
    }
    [Console]::ResetColor()
}

function script:Show-Help {
    Show-Popup -Lines @(
        'PDU - PowerShell Disk Usage  (NCDU-style)',
        '',
        'Navigation',
        '  Up / k         Move up',
        '  Down / j       Move down',
        '  PgUp / PgDn    Page up / down',
        '  Home / End     First / last item',
        '  Enter / Right  Open directory',
        '  Left / Bksp    Go to parent',
        '',
        'Sorting',
        '  s   Disk size (default)',
        '  a   Apparent (file) size',
        '  n   Name',
        '  c   Item count',
        '',
        'Actions',
        '  d   Delete selected item',
        '  i   Item info',
        '  r   Rescan current directory',
        '  q   Quit',
        '',
        'Press any key to close'
    )
    $null = [Console]::ReadKey($true)
}

function script:Show-Info {
    $s = $script:S
    if ($s.SelectedIndex -lt 0 -or $s.SelectedIndex -ge $s.Entries.Count) { return }
    $e = $s.Entries[$s.SelectedIndex]

    $typeStr = if ($e.IsDirectory) { 'Directory' } else { 'File' }
    $mtStr   = $e.LastWrite.ToString('yyyy-MM-dd HH:mm:ss')
    $errStr  = if ($e.HasError) { '  [access error]' } else { '' }

    Show-Popup -Lines @(
        'Item Info',
        '',
        ('Name  : {0}' -f $e.Name),
        ('Type  : {0}{1}' -f $typeStr, $errStr),
        ('Disk  : {0}' -f (Format-Size -Bytes $e.DiskSize)),
        ('Size  : {0}' -f (Format-Size -Bytes $e.FileSize)),
        ('Items : {0}' -f $e.ItemCount),
        ('Mtime : {0}' -f $mtStr),
        ('Path  : {0}' -f $e.FullPath),
        '',
        'Press any key to close'
    )
    $null = [Console]::ReadKey($true)
}

function script:Confirm-Delete {
    param([PDUEntry]$Entry)
    $label = if ($Entry.IsDirectory) { 'directory' } else { 'file' }
    Show-Popup -BgColor ([ConsoleColor]::DarkRed) -Lines @(
        'Delete {0}?' -f $label,
        '',
        ('  {0}' -f $Entry.FullPath),
        '',
        '  WARNING: this cannot be undone.',
        '',
        '  Press Y to confirm, any other key to cancel'
    )
    $k = [Console]::ReadKey($true)
    return ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y')
}

function script:Show-Error {
    param([string]$Message)
    Show-Popup -BgColor ([ConsoleColor]::DarkRed) -Lines @(
        'Error', '', $Message, '', 'Press any key to dismiss'
    )
    $null = [Console]::ReadKey($true)
}

#endregion

#region ── Actions ─────────────────────────────────────────────────────────────

function script:Do-Delete {
    $s = $script:S
    if ($s.SelectedIndex -lt 0 -or $s.SelectedIndex -ge $s.Entries.Count) { return }
    $sel = $s.Entries[$s.SelectedIndex]
    if ($sel.IsParentLink) { return }

    if (-not (Confirm-Delete -Entry $sel)) { return }

    try {
        Remove-Item -LiteralPath $sel.FullPath -Recurse -Force -ErrorAction Stop

        # Remove from in-memory tree
        $parent = $s.CurrentDir
        for ($j = 0; $j -lt $parent.Children.Count; $j++) {
            if ($parent.Children[$j].FullPath -eq $sel.FullPath) {
                # Walk size back up the tree
                $ancestor = $parent
                while ($null -ne $ancestor) {
                    $ancestor.DiskSize  -= $sel.DiskSize
                    $ancestor.FileSize  -= $sel.FileSize
                    $ancestor.ItemCount -= $sel.ItemCount
                    $ancestor = $ancestor.Parent
                }
                $parent.Children.RemoveAt($j)
                break
            }
        }
        Enter-Dir -Dir $s.CurrentDir
        if ($s.SelectedIndex -ge $s.Entries.Count) {
            $s.SelectedIndex = [Math]::Max(0, $s.Entries.Count - 1)
        }
    } catch {
        Show-Error -Message $_.Exception.Message
    }
}

function script:Do-Rescan {
    $s    = $script:S
    $path = $s.CurrentDir.FullPath

    # Preserve selection
    $prevName = if ($s.SelectedIndex -lt $s.Entries.Count) { $s.Entries[$s.SelectedIndex].Name } else { '' }

    [Console]::ResetColor()
    [Console]::Clear()
    [Console]::ForegroundColor = [ConsoleColor]::Yellow
    [Console]::SetCursorPosition(0, 0)
    [Console]::Write('Rescanning...')
    [Console]::ResetColor()

    $ctr  = [ref]0
    $fresh = Invoke-Scan -Path $path -Parent $s.CurrentDir.Parent -Counter $ctr

    # Splice back into parent
    if ($null -ne $s.CurrentDir.Parent) {
        $p = $s.CurrentDir.Parent
        for ($j = 0; $j -lt $p.Children.Count; $j++) {
            if ($p.Children[$j].FullPath -eq $path) {
                # Adjust ancestor sizes
                $diff = $fresh.DiskSize - $p.Children[$j].DiskSize
                $diffF = $fresh.FileSize - $p.Children[$j].FileSize
                $diffI = $fresh.ItemCount - $p.Children[$j].ItemCount
                $ancestor = $p
                while ($null -ne $ancestor) {
                    $ancestor.DiskSize  += $diff
                    $ancestor.FileSize  += $diffF
                    $ancestor.ItemCount += $diffI
                    $ancestor = $ancestor.Parent
                }
                $p.Children[$j] = $fresh
                break
            }
        }
    } else {
        $s.Root = $fresh
    }

    Enter-Dir -Dir $fresh

    if ($prevName) {
        for ($i = 0; $i -lt $s.Entries.Count; $i++) {
            if ($s.Entries[$i].Name -eq $prevName) { $s.SelectedIndex = $i; break }
        }
    }
}

#endregion

#region ── Main ────────────────────────────────────────────────────────────────

function Start-PDU {
    <#
    .SYNOPSIS
    PowerShell Disk Usage — interactive TUI disk usage browser (NCDU-style).

    .PARAMETER Path
    Root directory to scan. Defaults to the current directory.

    .EXAMPLE
    pdu
    pdu C:\Users
    Start-PDU D:\Projects
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Path = (Get-Location).Path
    )

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $rootPath = $resolved.ProviderPath

    # ── Save terminal state ─────────────────────────────────────────────────
    $savedTitle  = $Host.UI.RawUI.WindowTitle
    $savedFg     = [Console]::ForegroundColor
    $savedBg     = [Console]::BackgroundColor
    $savedCursor = [Console]::CursorVisible

    try {
        [Console]::CursorVisible = $false
        [Console]::Clear()
        [Console]::ForegroundColor = [ConsoleColor]::Yellow
        [Console]::SetCursorPosition(0, 0)
        [Console]::Write('PDU: Scanning {0} ...' -f $rootPath)
        [Console]::ResetColor()

        $ctr  = [ref]0
        $root = Invoke-Scan -Path $rootPath -Parent $null -Counter $ctr

        if ($root.Name -eq '') { $root.Name = $rootPath }

        $Host.UI.RawUI.WindowTitle = 'PDU - PowerShell Disk Usage'

        $script:S = [pscustomobject]@{
            Root          = $root
            CurrentDir    = $root
            Entries       = [System.Collections.Generic.List[PDUEntry]]::new()
            SelectedIndex = 0
            TopIndex      = 0
            MaxSize       = 0L
            SortBy        = 'size'
        }

        Enter-Dir -Dir $root

        # ── Event loop ──────────────────────────────────────────────────────
        [Console]::Clear()
        $running = $true
        while ($running) {
            Draw-Screen

            $k = [Console]::ReadKey($true)
            $s = $script:S

            switch ($k.Key) {
                'UpArrow'   { if ($s.SelectedIndex -gt 0) { $s.SelectedIndex-- } }
                'DownArrow' { if ($s.SelectedIndex -lt ($s.Entries.Count - 1)) { $s.SelectedIndex++ } }
                'PageUp' {
                    $ph = [Console]::WindowHeight - 3
                    $s.SelectedIndex = [Math]::Max(0, $s.SelectedIndex - $ph)
                }
                'PageDown' {
                    $ph = [Console]::WindowHeight - 3
                    $s.SelectedIndex = [Math]::Min($s.Entries.Count - 1, $s.SelectedIndex + $ph)
                }
                'Home' { $s.SelectedIndex = 0 }
                'End'  { $s.SelectedIndex = [Math]::Max(0, $s.Entries.Count - 1) }
                { $_ -in 'Enter','RightArrow' } {
                    if ($s.SelectedIndex -ge 0 -and $s.SelectedIndex -lt $s.Entries.Count) {
                        $sel = $s.Entries[$s.SelectedIndex]
                        if ($sel.IsParentLink -and $null -ne $sel.Parent) {
                            $prev = $s.CurrentDir
                            Enter-Dir -Dir $sel.Parent
                            for ($i = 0; $i -lt $s.Entries.Count; $i++) {
                                if ($s.Entries[$i].FullPath -eq $prev.FullPath) { $s.SelectedIndex = $i; break }
                            }
                        } elseif ($sel.IsDirectory -and -not $sel.IsParentLink) {
                            Enter-Dir -Dir $sel
                        }
                    }
                }
                { $_ -in 'LeftArrow','Backspace' } {
                    if ($null -ne $s.CurrentDir.Parent) {
                        $prev = $s.CurrentDir
                        Enter-Dir -Dir $s.CurrentDir.Parent
                        for ($i = 0; $i -lt $s.Entries.Count; $i++) {
                            if ($s.Entries[$i].FullPath -eq $prev.FullPath) { $s.SelectedIndex = $i; break }
                        }
                    }
                }
                default {
                    switch -CaseSensitive ($k.KeyChar) {
                        'q' { $running = $false }
                        'Q' { $running = $false }
                        'j' { if ($s.SelectedIndex -lt ($s.Entries.Count - 1)) { $s.SelectedIndex++ } }
                        'k' { if ($s.SelectedIndex -gt 0) { $s.SelectedIndex-- } }
                        's' { $s.SortBy = 'size';  Enter-Dir -Dir $s.CurrentDir }
                        'a' { $s.SortBy = 'asize'; Enter-Dir -Dir $s.CurrentDir }
                        'n' { $s.SortBy = 'name';  Enter-Dir -Dir $s.CurrentDir }
                        'c' { $s.SortBy = 'count'; Enter-Dir -Dir $s.CurrentDir }
                        'd' { Do-Delete }
                        'i' { Show-Info }
                        'r' { Do-Rescan }
                        '?' { Show-Help }
                    }
                }
            }
        }
    } finally {
        [Console]::ResetColor()
        [Console]::Clear()
        [Console]::CursorVisible  = $savedCursor
        [Console]::ForegroundColor = $savedFg
        [Console]::BackgroundColor = $savedBg
        $Host.UI.RawUI.WindowTitle = $savedTitle
        $script:S = $null
    }
}

Set-Alias -Name pdu -Value Start-PDU
Export-ModuleMember -Function Start-PDU -Alias pdu
