$ErrorActionPreference = 'Stop'

$workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotnet-test-vstest-compatibility-$([guid]::NewGuid().ToString('N'))"
$targetDirectory = Join-Path $workspaceRoot 'CoverageTarget'
$testDirectory = Join-Path $workspaceRoot 'Vstest.Tests'
New-Item -ItemType Directory -Path $targetDirectory, $testDirectory | Out-Null

$targetProject = Join-Path $targetDirectory 'CoverageTarget.csproj'
$testProject = Join-Path $testDirectory 'Vstest.Tests.csproj'
$resultsDirectory = Join-Path $workspaceRoot 'TestResults'
Set-Content -LiteralPath (Join-Path $workspaceRoot 'global.json') -Value '{ "sdk": { "version": "10.0.401", "rollForward": "latestFeature" } }'

$targetProjectContent = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
'@

$testProjectContent = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <IsPackable>false</IsPackable>
    <IsTestProject>true</IsTestProject>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="18.10.0" />
    <PackageReference Include="xunit" Version="2.9.3" />
    <PackageReference Include="xunit.runner.visualstudio" Version="3.1.5" PrivateAssets="all" />
    <PackageReference Include="coverlet.collector" Version="10.0.1" PrivateAssets="all" />
    <ProjectReference Include="../CoverageTarget/CoverageTarget.csproj" />
  </ItemGroup>
</Project>
'@

$targetSource = @'
namespace CoverageTarget;

public static class MathOps
{
    public static int Adjust(int value)
    {
        if (value > 0)
        {
            return value + 1;
        }

        return value - 1;
    }
}
'@

$testSource = @'
using CoverageTarget;
using Xunit;

namespace Vstest.Tests;

public class CoverageTest
{
    [Fact]
    public void ShouldAdjustPositiveValues()
    {
        Assert.Equal(5, MathOps.Adjust(4));
    }
}
'@

[System.IO.File]::WriteAllText($targetProject, $targetProjectContent, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($testProject, $testProjectContent, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $targetDirectory 'MathOps.cs'), $targetSource, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $testDirectory 'CoverageTest.cs'), $testSource, [System.Text.UTF8Encoding]::new($false))

$previousLocation = Get-Location
try {
    Set-Location $workspaceRoot
    & dotnet test $testProject --configuration Release --logger trx --results-directory $resultsDirectory '--collect:XPlat Code Coverage;Format=opencover' -p:CoverletOutputFormat=opencover -p:UseSourceLink=true
    if ($LASTEXITCODE -ne 0) {
        throw "The VSTest Coverlet compatibility run failed with exit code $LASTEXITCODE."
    }

    $trxFiles = @(Get-ChildItem -LiteralPath $resultsDirectory -Filter '*.trx' -Recurse -File)
    $coverageFiles = @(Get-ChildItem -LiteralPath $resultsDirectory -Filter '*opencover*.xml' -Recurse -File)
    if ($trxFiles.Count -eq 0) {
        throw "The VSTest run did not produce TRX under '$resultsDirectory'."
    }
    if ($coverageFiles.Count -eq 0) {
        throw "The VSTest run did not produce OpenCover under '$resultsDirectory'."
    }

    $visitedSequencePoints = 0
    foreach ($coverageFile in $coverageFiles) {
        [xml] $coverage = Get-Content -LiteralPath $coverageFile.FullName -Raw
        $summary = $coverage.SelectSingleNode("//*[local-name()='Summary']")
        if ($null -eq $summary -or $coverageFile.Length -eq 0) {
            throw "OpenCover output is empty or malformed: $($coverageFile.FullName)"
        }
        $visitedSequencePoints += [int] $summary.visitedSequencePoints
    }

    if ($visitedSequencePoints -eq 0) {
        throw 'The VSTest OpenCover reports contained no covered sequence points.'
    }

    Write-Host "VSTest produced $($trxFiles.Count) TRX file(s) and $($coverageFiles.Count) OpenCover file(s) under '$resultsDirectory'."
}
finally {
    Set-Location $previousLocation

    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedWorkspace = [System.IO.Path]::GetFullPath($workspaceRoot)
    if (-not $resolvedWorkspace.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove VSTest compatibility path outside the temporary directory: $resolvedWorkspace"
    }
    Remove-Item -LiteralPath $resolvedWorkspace -Recurse -Force
}
