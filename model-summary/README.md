# Model Summary Knowledge Base

This folder contains comprehensive learning materials and configuration for an MCP server that intelligently switches between Claude models based on task characteristics.

## Files Overview

### 1. **claude-opus.md**
Detailed profile of Claude Opus (most capable model)
- Strengths: Complex reasoning, creative work, specialized domains
- Weaknesses: Slowest, most expensive
- Best for: Research, complex refactoring, strategic planning
- **Use when: Quality and correctness matter more than speed/cost**

### 2. **claude-sonnet.md**
Detailed profile of Claude Sonnet (balanced model)
- Strengths: Good reasoning, moderate speed/cost balance
- Weaknesses: Not ideal for extreme real-time or complex tasks
- Best for: Production apps, general coding, business analysis
- **Use when: No specific constraint, best default choice**

### 3. **claude-haiku.md**
Detailed profile of Claude Haiku (fastest model)
- Strengths: Fastest, cheapest, real-time capable
- Weaknesses: Limited reasoning, shallow analysis
- Best for: Chatbots, classification, simple Q&A
- **Use when: Speed and cost are critical**

### 4. **routing-guide.md**
Quick reference guide for model selection
- Decision tree for choosing the right model
- Task complexity assessment framework
- Performance characteristics comparison table
- MCP routing rules and fallback logic
- **Use this to implement the routing logic in your MCP server**

### 5. **models-config.json**
Structured configuration file for programmatic model selection
- Model characteristics (latency, cost, capabilities)
- Routing rules based on constraints
- Task profiles with recommended models
- **Use this in your MCP server code for automatic model selection**

## Implementation Approach

### For MCP Server Router

The MCP server should:

1. **Accept task input with metadata:**
   ```json
   {
     "task": "user request text",
     "constraints": {
       "latency_ms": 500,  // optional
       "max_cost": 0.10,   // optional
       "domain": "coding"  // optional
     }
   }
   ```

2. **Apply routing logic (in order):**
   - Check latency constraint first
   - Assess reasoning complexity
   - Consider volume and cost
   - Default to Sonnet if unsure

3. **Select model** from `models-config.json`

4. **Execute** with selected model

### Decision Matrix

```
Latency < 300ms?
├─ YES → Use Haiku
└─ NO → Task complex?
        ├─ YES (4+ steps) → Use Opus
        ├─ NO (1-2 steps) → Use Haiku
        └─ MEDIUM (2-4 steps) → Use Sonnet (default)
```

### Example Routing Scenarios

| Scenario | Recommendation | Reasoning |
|----------|---|---|
| Chat response needed in 100ms | Haiku | Speed critical |
| Standard code generation | Sonnet | Good balance, no constraints |
| Multi-file architectural refactoring | Opus | Complex reasoning required |
| Sentiment analysis of 1000 texts | Haiku | High volume, simple task |
| Document summarization | Sonnet | Medium complexity, no time pressure |
| Research paper synthesis | Opus | Deep analysis, quality critical |

## Extending This Knowledge Base

To add new task types or refine recommendations:

1. Document task profile in this folder (e.g., `task-email-generation.md`)
2. Update `routing-guide.md` with new task examples
3. Add entry to `models-config.json` task_profiles section
4. Re-evaluate existing routing rules if patterns change

## Quick Facts for Integration

- **Default model**: Sonnet (best overall value)
- **Fastest model**: Haiku (50-150ms latency)
- **Most capable**: Opus (best for edge cases)
- **Cost ratio**: Haiku:Sonnet:Opus ≈ 1:3.75:18.75
- **Quality ratio**: Haiku:Sonnet:Opus ≈ 1:3:5

---

This knowledge base serves as the foundation for intelligent model selection and should be referenced when implementing the MCP server's routing logic.
