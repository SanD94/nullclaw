# Prompt, Tool, and Delegation Recommendations

## Goal

These recommendations separate:

- changes you can make now with config or workspace content
- changes that require code work to fully satisfy the three requirements

## Highest-Value No-Code Changes

These can be applied immediately and should reduce cost without changing runtime behavior.

### 1. Keep the workspace bootstrap files aggressively short

The current prompt builder always reads workspace context files first. The cheapest improvement is to reduce the text in:

- `AGENTS.md`
- `SOUL.md`
- `TOOLS.md`
- `IDENTITY.md`
- `USER.md`

Recommended approach:

- keep only global rules in those files
- move specialized instructions into skills
- avoid repeating information across files
- avoid long prose when a short rule list would do

### 2. Stop preloading large skills unless they are universally needed

Skills marked `always=true` are injected into the prompt every turn.

Recommended approach:

- reserve `always=true` for one or two foundational skills at most
- convert task-specific skills into on-demand skills
- keep skill descriptions short so discovery is cheap

### 3. Lower the allowed tool loop length

The current default `agent.max_tool_iterations = 1000` is far too generous if the goal is token efficiency.

Recommended operating range:

- `4` to `8` for general use
- `8` to `12` only for intentionally tool-heavy agents

### 4. Use MCP tool filtering aggressively

`agent.tool_filter_groups` is one of the best existing controls because it prevents irrelevant MCP tool schemas from being sent on every turn.

Use `always` for tools that are nearly always relevant, and `dynamic` for tool families that should only appear when the user mentions matching keywords.

### 5. Set realistic token budgets

If a model has a 20k context window, configure `agent.token_limit` near that real limit instead of using a large default.

That does not reduce cumulative usage by itself, but it forces earlier clamping and reduces failure modes.

### 6. Use named agents with narrow workspaces

Named agents already support:

- different provider/model choices
- separate `system_prompt`
- separate `workspace_path`

Even before code changes, they are useful for creating cheaper specialists with less workspace context.

## Recommended Current Config Example

This example uses only fields that already exist.

```json
{
  "agent": {
    "compact_context": true,
    "max_tool_iterations": 6,
    "max_history_messages": 40,
    "token_limit": 20000,
    "tool_filter_groups": [
      {
        "mode": "always",
        "tools": ["mcp_git_*"]
      },
      {
        "mode": "dynamic",
        "tools": ["mcp_browser_*", "mcp_web_*"],
        "keywords": ["browser", "website", "url", "page", "dom"]
      },
      {
        "mode": "dynamic",
        "tools": ["mcp_ticket_*", "mcp_jira_*"],
        "keywords": ["ticket", "issue", "jira", "bug", "task"]
      }
    ]
  },
  "models": {
    "providers": {
      "openai": {
        "native_tools": true
      },
      "openrouter": {
        "native_tools": true
      }
    }
  },
  "agents": {
    "list": [
      {
        "name": "coder",
        "provider": "openai",
        "model": "gpt-5.2",
        "system_prompt": "You are a focused coding worker. Prefer direct action, minimal narration, and concise outputs.",
        "workspace_path": "agents/coder"
      },
      {
        "name": "researcher",
        "provider": "openrouter",
        "model": "anthropic/claude-sonnet-4",
        "system_prompt": "You are a focused research worker. Gather evidence, summarize clearly, and avoid coding unless asked.",
        "workspace_path": "agents/researcher"
      }
    ]
  }
}
```

## Important Caveat About Existing Config Fields

Do not rely on these as optimization controls yet:

- `agent.parallel_tools`
- `agent.tool_dispatcher`

In the reviewed code, they are parsed and serialized but not actually used to change the runtime tool loop.

## What To Borrow From Amp

From the local Amp bundle at `~/.amp/package/dist/main.js`, a few ideas stand out as especially relevant.

### 1. Treat prompt shape as a mode, not a constant

Amp visibly has multiple system-prompt variants, including a speed-oriented mode, and its CLI states that `--mode` controls model, system prompt, and tool selection.

`nullclaw` should copy that idea directly.

Recommended takeaway:

- prompt profile should be a top-level runtime choice
- tool exposure should vary with that profile
- a compact profile should not be forced to carry the same bootstrap payload as a full profile

### 2. Support real root-level prompt override

Amp exposes `--sp` and `--system-prompt` for raw text or file-backed override.

Recommended takeaway:

- root-agent prompt override should be supported directly
- file-backed custom prompts should be supported
- override should be able to replace the base prompt, not only prepend to it

### 3. Use handoff as a pressure-release valve

Amp's `handoff` tool is explicitly designed for:

- degrading context quality
- near-capacity context windows
- continuing work in a fresh thread

Recommended takeaway:

- do not make compaction the only answer
- introduce a first-class fresh-context handoff path
- allow the runtime to continue work in a new agent/thread when the current one becomes too context-heavy

### 4. Make delegation operationally explicit

Amp includes explicit subagent guidance about when to use them and how to summarize their output back to the user.

