$ErrorActionPreference = 'Stop'

$actionPath = Join-Path $PSScriptRoot '..\action.yml'
$actionText = Get-Content -LiteralPath $actionPath -Raw

function Assert-Contains {
  param(
    [string] $Text,
    [string] $Expected,
    [string] $Message
  )

  if (-not $Text.Contains($Expected)) {
    throw "$Message Expected to find: $Expected"
  }
}

function Assert-DoesNotContain {
  param(
    [string] $Text,
    [string] $Unexpected,
    [string] $Message
  )

  if ($Text.Contains($Unexpected)) {
    throw "$Message Found unexpected text: $Unexpected"
  }
}

function Get-RunScript {
  param([string] $StepName)

  $lines = Get-Content -LiteralPath $actionPath
  $stepLine = [Array]::FindIndex($lines, [Predicate[string]] { param($line) $line.Trim() -eq "- name: $StepName" })
  if ($stepLine -lt 0) {
    throw "Could not find action step '$StepName'."
  }

  $runLine = -1
  for ($index = $stepLine + 1; $index -lt $lines.Count; $index++) {
    if ($lines[$index].StartsWith('    - ')) {
      break
    }
    if ($lines[$index].Trim() -eq 'run: |') {
      $runLine = $index
      break
    }
  }

  if ($runLine -lt 0) {
    throw "Could not find the run block for action step '$StepName'."
  }

  $scriptLines = [System.Collections.Generic.List[string]]::new()
  for ($index = $runLine + 1; $index -lt $lines.Count; $index++) {
    $line = $lines[$index]
    if ($line.StartsWith('    - ') -or $line.StartsWith('      shell:') -or $line -match '^\S') {
      break
    }
    if ([string]::IsNullOrWhiteSpace($line)) {
      $scriptLines.Add('')
      continue
    }
    if (-not $line.StartsWith('        ')) {
      throw "Unexpected indentation in the '$StepName' run block: $line"
    }
    $scriptLines.Add($line.Substring(8))
  }

  return $scriptLines -join "`n"
}

$detectScript = Get-RunScript -StepName 'Detect Microsoft.Testing.Platform dotnet test experience'
$workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotnet-test-action-contract-$([guid]::NewGuid().ToString('N'))"
$outputPath = Join-Path $workspaceRoot 'github-output.txt'
New-Item -ItemType Directory -Path $workspaceRoot | Out-Null

$previousWorkspace = $env:GITHUB_WORKSPACE
$previousOutput = $env:GITHUB_OUTPUT
try {
  $env:GITHUB_WORKSPACE = $workspaceRoot
  $env:GITHUB_OUTPUT = $outputPath

  Set-Content -LiteralPath $outputPath -Value ''
  & { Invoke-Expression $detectScript }
  $vstestSelection = Get-Content -LiteralPath $outputPath -Raw
  Assert-Contains -Text $vstestSelection -Expected 'use-mtp=false' -Message 'A repository without global.json must select VSTest.'

  Set-Content -LiteralPath (Join-Path $workspaceRoot 'global.json') -Value '{"test":{"runner":"Microsoft.Testing.Platform"}}'
  Set-Content -LiteralPath $outputPath -Value ''
  & { Invoke-Expression $detectScript }
  $mtpSelection = Get-Content -LiteralPath $outputPath -Raw
  Assert-Contains -Text $mtpSelection -Expected 'use-mtp=true' -Message 'A repository opting into Microsoft.Testing.Platform must select MTP.'

  Set-Content -LiteralPath (Join-Path $workspaceRoot 'global.json') -Value '{ invalid json'
  Set-Content -LiteralPath $outputPath -Value ''
  $invalidJsonFailed = $false
  try {
    & { Invoke-Expression $detectScript }
  }
  catch {
    $invalidJsonFailed = $true
  }
  if (-not $invalidJsonFailed) {
    throw 'An invalid global.json must fail runner detection.'
  }
}
finally {
  if ($null -eq $previousWorkspace) {
    Remove-Item Env:GITHUB_WORKSPACE -ErrorAction SilentlyContinue
  }
  else {
    $env:GITHUB_WORKSPACE = $previousWorkspace
  }
  if ($null -eq $previousOutput) {
    Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
  }
  else {
    $env:GITHUB_OUTPUT = $previousOutput
  }

  $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
  $resolvedWorkspaceRoot = [System.IO.Path]::GetFullPath($workspaceRoot)
  if (-not $resolvedWorkspaceRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove contract-test path outside the temporary directory: $resolvedWorkspaceRoot"
  }
  Remove-Item -LiteralPath $resolvedWorkspaceRoot -Recurse -Force
}

