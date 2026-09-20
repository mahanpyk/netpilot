param(
  [ValidateSet('Debug','Release')][string]$Configuration = 'Debug',
  [string]$PublishDir = "$PSScriptRoot\..\..\build\windows\x64\runner\$Configuration"
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
  throw 'WiX Toolset v4 is required. Install it with: dotnet tool install --global wix'
}
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$publishRoot = (Resolve-Path $PublishDir).Path.TrimEnd('\')
$files = @(Get-ChildItem $publishRoot -File -Recurse | Sort-Object FullName)
if (-not $files) { throw "No Windows build files found in $publishRoot" }
if (-not ($files | Where-Object Name -eq 'NetPilotMaintenance.exe')) {
  throw 'NetPilotMaintenance.exe is missing from the Windows build.'
}

$namespace = 'http://wixtoolset.org/schemas/v4/wxs'
$document = [System.Xml.XmlDocument]::new()
$wix = $document.CreateElement('Wix', $namespace)
$document.AppendChild($wix) | Out-Null
$fragment = $document.CreateElement('Fragment', $namespace)
$wix.AppendChild($fragment) | Out-Null
$rootDirectory = $document.CreateElement('DirectoryRef', $namespace)
$rootDirectory.SetAttribute('Id', 'INSTALLFOLDER')
$fragment.AppendChild($rootDirectory) | Out-Null
$group = $document.CreateElement('ComponentGroup', $namespace)
$group.SetAttribute('Id', 'NetPilotFiles')
$fragment.AppendChild($group) | Out-Null
$directories = @{ '' = @{ Id = 'INSTALLFOLDER'; Node = $rootDirectory } }
$directoryIndex = 0
$fileIndex = 0

foreach ($file in $files) {
  $relative = $file.FullName.Substring($publishRoot.Length).TrimStart('\')
  $parts = $relative -split '\\'
  $directoryKey = ''
  for ($partIndex = 0; $partIndex -lt $parts.Length - 1; $partIndex++) {
    $parentKey = $directoryKey
    $directoryKey = if ($parentKey) { "$parentKey\$($parts[$partIndex])" } else { $parts[$partIndex] }
    if (-not $directories.ContainsKey($directoryKey)) {
      $directoryIndex++
      $id = "NetPilotDir$directoryIndex"
      $directory = $document.CreateElement('Directory', $namespace)
      $directory.SetAttribute('Id', $id)
      $directory.SetAttribute('Name', $parts[$partIndex])
      $directories[$parentKey].Node.AppendChild($directory) | Out-Null
      $directories[$directoryKey] = @{ Id = $id; Node = $directory }
    }
  }

  $fileIndex++
  $component = $document.CreateElement('Component', $namespace)
  $component.SetAttribute('Id', "NetPilotComponent$fileIndex")
  $component.SetAttribute('Directory', $directories[$directoryKey].Id)
  $component.SetAttribute('Guid', '*')
  $entry = $document.CreateElement('File', $namespace)
  $entry.SetAttribute('Id', $(if ($relative -eq 'NetPilotMaintenance.exe') { 'NetPilotMaintenanceExe' } else { "NetPilotFile$fileIndex" }))
  $entry.SetAttribute('Source', $file.FullName)
  $entry.SetAttribute('KeyPath', 'yes')
  $component.AppendChild($entry) | Out-Null
  $group.AppendChild($component) | Out-Null
}

$harvest = Join-Path $out 'NetPilotFiles.generated.wxs'
$document.Save($harvest)
$msi = Join-Path $out 'NetPilot.msi'
wix build "$PSScriptRoot\Package.wxs" $harvest -arch x64 -o $msi
if ($LASTEXITCODE -ne 0) { throw 'WiX MSI build failed.' }
wix build "$PSScriptRoot\Bundle.wxs" -arch x64 -ext WixToolset.Bal.wixext -d "NetPilotMsi=$msi" -o (Join-Path $out 'NetPilotSetup.exe')
if ($LASTEXITCODE -ne 0) { throw 'WiX bootstrapper build failed.' }
