# UI Automation for OpenMusic in the test VM's desktop session (no mouse there). Run through windows-vm.sh uia:
#   uia click <AutomationId>        invoke a button, menu item or link
#   uia set <AutomationId> <text>   type into a text field (the value pattern, as pasting would)
#   uia text <AutomationId>         print an element's name or value
#   uia exists <AutomationId>       print yes/no
#   uia focused                     print the focused element's AutomationId, control type and Narrator name
#   uia names                       list every control with a Narrator name: AutomationId, type, name (unnamed ones flagged)
#   uia dump                        list the AutomationIds on screen
# Searches only OpenMusic's own windows (a search from the desktop root can hang on other apps' trees).
# Results go to C:\medley\<slot>\uia-out.txt (the desktop session has no console the caller can read).
# -ArgsFile <path>: the op, id and text on three lines (windows-vm.sh uses it: quotes don't survive the scheduled task).
param([string]$Op, [string]$Id, [string]$Text, [string]$Out = "$PSScriptRoot\uia-out.txt", [int]$Wait = 8, [string]$ArgsFile)
if ($ArgsFile) { $l = @(Get-Content $ArgsFile -Encoding UTF8); $Op = $l[0]; $Id = "$($l[1])"; $Text = "$($l[2])" }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
function AppWindows {
  $ids = @(Get-Process OpenMusic -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
  if ($ids.Count -eq 0) { return @() }
  $A::RootElement.FindAll($Scope::Children, [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $ids -contains $_.Current.ProcessId }
}
function Find([string]$aid) {
  $cond = New-Object System.Windows.Automation.PropertyCondition($A::AutomationIdProperty, $aid)
  $deadline = (Get-Date).AddSeconds($Wait)
  do {
    foreach ($w in AppWindows) {
      $e = $w.FindFirst($Scope::Descendants, $cond)
      if ($e) { return $e }
    }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)
  return $null
}
function All {
  foreach ($w in AppWindows) { $w.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) }
}
try {
  switch ($Op) {
    'click' {
      $e = Find $Id; if (-not $e) { throw "no element $Id" }
      $p = $null
      if ($e.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke() }
      elseif ($e.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { $p.Toggle() }
      elseif ($e.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select() }
      elseif ($e.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p)) { $p.Expand() }
      else { throw "$Id can't be invoked" }
      "clicked $Id" | Set-Content $Out
    }
    'set' {
      $e = Find $Id; if (-not $e) { throw "no element $Id" }
      $p = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); $p.SetValue($Text)
      "set $Id" | Set-Content $Out
    }
    'text' {
      $e = Find $Id; if (-not $e) { throw "no element $Id" }
      $p = $null; $v = $e.Current.Name
      if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) { $v = "$v | $($p.Current.Value)" }
      "text $Id = $v" | Set-Content $Out
    }
    'exists' { $Wait = [Math]::Min($Wait, 2); if (Find $Id) { "yes" | Set-Content $Out } else { "no" | Set-Content $Out } }
    'focused' {
      $f = $A::FocusedElement
      "focused $($f.Current.AutomationId) [$($f.Current.ControlType.ProgrammaticName)] $($f.Current.Name)" | Set-Content $Out
    }
    'names' {
      $interactive = 'ControlType.Button','ControlType.Edit','ControlType.Hyperlink','ControlType.CheckBox','ControlType.ComboBox','ControlType.ListItem','ControlType.RadioButton','ControlType.MenuItem'
      All | Where-Object { $_.Current.IsOffscreen -eq $false -and $interactive -contains $_.Current.ControlType.ProgrammaticName } |
        ForEach-Object { $n = $_.Current.Name; if (-not $n) { $n = "!! NO NAME" }; "$($_.Current.AutomationId) [$($_.Current.ControlType.ProgrammaticName)] $n" } | Set-Content $Out
    }
    'dump' {
      All | Where-Object { $_.Current.AutomationId } |
        ForEach-Object { "$($_.Current.AutomationId) [$($_.Current.ControlType.ProgrammaticName)] $($_.Current.Name)" } | Set-Content $Out
    }
    default { throw "unknown op $Op" }
  }
} catch { "ERROR $_" | Set-Content $Out }