Recommended takeaway:

- delegation should be a core operating pattern, not an incidental helper
- worker prompts should include focused context, file paths, conventions, and verification guidance
- main-agent responses should summarize delegated work instead of replaying raw worker transcripts

### 5. Prefer narrow runtime context over giant preambles

Amp also appears to rely on targeted runtime context such as the currently open IDE file and selection.

Recommended takeaway:

- favor task-local context injection where possible
- avoid solving every context problem by making the root preamble larger

## What To Borrow From Hermes Agent

From `github.com/nousresearch/hermes-agent`, a different set of ideas stands out as especially relevant.

### 1. Keep the root prompt stable and move transient guidance out of it

Hermes caches its main system prompt and appends ephemeral task guidance separately.

Recommended takeaway:

- keep the root prompt as stable as possible across turns
- inject volatile guidance outside the cached prefix when possible
- treat prompt-cache preservation as part of token optimization

### 2. Use a compact skills index plus on-demand skill loading

Hermes keeps only a small skills directory in the main prompt and loads full skill text on demand.

Recommended takeaway:

- do not force every skill body into the opening prompt
- prefer a short discoverability layer plus explicit skill loading
- keep skill descriptions concise enough to act as a cheap index

### 3. Add cheap tool-result pruning before heavyweight compression

Hermes still replays tool results, but it prunes, deduplicates, and summarizes them aggressively before larger compression steps.

Recommended takeaway:

- deduplicate repeated file reads and searches
- summarize older tool results into one-line entries
- move bulky outputs into artifact storage rather than replaying them

### 4. Make delegation return only a bounded child summary

Hermes delegation is useful because the parent gets only the child result summary and metadata, not the full child tool transcript.

Recommended takeaway:

- child transcripts should stay in child context
- parent context should receive only summary, status, and artifact references
- summary-only delegation should be the default for tool-heavy worker execution

### 5. Protect recent context by token budget, not only message count

Hermes protects its most recent useful context by token budget and explicitly keeps the current user ask in the protected tail.

Recommended takeaway:

- protect the current task and latest user request explicitly
- use token-based retention for recent context
- do not assume a fixed message count maps to a safe token budget

## Where `nullclaw` Should Improve On These References

Amp and Hermes are useful references, but `nullclaw` should aim for a more structurally efficient design than either one alone.

### 1. Prefer structured state over thread resets

Amp's handoff idea is good as an escape hatch, but `nullclaw` should first preserve compact state inside the same workflow.

Recommended direction:

- maintain a machine-readable tool-execution ledger for the current turn
- keep compact state such as discovered files, failed attempts, selected strategy, and artifact handles
- hand off only when the compact state itself is no longer enough

### 2. Budget large tool reads before they happen

Hermes improves post-hoc compression, but `nullclaw` should also stop expensive context inflation earlier.

Recommended direction:

- estimate the likely token size of large file reads and command outputs before execution
- prefer chunked reads or delegated investigation when the expected output is too large
- use pre-execution budgeting in addition to post-execution summarization

### 3. Treat tool output as artifacts, not prompt text

Instead of replaying raw output or even medium-size summaries repeatedly, `nullclaw` should prefer:

- one short summary in prompt-visible history
- one opaque artifact identifier for the full output
- lazy rehydration only if the model explicitly needs the full material again

This is better than both the current `nullclaw` approach and the typical thread-handoff fallback pattern.

### 4. Make delegation adaptive, not manual-only

Amp visibly encourages explicit subagent usage, and Hermes has a stronger concrete delegation tool, but `nullclaw` can do better by deciding automatically when delegation is worth it.

Recommended signals for automatic escalation:

- too many candidate tools for the current task
- repeated tool iterations without convergence
- estimated next-request token cost above threshold
- task matches a named agent or skill with a narrower workspace/tool set

### 5. Budget prompt sections explicitly

Do not just switch between named profiles. Add real per-section budgets.

Recommended direction:

- hard cap project-context bytes
- hard cap skill bytes
- hard cap tool-instruction bytes
- deterministic drop order when the budget is exceeded

That gives more predictable behavior than only swapping whole prompt templates.

### 6. Summarize for the planner, not for the user first

Worker summaries should primarily optimize the next model step, not just human readability.

Recommended worker return shape:

- `status`
- `goal_completed`
- `key_findings`
- `changed_files` or `artifacts`
- `recommended_next_action`

This is more useful than a prose-only worker answer.

### 7. Keep override support safe

If `nullclaw` adds root prompt override, it should also add guardrails.

Recommended direction:

- show effective prompt size in diagnostics
- warn when custom prompt size exceeds a threshold
- preserve a built-in safety/tool contract even when a custom profile is used

### 8. Use handoff sparingly and intentionally

`nullclaw` should still add a handoff path, but only as:

- a context-pressure escape hatch
- a user-directed continuation tool
- a long-running-work boundary

It should not be the primary answer to token inefficiency.

## Code Changes Needed For Requirement 1

