# .NET Test

Uses the .NET CLI `dotnet test` [command](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-test) that utilizes the test runner in the .NET SDK.

Uploaded artifacts will follow the convention `{coverageReportFolderName}-{configuration}-{os}` and `{testResultsFolderName}-{configuration}-{os}`.

Supports `projects` input we learned to appreciate from [AzDO DotNetCoreCLI](https://learn.microsoft.com/en-us/azure/devops/pipelines/tasks/reference/dotnet-core-cli-v2?view=azure-pipelines).

> This action is part of the Codebelt ecosystem and ensures a consistent way of: 
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
uses: codebeltnet/dotnet-test@main
```

### Inputs

```yaml
with:
  # Optional path to the project(s) file to test. Pass empty to test whole solution.
  # Supports globbing.
  projects: 'test/**/*.csproj'
  # Defines the build configuration.
  configuration: 'Release'
  # Sets the verbosity level of the command.
  # Allowed values are q[uiet], m[inimal], n[ormal], d[etailed], and diag[nostic]. 
  # The default is quiet.
  level: 'quiet'
  # The name of the folder where the coverage report will be written.
  coverageReportFolderName: 'Coverage'
  # The name of the folder where the test results will be written.
  testResultsFolderName: 'TestResults'
  # Provides a way to fully customize the build. See https://learn.microsoft.com/en-us/visualstudio/msbuild/msbuild-command-line-reference?view=vs-2022#switches for more information.
  buildSwitches: ''
```

### Outputs

This action has no outputs.

## Examples

### Test all projects in the test folder

```yaml
- name: Test with Release build
  uses: codebeltnet/dotnet-test@main
  with:
    configuration: Release
```

## Contributing to .NET Test

Contributions are welcome! 
Feel free to submit issues, feature requests, or pull requests to help improve this action.

### License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
