# Auto Model Selector for Claude Code

A custom MCP (Model Context Protocol) server written in C# that automatically selects the appropriate Claude model (Haiku, Sonnet, or Opus) based on task type, file size, and user prompt complexity.

## Goal

This MCP server provides a "chooseModel" tool that returns a JSON response indicating which Claude model to use for the next action. Claude Code can then route requests to the selected model, optimizing token usage by avoiding unnecessary Opus calls for simple tasks.

## Features

- **chooseModel Tool**: Takes `userPrompt` (string), `fileSize` (int), and `taskType` (string) as inputs
- **Intelligent Routing**: Uses model summaries from `model-summary/` folder for data-driven decisions
- **Dynamic Model IDs**: Loads current model identifiers from configuration
- **Lightweight**: No file content required, only metadata
- **MCP Compliant**: Built with official ModelContextProtocol SDK
- **Configurable**: Supports both structured config and fallback logic

## Model Selection Logic

The server now uses the `model-summary` folder for intelligent model selection:

- **Loads model configurations** from `model-summary/models-config.json` for available models and their characteristics
- **Implements routing logic** based on the `routing-guide.md` decision tree:
  - **Haiku**: For low-complexity tasks (<500 lines) and simple operations (explain, summarize, comment, format)
  - **Sonnet**: Default for medium-complexity tasks (500-5000 lines) and standard coding/business tasks
  - **Opus**: For high-complexity tasks (>5000 lines) and architecture-level reasoning (design, research, complex analysis)
- **Fallback**: Uses hardcoded model names if config file is not found

## Project Structure

```
AutoModelSelectorMCP/
├── Program.cs          # Server bootstrap and hosting
├── Tools.cs            # MCP tool definitions with config loading
├── config.json         # Legacy configuration file (optional)
└── AutoModelSelectorMCP.csproj  # Project file

model-summary/
├── README.md           # Overview of model summaries
├── routing-guide.md    # Decision tree for model selection
├── models-config.json  # Structured model configurations
├── claude-haiku.md     # Detailed Haiku profile
├── claude-sonnet.md    # Detailed Sonnet profile
└── claude-opus.md      # Detailed Opus profile
```

## Prerequisites

- .NET 8.0 or later
- Claude Code installed and authenticated

## Build Instructions

1. Navigate to the project directory:
   ```bash
   cd AutoModelSelectorMCP
   ```

2. Restore dependencies:
   ```bash
   dotnet restore
   ```

3. Build the project:
   ```bash
   dotnet build
   ```

## Running the Server

To run the server manually for testing:
```bash
dotnet run
```

The server uses stdio transport and will listen for MCP protocol messages.

## Loading and Updating Model Summaries

The MCP server loads model metadata from `model-summary/model-summary/models-config.json` at runtime. You can update that file when new models or versions are released without changing the C# code.

- Edit `model-summary/model-summary/models-config.json` to add new models, update model IDs, or adjust versioned model names.
- The config now includes metadata such as `metadata.summaryCreatedByModel` and `metadata.summaryCreatedAt`, plus per-model `summaryAboutModel` values so you can track which specific model/version each summary is about.
- Optionally set `MODEL_SUMMARY_CONFIG_PATH` to a custom file or directory if your summary files live outside the repository.
- Use the `ReloadModelSummaries` tool to refresh the loaded configuration from disk.
- Use the `GetAvailableModels` tool to verify which model IDs are currently loaded.

Example:
```bash
claude mcp ...
```

## Connecting to Claude Code

1. **Add the MCP Server**:
   From your terminal (not inside Claude Code), run:
   ```bash
   claude mcp add --transport stdio auto-model-selector -- dotnet /path/to/AutoModelSelectorMCP.dll
   ```
   Replace `/path/to/AutoModelSelectorMCP.dll` with the absolute path to your compiled DLL (e.g., `E:\dev\Auto-model-selector-for-Claude\AutoModelSelectorMCP\bin\Debug\net10.0\AutoModelSelectorMCP.dll`).

   For project scope (recommended for team sharing):
   ```bash
   claude mcp add --scope project --transport stdio auto-model-selector -- dotnet /path/to/AutoModelSelectorMCP.dll
   ```

2. **Start Claude Code**:
   In your project directory:
   ```bash
   claude
   ```

3. **Verify Connection**:
   Inside Claude Code, run `/mcp` to see connected servers. Your server should appear as "connected".

4. **Test the Tool**:
   You can now use the `chooseModel` tool. For example, Claude Code might invoke it automatically or you can test by prompting Claude to use the tool.

## Tool Specification

### chooseModel Tool

**Inputs**:
- `userPrompt` (string): The user's prompt describing the task
- `fileSize` (int): The size of the file in lines
- `taskType` (string): The type of task (e.g., "edit", "refactor", "explain", "generate")

**Output**:
A JSON object:
```json
{
  "model": "claude-3.7-haiku" | "claude-3.7-sonnet" | "claude-3.7-opus"
}
```

**Example Usage**:
- Input: `userPrompt="Quickly explain this function"`, `fileSize=50`, `taskType="explain"`
- Output: `{"model": "claude-3.7-haiku"}`

## Configuration

The `config.json` file allows tuning of the selection thresholds and keywords. Currently, the logic is hardcoded in `Tools.cs`, but you can extend the code to load this configuration.

Example `config.json`:
```json
{
  "haiku": {
    "fileSizeMax": 500,
    "taskTypes": ["explain", "summarize", "comment"],
    "promptKeywords": ["quick", "simple", "small"]
  },
  "sonnet": {
    "fileSizeMin": 500,
    "fileSizeMax": 5000,
    "taskTypes": ["refactor", "generate", "improve"],
    "promptKeywords": ["optimize", "rewrite", "clean up"]
  },
  "opus": {
    "fileSizeMin": 5000,
    "taskTypes": [],
    "promptKeywords": ["architecture", "design", "deep analysis", "system-wide", "multi-file"]
  },
  "defaultModel": "claude-3.7-haiku"
}
```

## Publishing to NuGet

To prepare for NuGet publication:

1. Update the project file with package metadata:
   ```xml
   <PropertyGroup>
     <PackageId>AutoModelSelectorMCP</PackageId>
     <Version>1.0.0</Version>
     <Authors>Your Name</Authors>
     <Description>A MCP server for auto-selecting Claude models</Description>
   </PropertyGroup>
   ```

2. Build and pack:
   ```bash
   dotnet pack -c Release
   ```

3. Publish:
   ```bash
   dotnet nuget push bin/Release/AutoModelSelectorMCP.1.0.0.nupkg -k YOUR_API_KEY -s https://api.nuget.org/v3/index.json
   ```

## Troubleshooting

- **Server not connecting**: Ensure the DLL path is correct and `dotnet` is in your PATH. Test by running the server manually.
- **Tool not found**: Run `/mcp` in Claude Code to check server status. Try `/reload-plugins`.
- **Errors in logic**: Check the console output when running the server manually for debugging.

## License

[Add your license here]