### 1. Add prompt profiles

Add a root-agent config field such as:

- `agent.prompt_profile = "full" | "compact" | "amp" | "custom"`

Recommended behavior:

- `full`: current behavior
- `compact`: minimal safety + workspace + runtime + short tool instructions
- `amp`: a short operator-style preamble focused on read-before-write, small patches, and verification
- `custom`: load from `agent.prompt_profile_path`

### 2. Make prompt sections individually toggleable

Add booleans for sections that are currently always present, for example:

- `agent.prompt_include_workspace_files`
- `agent.prompt_include_skills`
- `agent.prompt_include_tool_catalog`
- `agent.prompt_include_schedule_guidance`

That allows a compact agent to keep only what it truly needs.

### 3. Let named/root prompts replace, not only prepend

Today, named-agent `system_prompt` is additive.

Add an option such as:

- `agents.list[].prompt_mode = "prepend" | "replace"`

That would allow a genuinely small specialist prompt.

## Code Changes Needed For Requirement 2

### 1. Stop duplicating tool metadata on native-tool providers

When `native_tools` is enabled, the system prompt should not also include the full textual tool catalog and schema dump.

Recommended behavior:

- native-tool providers: keep only a short instruction saying tools are available through native tool calling
- non-native providers: keep the current XML/text protocol

This is likely the smallest high-impact token optimization.

### 2. Replace raw tool-result history with bounded summaries

Instead of appending full tool output into history, store:

- tool name
- success/failure
- short summary
- artifact reference or memory key for full output if needed

Example shape:

```text
Tool shell succeeded.
Summary: found 3 matching files and extracted the error path.
Artifact: tool_result:abc123
```

The full output can remain outside the prompt-visible history.

### 3. Compact within the tool loop, not only after it

Add a threshold such as:

- total tool-result chars appended this turn
- tool-iteration count
- estimated prompt size before the next request

Once crossed, summarize the previous tool results before the next model round.

### 4. Track a separate machine state for tool execution

The model does not need the full transcript of every tool result if the runtime can retain:

- the pending plan
- completed tool actions
- summarized evidence
- artifact references

This is the real fix for cumulative tool-loop token growth.

### 5. Either implement or remove inert controls

If `parallel_tools` and `tool_dispatcher` are intended to matter, wire them into the runtime. Otherwise remove them to avoid misleading users.

## Code Changes Needed For Requirement 3

### 1. Promote `spawn`/subagent execution into the default tool-heavy path

The codebase already has the right building blocks:

- `spawn`
- `SubagentManager`
- restricted `subagentTools()`
- skill inclusion in `subagent_runner.zig`

The missing step is making delegation central instead of optional.

### 2. Add a synchronous skill-aware delegation path

Current `delegate` is only a direct LLM completion. Add a new path that uses the subagent runner synchronously so the caller gets an inline result.

Possible design:

- `delegate_task(agent, task)`
- `delegate_skill(skill, task)`

Behavior:

- resolve the worker agent or skill
- run through `subagent_runner.runTaskWithTools`
- expose only the summarized result back to the root agent

### 3. Shrink the main agent’s tool surface

The root agent should ideally only see:

- delegation tools
- maybe a few universal tools like `memory_recall`
- maybe one direct file-read tool for simple checks

Workers should receive the heavy tool catalogs.

That would satisfy the design goal that the main model only needs to know how to route work, not how every tool works.

### 4. Bind delegation to skills and workspaces

The best fit with the current codebase is:

- root agent chooses a named worker
- named worker has a narrow `workspace_path`
- worker receives workspace skills through `buildSkillsSection()`
- worker uses restricted tools

That turns skills into actual delegated execution context instead of only more prompt text.

### 5. Return summaries, not transcripts, to the main agent

The root agent should receive something like:

- final answer
- key findings
- artifact references
- follow-up status

It should not receive the entire tool-by-tool trace unless explicitly requested.

## Suggested Implementation Order

### Phase 1

- add `agent.prompt_profile`
- suppress textual tool catalog when native tools are enabled
- lower default `max_tool_iterations`

### Phase 2

- summarize tool results before re-injecting them into history
- compact within long tool loops
- make `parallel_tools` and `tool_dispatcher` real or remove them

### Phase 3

- add synchronous skill-aware delegation using the existing subagent runner
- make the root agent delegation-first
- move heavy tool catalogs to worker agents only

## Final Recommendation

If the goal is the fastest practical improvement, do this first:

1. shorten workspace bootstrap files and always-on skills
2. set `max_tool_iterations`, `token_limit`, and `tool_filter_groups` conservatively
3. remove duplicated tool catalog text for native-tool providers
4. stop fully inlining skill bodies where a compact index plus explicit skill loading would work

If the goal is to fully match the requested behavior, the real target should be:

- compact prompt profiles
- a stable cached prompt prefix with ephemeral per-turn additions
- summarized tool-loop state instead of raw result replay
- a delegation-first root agent backed by skill-aware subagents
