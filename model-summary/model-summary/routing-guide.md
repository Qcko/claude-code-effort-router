# Model Selection Guide for MCP Server

## Quick Decision Tree

### Use **Haiku** when:
- Response must be < 1 second
- Cost is primary concern
- Task is straightforward and well-defined
- High volume / high throughput required
- Real-time interactivity needed
- Simple classification or formatting task
- Mobile or bandwidth-constrained environment

### Use **Sonnet** when:
- Balance needed between speed, cost, and quality
- Production application with moderate complexity
- Code generation or general technical task
- No specific latency requirement (< 5 seconds OK)
- Volume is moderate to high
- Most business/operational tasks
- **Default choice when unsure**

### Use **Opus** when:
- Highest quality output required regardless of cost/speed
- Complex multi-step reasoning needed
- Novel or edge-case scenario
- Deep analysis or research task
- Complex code architecture decisions
- Creative high-quality content needed
- Specialized domain expertise required
- Quality worth 5-10x cost premium

## Task Complexity Assessment

### Low Complexity → Haiku
- Single-step operations
- Pre-defined response format
- Well-understood problem domain
- High volume expected
- Examples: sentiment analysis, simple Q&A, classification, formatting

### Medium Complexity → Sonnet (Default)
- 2-3 step reasoning required
- Moderate domain knowledge needed
- Some ambiguity or context required
- Standard code generation
- Examples: code review, document summarization, business analysis, standard coding tasks

### High Complexity → Opus
- 4+ step reasoning chain
- Novel problem-solving required
- Deep domain expertise needed
- Edge cases or unusual scenarios
- Sophisticated code architecture
- Examples: research synthesis, complex refactoring, strategic planning, creative work

## Performance Characteristics

| Metric | Haiku | Sonnet | Opus |
|--------|-------|--------|------|
| Latency (ms) | 50-150 | 300-800 | 1000-3000 |
| Cost (per 1M tokens) | $0.80 | $3.00 | $15.00 |
| Reasoning Capability | Basic | Strong | Expert |
| Knowledge Breadth | Limited | Good | Comprehensive |
| Best For | Speed | Balance | Quality |

## MCP Routing Rules

1. **Check latency requirement first**
   - If < 500ms required → Haiku
   - Otherwise → proceed to step 2

2. **Assess task complexity**
   - Count reasoning steps required
   - Evaluate domain specificity
   - Simple → Haiku, Medium → Sonnet, Complex → Opus

3. **Consider volume/cost**
   - High volume + simple task → Haiku
   - High volume + medium task → Sonnet
   - Any volume + complex → Opus

4. **Default fallback**
   - When unsure → Sonnet (best value for most tasks)