$vstestStep = Get-RunScript -StepName 'Test'
Assert-Contains -Text $vstestStep -Expected '--collect:"XPlat Code Coverage;Format=opencover"' -Message 'The legacy VSTest collector invocation must remain unchanged.'
Assert-Contains -Text $vstestStep -Expected '--logger trx' -Message 'The legacy VSTest path must continue producing TRX.'
Assert-Contains -Text $vstestStep -Expected '--blame-hang-timeout' -Message 'The legacy VSTest hang timeout input must remain active.'
Assert-Contains -Text $vstestStep -Expected '--blame-hang-dump-type' -Message 'The legacy VSTest hang dump type input must remain active.'
Assert-Contains -Text $vstestStep -Expected '-p:CoverletOutputFormat=opencover' -Message 'The legacy VSTest OpenCover format property must remain unchanged.'

$mtpStep = Get-RunScript -StepName 'Test with Microsoft.Testing.Platform'
Assert-Contains -Text $mtpStep -Expected '--coverlet --coverlet-output-format opencover' -Message 'MTP must use Coverlet with OpenCover.'
Assert-Contains -Text $mtpStep -Expected '--report-xunit-trx' -Message 'MTP must continue producing xUnit TRX.'
Assert-Contains -Text $mtpStep -Expected '--hangdump --hangdump-timeout' -Message 'MTP must translate the existing hang timeout input.'
Assert-Contains -Text $mtpStep -Expected '--hangdump-type-if-supported' -Message 'MTP .NET Framework runs must translate dump types with the supported fallback option.'
Assert-Contains -Text $mtpStep -Expected '--test-modules' -Message 'MTP module discovery must remain available.'
Assert-Contains -Text $mtpStep -Expected 'dotnet test --test-modules "$module"' -Message 'MTP modules must execute individually so fixed Coverlet filenames do not overwrite other modules.'
Assert-Contains -Text $mtpStep -Expected 'if is_mtp_coverage_supported_tfm "$module_framework"; then' -Message 'Pre-built modern modules outside the supported coverage range must still run without Coverlet.'
Assert-Contains -Text $mtpStep -Expected 'module_results_directory="$results_directory/$module_framework/$module_name"' -Message 'Each discovered MTP module must retain coverage under the shared TestResults root in a unique directory.'
Assert-Contains -Text $mtpStep -Expected 'project_results_directory="$results_directory/$target_framework/$project_name"' -Message 'Explicit MTP project targets must retain results in target-specific directories.'
Assert-Contains -Text $mtpStep -Expected 'net48/*Tests.exe' -Message 'The MTP path must identify verified net48 test modules.'
Assert-Contains -Text $mtpStep -Expected 'is_mtp_coverage_supported_tfm' -Message 'Explicit project runs must distinguish supported coverage target frameworks.'
Assert-DoesNotContain -Text $mtpStep -Unexpected 'Microsoft.Testing.Extensions.CodeCoverage' -Message 'MTP must not depend on Microsoft code coverage.'
Assert-DoesNotContain -Text $mtpStep -Unexpected '--coverage-output-format' -Message 'MTP must not request Microsoft Cobertura coverage.'
Assert-DoesNotContain -Text $mtpStep -Unexpected ' --coverage ' -Message 'MTP must not enable Microsoft code coverage.'

$net48Block = [regex]::Match($mtpStep, '(?s)if \[ -n "\$net48_module" \]; then\s+found_modules=true(?<block>.*?)done < <\(find.*net48')
if (-not $net48Block.Success) {
  throw 'The net48 module execution block was not found.'
}
Assert-Contains -Text $net48Block.Groups['block'].Value -Expected '--coverlet --coverlet-output-format opencover' -Message 'Verified net48 runs must collect Coverlet OpenCover coverage.'
Assert-Contains -Text $net48Block.Groups['block'].Value -Expected '--hangdump-type-if-supported' -Message 'net48 hang dump types must use the runtime-aware MTP option.'

$otherFrameworkBlock = [regex]::Match($mtpStep, '(?s)if \[ -n "\$other_framework_module" \]; then(?<block>.*?)done < <\(find.*net4\*')
if (-not $otherFrameworkBlock.Success) {
  throw 'The other .NET Framework module execution block was not found.'
}
Assert-DoesNotContain -Text $otherFrameworkBlock.Groups['block'].Value -Unexpected '--coverlet' -Message 'Unverified .NET Framework targets must remain test-only for Coverlet.'

Write-Host 'Runner selection and coverage compatibility contracts passed.'
