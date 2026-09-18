# .NET Test from Codebelt

Uses the .NET CLI `dotnet test` [command](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-test) that utilizes the test runner in the .NET SDK.

To have the best experience, it is recommended to use the reusable workflow [jobs-dotnet-test](https://github.com/codebeltnet/jobs-dotnet-test) that also provides additional features such as caching, test result publishing, and more.

Supports `projects` input we learned to appreciate from [AzDO DotNetCoreCLI](https://learn.microsoft.com/en-us/azure/devops/pipelines/tasks/reference/dotnet-core-cli-v2?view=azure-pipelines).

> This action is part of the Codebelt umbrella and ensures a consistent way of: 
> 
> - Defining your CI/CD pipeline 
> - Structuring your repository
> - Keeping your codebase small and feasible
> - Writing clean and maintainable code
> - Deploying your code to different environments
> - Automating as much as possible
>
> A paved path to excel as a DevSecOps Engineer.

## Usage

To use this action in your GitHub repository, you can follow these steps:

```yaml
uses: codebeltnet/dotnet-test@v4
```

### Inputs

```yaml
with:
  # Optional path to the project(s) file to test. Pass empty to test whole solution.
  # Supports globbing.
  projects: ''
  # Defines the build configuration.
  configuration: 'Release'
  # Sets the verbosity level of the command.
  # Allowed values are q[uiet], m[inimal], n[ormal], d[etailed], and diag[nostic]. 
  # The default is quiet.
  verbosity-level: 'quiet'
  # The name of the folder where the test results will be written.
  test-results-folder-name: 'TestResults'
  # Provides a way to fully customize the build. See https://learn.microsoft.com/en-us/visualstudio/msbuild/msbuild-command-line-reference?view=vs-2022#switches for more information.
  build-switches: ''
  # The time to wait for a test to complete before collecting a dump.
  blame-hang-timeout: '10m'
  # The type of dump to collect when a test hangs.
  blame-hang-dump-type: 'mini'
  # Whether to build the project(s) before testing. Default is false.
  build: 'false'
  # Whether to restore the project(s) before testing. Default is false.
  restore: 'false'
  # Additional arguments to pass to the test runner. Default is empty.
  test-arguments: ''
```

### Outputs

- `runner`: `vstest` or `mtp`, selected from the repository root `global.json`.
- `coverage-expected`: `true` when the run included a target framework expected to produce coverage; otherwise `false`.

### Test runner selection

The action reads `global.json` in the repository root. When `test.runner` is
`Microsoft.Testing.Platform`, it uses the .NET 10+ MTP test experience. Otherwise,
it uses the existing VSTest arguments. An invalid `global.json` fails the action.

The VSTest path retains its existing `coverlet.collector` OpenCover invocation,
including `--collect:"XPlat Code Coverage;Format=opencover"`. MTP runs produce
xUnit TRX reports and Coverlet OpenCover coverage. MTP test projects must provide
`--report-xunit-trx` support and reference `coverlet.MTP` for supported modern
.NET targets (Coverlet MTP supports .NET Core 8.0 and newer) and `net48`
(verified with `coverlet.MTP` 10.0.1). They must also
reference `Microsoft.Testing.Extensions.HangDump` 2.3.0 or newer for diagnostics.
The MTP coverage arguments are
`--coverlet --coverlet-output-format opencover`; the legacy hang inputs are
forwarded as `--hangdump-timeout` and `--hangdump-type`. .NET Framework runs use
`--hangdump-type-if-supported` so an unsupported `Triage` request falls back to
`Mini`. MTP HangDump uses a test-host inactivity timeout, so its hang detection
can differ from VSTest's blame behavior.

With `projects` specified, the action evaluates each project's target frameworks
and runs `dotnet test --project --framework` for each one. It honors the `build`,
`restore`, and `build-switches` inputs on every target. Coverlet coverage is
requested for supported modern .NET targets and `net48`; other .NET Framework
targets still run and produce TRX without Coverlet coverage. With `projects` empty, MTP runs
already-built `*Tests.dll` modules under `bin/<configuration>/net*.0/` and
`*Tests.exe` modules under `bin/<configuration>/net4*/`. That module-discovery
path does not apply `build`, `restore`, or `build-switches`; callers must prepare
the modules first, as the reusable workflow does. Supported .NET Core 8.0+
modules collect OpenCover; older modern .NET modules run test-only. `net48`
modules collect OpenCover with Coverlet.MTP 10.0.1, and other .NET Framework
modules remain test-only. No matching modules is an error.

For MTP, `test-arguments` are forwarded after the `dotnet test` `--` separator.
For VSTest, the existing argument forwarding is unchanged. All results are
written under `runner.temp/<test-results-folder-name>`; callers own report
publishing.

Run the deterministic runner and argument contract checks with
`pwsh -NoProfile -File tests/Test-ActionContract.ps1`. Run the VSTest collector
smoke test with `pwsh -NoProfile -File tests/Test-VSTestCompatibility.ps1`; it
restores a temporary test project and checks for TRX and non-empty OpenCover.

## Examples

### Test all projects in the test folder

```yaml
- name: Test with Release build
  uses: codebeltnet/dotnet-test@v4
  with:
    configuration: Release
```

## Caller workflows to showcase the Codebelt experience

### Basic CI/CD Pipeline

- Bootstrapper API - https://github.com/codebeltnet/bootstrapper/blob/main/.github/workflows/pipelines.yml
- Extensions for Asp.Versioning API - https://github.com/codebeltnet/asp-versioning/blob/main/.github/workflows/pipelines.yml
- Extensions for AWS Signature Version 4 API - https://github.com/codebeltnet/aws-signature-v4/blob/main/.github/workflows/pipelines.yml
- Extensions for Globalization API - https://github.com/codebeltnet/globalization/blob/main/.github/workflows/pipelines.yml
- Extensions for Newtonsoft.Json API - https://github.com/codebeltnet/newtonsoft-json/blob/main/.github/workflows/pipelines.yml
- Extensions for Swashbuckle.AspNetCore API - https://github.com/codebeltnet/swashbuckle-aspnetcore/blob/main/.github/workflows/pipelines.yml
- Extensions for xUnit API - https://github.com/codebeltnet/xunit/blob/main/.github/workflows/pipelines.yml
- Extensions for YamlDotNet API - https://github.com/codebeltnet/yamldotnet/blob/main/.github/workflows/pipelines.yml
- Shared Kernel API - https://github.com/codebeltnet/shared-kernel/blob/main/.github/workflows/pipelines.yml
- Unitify API - https://github.com/codebeltnet/unitify/blob/main/.github/workflows/pipelines.yml

### Intermediate CI/CD Pipeline

- Savvy I/O - https://github.com/codebeltnet/savvyio/blob/main/.github/workflows/pipelines.yml

### Advanced CI/CD Pipeline

- Cuemon for .NET - https://github.com/gimlichael/Cuemon/blob/main/.github/workflows/pipelines.yml

## Contributing to .NET Test from Codebelt

Contributions are welcome! 
Feel free to submit issues, feature requests, or pull requests to help improve this action.

### License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

> [!TIP]
> To learn more about the Codebelt experience and offerings, visit our [organization page](https://github.com/codebeltnet) on GitHub.
