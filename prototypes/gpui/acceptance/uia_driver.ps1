# Test-only exact-process UIA actions. JSON arrives on stdin; no raw UI tree dump.
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DBeerOwnedWindow {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
}
'@
    $raw = [Console]::In.ReadToEnd()
    if ($raw.Length -gt 65536) { throw 'Bound' }
    $request = $raw | ConvertFrom-Json
    $owner = $request.owner
    function Assert-Owner {
        $process = [System.Diagnostics.Process]::GetProcessById([int]$owner.pid)
        # FILETIME matches Python GetProcessTimes; never infer PID ownership by name.
        if ($process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -ne $owner.startTime) { throw 'Lifetime' }
        if ([IO.Path]::GetFullPath($process.MainModule.FileName) -cne [IO.Path]::GetFullPath($owner.executable)) { throw 'Image' }
        if ((Get-FileHash -LiteralPath $owner.executable -Algorithm SHA256).Hash.ToLowerInvariant() -ne $owner.sha256) { throw 'Hash' }
    }
    function Hash-Text([string]$value) {
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($value)))).Replace('-', '').ToLowerInvariant() }
        finally { $algorithm.Dispose() }
    }
    Assert-Owner
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$owner.pid)
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
    $matches = @($windows | Where-Object { $_.Current.ControlType.ProgrammaticName -eq ('ControlType.' + $request.window.role) -and $_.Current.Name -ceq $request.window.name })
    if ($matches.Count -ne 1) { throw 'Window' }
    $window = $matches[0]
    [uint32]$foregroundPid = 0
    $foreground = [DBeerOwnedWindow]::GetForegroundWindow()
    [void][DBeerOwnedWindow]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)
    $active = $foregroundPid -eq [int]$owner.pid
    $mutating = $request.action -notin @('inspect', 'assert', 'wait', 'read-text-range')
    if ($mutating -and (-not $request.disposableDesktopAcknowledged -or -not $active)) { throw 'Foreground' }
    $node = $window
    $target = $request.selector
    if ($null -ne $target) {
        if ($target.identitySensitive -and -not $target.nativeId) { throw 'Identity' }
        $elements = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($elements.Count -gt 8192) { throw 'Bound' }
        $matches = @()
        foreach ($item in $elements) {
            $current = $item.Current
            if ($current.ControlType.ProgrammaticName -ne ('ControlType.' + $target.role)) { continue }
            if ($null -ne $target.name -and $current.Name -cne $target.name) { continue }
            if ($target.nativeId -and $current.AutomationId -cne $target.nativeId) { continue }
            $parents = @()
            $parent = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($item)
            for ($depth = 0; $null -ne $parent -and $depth -lt 64; $depth++) {
                $parents = @($parent) + $parents
                if ($parent -eq $window) { break }
                $parent = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($parent)
            }
            $expected = @()
            if ($null -ne $target.ancestors) { $expected = @($target.ancestors) }
            $good = $parents.Count -ge $expected.Count
            for ($i = 0; $good -and $i -lt $expected.Count; $i++) {
                $actual = $parents[$parents.Count - $expected.Count + $i].Current
                $good = $actual.ControlType.ProgrammaticName -eq ('ControlType.' + $expected[$i].role)
                if ($expected[$i].nativeId) { $good = $good -and $actual.AutomationId -ceq $expected[$i].nativeId }
            }
            if ($good) { $matches += $item }
        }
        if ($matches.Count -ne 1) { throw 'Target' }
        $node = $matches[0]
    }
    Assert-Owner
    $windowKey = Hash-Text ($owner.pid.ToString() + ':' + $owner.startTime + ':' + $window.Current.NativeWindowHandle.ToString())
    $binding = Hash-Text ($windowKey + ':' + ($node.GetRuntimeId() -join ',') + ':' + $node.Current.AutomationId)
    if ($request.expectedWindowKey -and $request.expectedWindowKey -ne $windowKey) { throw 'WindowChanged' }
    if ($request.expectedBinding -and $request.expectedBinding -ne $binding) { throw 'TargetChanged' }
    if ($mutating) {
        [uint32]$currentForegroundPid = 0
        [void][DBeerOwnedWindow]::GetWindowThreadProcessId([DBeerOwnedWindow]::GetForegroundWindow(), [ref]$currentForegroundPid)
        if ($currentForegroundPid -ne [int]$owner.pid -or -not $node.Current.IsEnabled -or ($node.Current.IsOffscreen -and $request.action -ne 'scroll')) { throw 'State' }
    }
    $focused = $node.Current.HasKeyboardFocus
    $textPattern = $null
    $documentRange = $null
    function Get-OwnedTextPattern {
        if (-not $target -or $target.secret -or -not $target.nativeId -or $node.Current.IsPassword) { throw 'SecretOrIdentity' }
        $pattern = [System.Windows.Automation.TextPattern]$node.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        $value = $pattern.DocumentRange.GetText(65537)
        if ($value.Length -gt 65536 -or (Hash-Text $value) -cne $request.expectedTextSha256) { throw 'OriginalText' }
        return $pattern
    }
    function Get-PrefixAt([System.Windows.Automation.Text.TextPatternRange]$document, [int]$offset) {
        # Character units are provider defined. Locate a native endpoint by its
        # independently measured UTF-16 prefix, never assume one unit == UTF-16.
        $low = 0
        $high = $document.GetText(65537).Length
        if ($offset -lt 0 -or $offset -gt $high) { throw 'TextRange' }
        for ($attempt = 0; $attempt -lt 18 -and $low -le $high; $attempt++) {
            $units = [int][Math]::Floor(($low + $high) / 2)
            $prefix = $document.Clone()
            $prefix.MoveEndpointByRange([System.Windows.Automation.Text.TextPatternRangeEndpoint]::End, $prefix, [System.Windows.Automation.Text.TextPatternRangeEndpoint]::Start)
            [void]$prefix.MoveEndpointByUnit([System.Windows.Automation.Text.TextPatternRangeEndpoint]::End, [System.Windows.Automation.Text.TextUnit]::Character, $units)
            $length = $prefix.GetText(65537).Length
            if ($length -eq $offset) { return $prefix }
            if ($length -lt $offset) { $low = $units + 1 } else { $high = $units - 1 }
        }
        throw 'UnrepresentableNativeEndpoint'
    }
    if ($request.expectExit -and $request.action -ne 'invoke') { throw 'ExitAction' }
    switch ($request.action) {
        'focus' { $node.SetFocus() }
        'invoke' { ([System.Windows.Automation.InvokePattern]$node.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke() }
        'select' { ([System.Windows.Automation.SelectionItemPattern]$node.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select() }
        'scroll' { ([System.Windows.Automation.ScrollItemPattern]$node.GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern)).ScrollIntoView() }
        'set-text' {
            if ($target.identitySensitive) { throw 'CellBypass' }
            ([System.Windows.Automation.ValuePattern]$node.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue($request.text)
        }
        'select-text-range' {
            $textPattern = Get-OwnedTextPattern
            $documentRange = $textPattern.DocumentRange
            $first = Get-PrefixAt $documentRange ([int]$request.textRange.start)
            $last = Get-PrefixAt $documentRange ([int]$request.textRange.end)
            $selected = $documentRange.Clone()
            $selected.MoveEndpointByRange([System.Windows.Automation.Text.TextPatternRangeEndpoint]::Start, $first, [System.Windows.Automation.Text.TextPatternRangeEndpoint]::End)
            $selected.MoveEndpointByRange([System.Windows.Automation.Text.TextPatternRangeEndpoint]::End, $last, [System.Windows.Automation.Text.TextPatternRangeEndpoint]::End)
            Assert-Owner
            if ((Hash-Text $textPattern.DocumentRange.GetText(65537)) -cne $request.expectedTextSha256) { throw 'OriginalTextChanged' }
            [uint32]$rangeForegroundPid = 0
            [void][DBeerOwnedWindow]::GetWindowThreadProcessId([DBeerOwnedWindow]::GetForegroundWindow(), [ref]$rangeForegroundPid)
            if ($rangeForegroundPid -ne [int]$owner.pid) { throw 'ForegroundChanged' }
            if (@($textPattern.GetSelection()).Count -gt 1) { throw 'UnrelatedSelections' }
            $selected.Select()
        }
        { $_ -in @('inspect', 'assert', 'wait', 'read-text-range') } { }
        default { throw 'ManualCapability' }
    }
    if (-not $request.expectExit) {
        Assert-Owner
        $focused = $node.Current.HasKeyboardFocus
    }
    $valueHash = $null
    if ($request.readValue) {
        if (-not $target -or $target.secret -or $node.Current.IsPassword) { throw 'Secret' }
        $propertyName = $target.valueProperty
        if (-not $propertyName -or $propertyName -ceq 'value') {
            $value = [System.Windows.Automation.ValuePattern]$node.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            $textValue = $value.Current.Value
        } elseif ($propertyName -ceq 'name') {
            $textValue = $node.Current.Name
        } elseif ($propertyName -ceq 'text') {
            $value = [System.Windows.Automation.TextPattern]$node.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
            $textValue = $value.DocumentRange.GetText(65537)
        } else { throw 'ValueProperty' }
        if ($textValue.Length -gt 65536) { throw 'ValueBound' }
        $valueHash = Hash-Text $textValue
    }
    $textRangeResult = $null
    if ($request.action -in @('read-text-range', 'select-text-range')) {
        $textPattern = Get-OwnedTextPattern
        $documentRange = $textPattern.DocumentRange
        $source = $documentRange.GetText(65537)
        $selections = @($textPattern.GetSelection())
        if ($selections.Count -lt 1 -or $selections.Count -gt 16) { throw 'SelectionCount' }
        $ranges = @()
        foreach ($selection in $selections) {
            $first = $documentRange.Clone()
            $last = $documentRange.Clone()
            $first.MoveEndpointByRange([System.Windows.Automation.Text.TextPatternRangeEndpoint]::End, $selection, [System.Windows.Automation.Text.TextPatternRangeEndpoint]::Start)
            $last.MoveEndpointByRange([System.Windows.Automation.Text.TextPatternRangeEndpoint]::End, $selection, [System.Windows.Automation.Text.TextPatternRangeEndpoint]::End)
            $startOffset = $first.GetText(65537).Length
            $endOffset = $last.GetText(65537).Length
            if ($startOffset -gt $endOffset -or $endOffset -gt $source.Length) { throw 'SelectionBounds' }
            $ranges += @{start=$startOffset; end=$endOffset; textSha256=(Hash-Text $selection.GetText(65537))}
        }
        $textRangeResult = @{textSha256=(Hash-Text $source); utf16Length=$source.Length; selections=@($ranges)}
    }
    $semantics = $null
    if ($request.readSemantics) {
        if (-not $target -or $target.secret -or $node.Current.IsPassword) { throw 'Secret' }
        $semantics = @{enabled=$node.Current.IsEnabled; focused=$node.Current.HasKeyboardFocus;
                      nameSha256=(Hash-Text $node.Current.Name)}
        # The observed exact selector contract must name the native property.
        # Never silently substitute an empty HelpText for a typed description.
        if ($target.descriptionProperty -ceq 'helpText') {
            $semantics.descriptionSha256 = Hash-Text $node.Current.HelpText
        } elseif ($target.descriptionProperty -ceq 'fullDescription') {
            $property = [System.Windows.Automation.AutomationProperty]::LookupById(30159)
            if ($null -eq $property) { throw 'DescriptionUnavailable' }
            $description = $node.GetCurrentPropertyValue($property, $true)
            if ($description -isnot [string]) { throw 'DescriptionUnavailable' }
            $semantics.descriptionSha256 = Hash-Text $description
        }
        $pattern = $null
        if ($node.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
            $semantics.readOnly = ([System.Windows.Automation.ValuePattern]$pattern).Current.IsReadOnly
        } elseif ($node.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
            $readOnly = ([System.Windows.Automation.TextPattern]$pattern).DocumentRange.GetAttributeValue([System.Windows.Automation.TextPattern]::IsReadOnlyAttribute)
            if ($readOnly -is [bool]) { $semantics.readOnly = $readOnly }
        }
        $pattern = $null
        if ($node.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
            $semantics.selected = ([System.Windows.Automation.SelectionItemPattern]$pattern).Current.IsSelected
        }
        $pattern = $null
        if ($node.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$pattern)) {
            $grid = ([System.Windows.Automation.GridPattern]$pattern).Current
            $semantics.rowCount = $grid.RowCount
            $semantics.columnCount = $grid.ColumnCount
        }
        $pattern = $null
        if ($node.TryGetCurrentPattern([System.Windows.Automation.GridItemPattern]::Pattern, [ref]$pattern)) {
            $cell = ([System.Windows.Automation.GridItemPattern]$pattern).Current
            $semantics.row = $cell.Row
            $semantics.column = $cell.Column
            $semantics.rowSpan = $cell.RowSpan
            $semantics.columnSpan = $cell.ColumnSpan
        }
    }
    if (-not $request.expectExit) { Assert-Owner }
    @{ schemaVersion=1; ownedPid=[int]$owner.pid; startTime=$owner.startTime; windowKey=$windowKey; binding=$binding; focused=$focused; active=$active; valueSha256=$valueHash; actionCompleted=$true; textRange=$textRangeResult; semantics=$semantics } | ConvertTo-Json -Depth 8 -Compress
} catch {
    [Console]::Out.WriteLine('{"schemaVersion":1,"refused":true}')
    exit 2
}
