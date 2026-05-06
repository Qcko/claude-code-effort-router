using ModelContextProtocol.Server;
using System.ComponentModel;
using System.Text.Json;
using System.IO;
using System.Linq;
using System.Collections.Generic;

// Define config classes
public class ModelsConfig
{
    public Dictionary<string, ModelConfig> Models { get; set; } = new();
    public SummaryMetadata? Metadata { get; set; }
}

public class SummaryMetadata
{
    public string? SummaryCreatedByModel { get; set; }
    public string? SummaryCreatedAt { get; set; }
    public string? SummaryNotes { get; set; }
}

public class ModelConfig
{
    public string Id { get; set; } = string.Empty;
    public string? DisplayName { get; set; }
    public string? SummaryAboutModel { get; set; }
    public List<string> IdealFor { get; set; } = new();
}

// Mark the class as containing tools
[McpServerToolType]
public static class AutoModelSelectorTools
{
    private static readonly object _configLock = new();
    private static ModelsConfig? _config;
    private static string? _loadedConfigPath;
    private static DateTime _loadedConfigLastWriteUtc;

    private static string? GetModelConfigPath()
    {
        string? envPath = Environment.GetEnvironmentVariable("MODEL_SUMMARY_CONFIG_PATH");
        if (!string.IsNullOrWhiteSpace(envPath))
        {
            if (Directory.Exists(envPath))
            {
                envPath = Path.Combine(envPath, "models-config.json");
            }

            if (!string.IsNullOrWhiteSpace(envPath) && File.Exists(envPath))
            {
                return Path.GetFullPath(envPath);
            }
        }

        var candidates = new[]
        {
            Path.Combine(Directory.GetCurrentDirectory(), "model-summary", "model-summary", "models-config.json"),
            Path.Combine(Directory.GetCurrentDirectory(), "model-summary", "models-config.json"),
            Path.Combine(AppContext.BaseDirectory, "model-summary", "model-summary", "models-config.json"),
            Path.Combine(AppContext.BaseDirectory, "..", "..", "model-summary", "model-summary", "models-config.json"),
            Path.Combine(AppContext.BaseDirectory, "..", "model-summary", "model-summary", "models-config.json")
        };

        return candidates.FirstOrDefault(File.Exists);
    }

    private static ModelsConfig? LoadConfig(bool forceReload = false)
    {
        lock (_configLock)
        {
            string? configPath = GetModelConfigPath();
            if (configPath == null)
            {
                return null;
            }

            var lastWrite = File.GetLastWriteTimeUtc(configPath);
            if (!forceReload && _config != null && _loadedConfigPath == configPath && lastWrite == _loadedConfigLastWriteUtc)
            {
                return _config;
            }

            string json = File.ReadAllText(configPath);
            var config = JsonSerializer.Deserialize<ModelsConfig>(json, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });

            if (config != null)
            {
                _config = config;
                _loadedConfigPath = configPath;
                _loadedConfigLastWriteUtc = lastWrite;
            }

            return _config;
        }
    }

    private static string GetModelId(string key)
    {
        var config = LoadConfig();
        return config?.Models.TryGetValue(key, out var model) == true && !string.IsNullOrEmpty(model.Id)
            ? model.Id
            : key switch
            {
                "haiku" => "claude-3.7-haiku",
                "sonnet" => "claude-3.7-sonnet",
                "opus" => "claude-3.7-opus",
                _ => "claude-3.7-sonnet"
            };
    }

    // Define the chooseModel tool
    [McpServerTool, Description("Chooses the appropriate Claude model based on user prompt, file size, and task type.")]
    public static string ChooseModel(
        [Description("The user's prompt describing the task")] string userPrompt,
        [Description("The size of the file in lines")] int fileSize,
        [Description("The type of task: edit, refactor, explain, generate, etc.")] string taskType)
    {
        var lowComplexityTokens = new[] { "explain", "summarize", "comment", "format", "classify", "simple", "quick" };
        var highComplexityTokens = new[] { "architecture", "design", "research", "complex", "strategic", "creative", "deep analysis", "system-wide", "multi-file" };

        string task = taskType?.ToLowerInvariant() ?? string.Empty;
        string prompt = userPrompt?.ToLowerInvariant() ?? string.Empty;

        string modelId;
        if (fileSize < 500 && lowComplexityTokens.Any(token => task.Contains(token) || prompt.Contains(token)))
        {
            modelId = GetModelId("haiku");
        }
        else if (fileSize > 5000 || highComplexityTokens.Any(token => task.Contains(token) || prompt.Contains(token)))
        {
            modelId = GetModelId("opus");
        }
        else
        {
            modelId = GetModelId("sonnet");
        }

        var result = new { model = modelId };
        return JsonSerializer.Serialize(result);
    }

    [McpServerTool, Description("Reloads model summary configuration from disk so new models or versions can be picked up without recompiling.")]
    public static string ReloadModelSummaries()
    {
        var config = LoadConfig(forceReload: true);
        var result = new
        {
            success = config != null,
            loadedModels = config?.Models?.Keys.ToArray() ?? Array.Empty<string>(),
            configPath = _loadedConfigPath ?? "not found",
            metadata = config?.Metadata
        };

        return JsonSerializer.Serialize(result);
    }

    [McpServerTool, Description("Returns the currently loaded models and their IDs from the model summary configuration.")]
    public static string GetAvailableModels()
    {
        var config = LoadConfig();
        var result = new
        {
            configLoaded = config != null,
            models = config?.Models?.ToDictionary(kvp => kvp.Key, kvp => new
            {
                kvp.Value.Id,
                kvp.Value.SummaryAboutModel
            }),
            metadata = config?.Metadata
        };

        return JsonSerializer.Serialize(result);
    }
}
