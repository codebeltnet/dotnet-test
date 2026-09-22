$ErrorActionPreference = 'Stop'

$actionPath = Join-Path $PSScriptRoot '..\action.yml'

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

function Assert-Equal {
  param(
    $Actual,
    $Expected,
    [string] $Message
  )

  if ($Actual -ne $Expected) {
    throw "$Message Expected: $Expected Actual: $Actual"
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

function Resolve-InputExpressions {
  param(
    [string] $Script,
    [hashtable] $Inputs
  )

  $resolved = $Script
  foreach ($entry in $Inputs.GetEnumerator()) {
    $resolved = $resolved.Replace('${{ inputs.' + $entry.Key + ' }}', [string] $entry.Value)
  }
  return $resolved
}

function Convert-ToBashPath {
  param([string] $Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if ($IsWindows) {
    $escapedPath = $fullPath
    $convertedPath = & bash -lc "if command -v wslpath >/dev/null 2>&1; then wslpath -a '$escapedPath'; elif command -v cygpath >/dev/null 2>&1; then cygpath -u '$escapedPath'; else printf '%s\n' '$escapedPath'; fi"
    if ($LASTEXITCODE -ne 0) {
      throw "Could not convert '$fullPath' to a bash path."
    }
    return ([string[]] $convertedPath)[0].Trim()
  }

  return $fullPath.Replace('\', '/')
}

function Write-Utf8NoBomFile {
  param(
    [string] $Path,
    [string] $Content
  )

  $normalizedContent = $Content -replace "`r?`n", "`n"
  [System.IO.File]::WriteAllText($Path, $normalizedContent, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-MtpProjectScenario {
  param(
    [hashtable] $Projects,
    [string] $ProjectsInput,
    [int] $ExpectedParallelStarts,
    [string] $FailFramework = '',
    [int] $FailExitCode = 23,
    [hashtable] $FrameworkDelays = @{},
    [string] $Build = 'false',
    [string] $Restore = 'false'
  )

  $mtpScript = Get-RunScript -StepName 'Test with Microsoft.Testing.Platform'
  $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotnet-test-mtp-contract-$([guid]::NewGuid().ToString('N'))"
  $traceDirectory = Join-Path $workspaceRoot 'trace'
  $frameworkMapDirectory = Join-Path $workspaceRoot 'frameworks'
  $fakeBinDirectory = Join-Path $workspaceRoot 'fake-bin'
  $runnerTempDirectory = Join-Path $workspaceRoot 'runner-temp'
  $outputPath = Join-Path $workspaceRoot 'github-output.txt'
  $stepScriptPath = Join-Path $workspaceRoot 'run-step.sh'
  $invokeScriptPath = Join-Path $workspaceRoot 'invoke-step.sh'

  New-Item -ItemType Directory -Path $traceDirectory, $frameworkMapDirectory, $fakeBinDirectory, $runnerTempDirectory | Out-Null

  foreach ($entry in $Projects.GetEnumerator()) {
    $projectRelativePath = $entry.Key.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $projectPath = Join-Path $workspaceRoot $projectRelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $projectPath) -Force | Out-Null
    Write-Utf8NoBomFile -Path $projectPath -Content '<Project Sdk="Microsoft.NET.Sdk" />'
    Write-Utf8NoBomFile -Path (Join-Path $frameworkMapDirectory ([System.IO.Path]::GetFileName($projectPath) + '.txt')) -Content ([string] $entry.Value)
  }

  $resolvedScript = Resolve-InputExpressions -Script $mtpScript -Inputs @{
    'projects' = $ProjectsInput
    'restore' = $Restore
    'build' = $Build
    'configuration' = 'Release'
    'verbosity-level' = 'quiet'
    'test-results-folder-name' = 'TestResults'
    'build-switches' = ''
    'blame-hang-timeout' = '10m'
    'blame-hang-dump-type' = 'mini'
    'test-arguments' = ''
  }

  $fakeDotnetScript = @'
#!/usr/bin/env bash
set -euo pipefail

trace_dir="${DOTNET_TEST_TRACE_DIR:?}"
framework_map_dir="${DOTNET_TEST_FRAMEWORK_MAP_DIR:?}"

command_name="$1"
shift

if [ "$command_name" = "msbuild" ]; then
  project="$1"
  framework_map_file="$framework_map_dir/$(basename "$project").txt"
  if [ ! -f "$framework_map_file" ]; then
    echo "Missing framework map for '$project'." >&2
    exit 31
  fi
  cat "$framework_map_file"
  exit 0
fi

if [ "$command_name" = "restore" ] || [ "$command_name" = "build" ]; then
  project="$1"
  printf '%s|%s\n' "$command_name" "$(basename "$project")" >> "$trace_dir/prep.log"
  exit 0
fi

if [ "$command_name" != "test" ]; then
  echo "Unsupported fake dotnet command: $command_name" >&2
  exit 32
fi

project=""
framework=""
results_directory=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      project="$2"
      shift 2
      ;;
    --framework)
      framework="$2"
      shift 2
      ;;
    --results-directory)
      results_directory="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "$project" ] || [ -z "$framework" ] || [ -z "$results_directory" ]; then
  echo "Fake dotnet test expected --project, --framework, and --results-directory." >&2
  exit 33
fi

project_name="$(basename "$project" .csproj)"
touch "$trace_dir/started-$framework"
printf '%s|%s|%s\n' "$project_name" "$framework" "$results_directory" >> "$trace_dir/test-runs.log"

expected_starts="${DOTNET_TEST_EXPECTED_PARALLEL_STARTS:-1}"
if [ "$expected_starts" -gt 1 ]; then
  deadline=$((SECONDS + 8))
  while [ "$(find "$trace_dir" -maxdepth 1 -name 'started-*' | wc -l | tr -d ' ')" -lt "$expected_starts" ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "Timed out waiting for $expected_starts framework run(s) to start." >&2
      exit 97
    fi
    sleep 0.05
  done
fi

delay_var_name="DOTNET_TEST_DELAY_${framework//[^[:alnum:]]/_}"
delay_seconds="${!delay_var_name:-0.05}"
sleep "$delay_seconds"

mkdir -p "$results_directory"
printf 'TRX for %s (%s)\n' "$project_name" "$framework" > "$results_directory/$project_name-$framework.trx"

if [ "${DOTNET_TEST_FAIL_FRAMEWORK:-}" = "$framework" ]; then
  echo "$framework" > "$trace_dir/failed-$framework"
  exit "${DOTNET_TEST_FAIL_EXIT_CODE:-23}"
fi

echo "$framework" > "$trace_dir/completed-$framework"
'@
Write-Utf8NoBomFile -Path (Join-Path $fakeBinDirectory 'dotnet') -Content $fakeDotnetScript

$stepScriptContent = @"
#!/usr/bin/env bash
$resolvedScript
"@
Write-Utf8NoBomFile -Path $stepScriptPath -Content $stepScriptContent

  $frameworkDelayExports = foreach ($entry in $FrameworkDelays.GetEnumerator()) {
    $variableName = 'DOTNET_TEST_DELAY_' + ($entry.Key -replace '[^A-Za-z0-9]', '_')
    "export $variableName='$($entry.Value)'"
  }

  $invokeScriptContent = @"
#!/usr/bin/env bash
set -euo pipefail
export PATH='$(Convert-ToBashPath $fakeBinDirectory)':"`$PATH"
export RUNNER_TEMP='$(Convert-ToBashPath $runnerTempDirectory)'
export GITHUB_OUTPUT='$(Convert-ToBashPath $outputPath)'
export DOTNET_TEST_TRACE_DIR='$(Convert-ToBashPath $traceDirectory)'
export DOTNET_TEST_FRAMEWORK_MAP_DIR='$(Convert-ToBashPath $frameworkMapDirectory)'
export DOTNET_TEST_EXPECTED_PARALLEL_STARTS='$ExpectedParallelStarts'
export DOTNET_TEST_FAIL_FRAMEWORK='$FailFramework'
export DOTNET_TEST_FAIL_EXIT_CODE='$FailExitCode'
$(($frameworkDelayExports -join "`n"))
cd '$(Convert-ToBashPath $workspaceRoot)'
bash '$(Convert-ToBashPath $stepScriptPath)'
"@
  Write-Utf8NoBomFile -Path $invokeScriptPath -Content $invokeScriptContent

  & bash -lc "chmod +x '$(Convert-ToBashPath (Join-Path $fakeBinDirectory 'dotnet'))' '$(Convert-ToBashPath $stepScriptPath)' '$(Convert-ToBashPath $invokeScriptPath)'"

  $outputText = ''
  $exitCode = 0
  try {
    $output = & bash (Convert-ToBashPath $invokeScriptPath) 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = [string]::Join("`n", [string[]] $output)

    $testRuns = @()
    $testRunsPath = Join-Path $traceDirectory 'test-runs.log'
    if (Test-Path -LiteralPath $testRunsPath) {
      $testRuns = Get-Content -LiteralPath $testRunsPath | ForEach-Object {
        $parts = $_ -split '\|', 3
        [pscustomobject]@{
          ProjectName = $parts[0]
          Framework = $parts[1]
          ResultsDirectory = $parts[2]
        }
      }
    }

    $prepLog = @()
    $prepLogPath = Join-Path $traceDirectory 'prep.log'
    if (Test-Path -LiteralPath $prepLogPath) {
      $prepLog = Get-Content -LiteralPath $prepLogPath
    }

    $completedFrameworks = @(
      Get-ChildItem -LiteralPath $traceDirectory -Filter 'completed-*' -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.Name.Substring('completed-'.Length) }
    )

    $failedFrameworks = @(
      Get-ChildItem -LiteralPath $traceDirectory -Filter 'failed-*' -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.Name.Substring('failed-'.Length) }
    )

    $githubOutput = ''
    if (Test-Path -LiteralPath $outputPath) {
      $githubOutput = Get-Content -LiteralPath $outputPath -Raw
    }

    return [pscustomobject]@{
      ExitCode = $exitCode
      OutputText = $outputText
      TestRuns = $testRuns
      PrepLog = $prepLog
      CompletedFrameworks = $completedFrameworks
      FailedFrameworks = $failedFrameworks
      GitHubOutput = $githubOutput
    }
  }
  finally {
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedWorkspaceRoot = [System.IO.Path]::GetFullPath($workspaceRoot)
    if (-not $resolvedWorkspaceRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove MTP execution-test path outside the temporary directory: $resolvedWorkspaceRoot"
    }
    Remove-Item -LiteralPath $resolvedWorkspaceRoot -Recurse -Force
  }
}

$parallelResult = Invoke-MtpProjectScenario -Projects @{
  'test/MultiTarget.Tests/MultiTarget.Tests.csproj' = 'net10.0;net9.0;net48'
} -ProjectsInput 'test/MultiTarget.Tests/MultiTarget.Tests.csproj' -ExpectedParallelStarts 3

if ($parallelResult.ExitCode -ne 0) {
  throw "Parallel MTP project execution must succeed when all child runs succeed. ExitCode: $($parallelResult.ExitCode)`nOutput:`n$($parallelResult.OutputText)"
}
Assert-Equal -Actual $parallelResult.TestRuns.Count -Expected 3 -Message 'Every resolved target framework must trigger its own dotnet test invocation.'
Assert-Contains -Text $parallelResult.OutputText -Expected 'Running 3 Microsoft.Testing.Platform project/target-framework invocation(s) in parallel' -Message 'Multi-target project runs must be launched in parallel when build and restore are disabled.'
Assert-Contains -Text $parallelResult.GitHubOutput -Expected 'coverage-expected=true' -Message 'Supported MTP target frameworks must continue marking coverage as expected.'

$parallelResultDirectories = @($parallelResult.TestRuns | Select-Object -ExpandProperty ResultsDirectory)
Assert-Equal -Actual (@($parallelResultDirectories | Sort-Object -Unique).Count) -Expected 3 -Message 'Each framework run must use a unique results directory.'
foreach ($run in $parallelResult.TestRuns) {
  $expectedSuffix = "/TestResults/$($run.Framework)/$($run.ProjectName)"
  if (-not $run.ResultsDirectory.EndsWith($expectedSuffix)) {
    throw "Results for '$($run.ProjectName)' ($($run.Framework)) must end with '$expectedSuffix', but were '$($run.ResultsDirectory)'."
  }
}

$failureResult = Invoke-MtpProjectScenario -Projects @{
  'test/MultiTarget.Tests/MultiTarget.Tests.csproj' = 'net9.0;net10.0;net48'
} -ProjectsInput 'test/MultiTarget.Tests/MultiTarget.Tests.csproj' -ExpectedParallelStarts 3 -FailFramework 'net9.0' -FailExitCode 23 -FrameworkDelays @{
  'net9.0' = '0.10'
  'net10.0' = '2.00'
  'net48' = '0.10'
}

Assert-Equal -Actual $failureResult.ExitCode -Expected 23 -Message 'A failed child MTP target-framework run must fail the action with a non-zero exit code.'
Assert-Contains -Text $failureResult.OutputText -Expected "::error::Test run failed for 'test/MultiTarget.Tests/MultiTarget.Tests.csproj' (net9.0)" -Message 'Failure logs must retain project and framework context.'
if (-not ($failureResult.CompletedFrameworks -contains 'net10.0')) {
  throw "The action must wait for slower background framework runs before exiting on a different framework failure.`nCompleted: $($failureResult.CompletedFrameworks -join ', ')`nOutput:`n$($failureResult.OutputText)"
}
if (-not ($failureResult.CompletedFrameworks -contains 'net48')) {
  throw "The action must wait for every background framework run before exiting on failure.`nCompleted: $($failureResult.CompletedFrameworks -join ', ')`nOutput:`n$($failureResult.OutputText)"
}
if (-not ($failureResult.FailedFrameworks -contains 'net9.0')) {
  throw 'The failing framework run was not recorded by the deterministic fake dotnet harness.'
}

$singleFrameworkResult = Invoke-MtpProjectScenario -Projects @{
  'test/SingleTarget.Tests/SingleTarget.Tests.csproj' = 'net10.0'
} -ProjectsInput 'test/SingleTarget.Tests/SingleTarget.Tests.csproj' -ExpectedParallelStarts 1

if ($singleFrameworkResult.ExitCode -ne 0) {
  throw "Single-target project execution must continue succeeding. ExitCode: $($singleFrameworkResult.ExitCode)`nOutput:`n$($singleFrameworkResult.OutputText)"
}
Assert-Equal -Actual $singleFrameworkResult.TestRuns.Count -Expected 1 -Message 'Single-target projects must still execute exactly one dotnet test invocation.'
Assert-DoesNotContain -Text $singleFrameworkResult.OutputText -Unexpected 'invocation(s) in parallel' -Message 'Single-target project execution must remain non-parallel.'
Assert-DoesNotContain -Text $singleFrameworkResult.OutputText -Unexpected 'Launching test run for' -Message 'Single-target project execution must keep the direct serial logging path.'
Assert-Contains -Text $singleFrameworkResult.OutputText -Expected "Tested and written results for 'test/SingleTarget.Tests/SingleTarget.Tests.csproj' (net10.0)" -Message 'Single-target project completion logging must remain unchanged.'

Write-Host 'MTP explicit-project execution contracts passed.'
