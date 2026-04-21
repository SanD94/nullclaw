# Prompt, Tool, and Delegation Implementation Plan

## Goal

This plan turns the earlier analysis into a concrete implementation path for `nullclaw`.

It is designed to be:

- minimal first
- aligned with the current architecture
- incremental, so each phase can land independently

The target outcomes are:

1. a smaller configurable root prompt
2. lower cumulative token usage during tool-heavy turns
3. a delegation-first execution model for specialized work

## Design Principles

- Prefer additive config and small branch points over a broad prompt-system rewrite.
- Reuse existing subagent infrastructure instead of inventing a second delegation runtime.
- Optimize native-tool providers first because that is the cheapest high-impact reduction.
- Keep old behavior available as the default `full` profile until the new profiles are proven.
- Keep the stable root prompt cacheable across turns; inject volatile context outside that prefix when possible.

## Additional Principles Beyond Amp

Amp is a strong reference, but `nullclaw` should not stop at "mode prompts + subagents + handoff".

The plan should also enforce these principles:

- Prefer structured compact state over repeated natural-language restatement.
- Prefer artifact references over replaying large tool outputs.
- Use handoff as an escape hatch, not the default context-management strategy.
- Make delegation adaptive based on cost and convergence, not only explicit user/tool choice.
- Make custom prompt override budget-aware so it cannot silently recreate the same token problem.

## Phase 1: Prompt Profiles

### Objective

Make the root prompt shape configurable, with a compact option and an Amp-like option.

### Proposed Config Keys

Add these under `agent`:

```json
{
  "agent": {
    "prompt_profile": "full",
    "prompt_profile_path": null,
    "prompt_include_project_context": true,
    "prompt_include_skills": true,
    "prompt_include_tool_catalog": true,
    "prompt_include_schedule_guidance": true,
    "prompt_include_workspace_section": true,
    "prompt_include_runtime_section": true
  }
}
```

### Recommended Semantics

- `prompt_profile = "full"`
  - current behavior
- `prompt_profile = "compact"`
  - keep safety, short workspace/runtime metadata, and short tool instructions
  - prefer a compact skill index over full skill expansion
  - drop large project-context expansion and large explanatory sections unless explicitly enabled
- `prompt_profile = "amp"`
  - short operator-style preamble focused on code work, verification, and concise execution
- `prompt_profile = "custom"`
  - load root prompt body from `prompt_profile_path`

### Minimal Code Touchpoints

#### `src/config_types.zig`

Extend `AgentConfig` with the new fields.

Smallest practical shape:

- `prompt_profile: []const u8 = "full"`
- `prompt_profile_path: ?[]const u8 = null`
- booleans for the optional sections

Using strings keeps the parser changes small and consistent with the existing config style.

#### `src/config_parse.zig`

Parse the new `agent.*` keys.

Validation should stay minimal:

- allow only `full`, `compact`, `amp`, `custom`
- ignore invalid booleans the same way nearby config parsing already behaves

#### `src/config.zig`

Serialize the new config fields in `save()`.

#### `src/agent/prompt.zig`

Add a lightweight prompt-profile switch near `buildSystemPrompt()`.

Recommended refactor shape:

- keep `buildSystemPrompt()` as the main entry point
- add a small profile resolver
- gate existing sections behind config booleans
- separate stable prompt content from transient turn-specific guidance so future prompt caching stays viable

Minimal helper set:

- `buildSystemPromptFull()`
- `buildSystemPromptCompact()`
- `buildSystemPromptAmp()`
- `loadCustomSystemPrompt()`

The implementation should reuse existing section writers rather than duplicating large blocks.

Hermes suggests one additional constraint here: if `nullclaw` later adds prompt caching, the stable prompt body should stay byte-stable across normal tool iterations, and temporary task hints should be appended outside that cached prefix.

### Minimal Acceptance Criteria

- `full` produces current output
- `compact` materially reduces prompt size
- `amp` produces a short root prompt
- `custom` loads prompt text from a file

## Phase 2: Make Root Prompt Replacement Possible

### Objective

Stop named-agent prompts from always being additive.

### Proposed Config Key

Add this under `agents.list[]`:

```json
{
  "name": "coder",
  "provider": "openai",
  "model": "gpt-5.2",
  "system_prompt": "...",
  "prompt_mode": "prepend"
}
```

Allowed values:

- `prepend` (current behavior)
- `replace`

### Minimal Code Touchpoints

#### `src/config_types.zig`

Extend `NamedAgentConfig` with:

- `prompt_mode: []const u8 = "prepend"`

#### `src/config_parse.zig`

Parse `agents.list[].prompt_mode`.

#### `src/config.zig`

Serialize the new field.

#### `src/agent/root.zig`

In the system-prompt composition block inside `Agent.turn()`, branch on `prompt_mode`:

- `prepend`: keep current behavior
- `replace`: use the profile prompt instead of appending `full_system`

This is a very small local change with high practical value.

### Minimal Acceptance Criteria

- existing profiles behave the same by default
- `replace` produces a genuinely smaller prompt for specialist agents

## Phase 3: Remove Native-Tool Prompt Duplication

### Objective

Avoid paying twice for tool metadata when the provider already receives structured tool definitions.

### Current Problem

On native-tool providers, `nullclaw` currently sends:

- textual tool protocol and full tool catalog in the system prompt
- structured tool schemas in the provider `tools` field

### Proposed Change

When native tools are enabled for the current request:

- keep only a short tool-use note in the system prompt
- do not emit the full textual tool catalog and schema dump

### Minimal Code Touchpoints

#### `src/agent/prompt.zig`

Extend `PromptContext` with something like:

- `native_tools_enabled: bool = false`

Then branch in `writeToolInstructionsSection()`:

- native tools on: write a compact note
- native tools off: write current full protocol and tool list

#### `src/agent/root.zig`

The current system prompt is built before each request loop, so pass the current tool mode into the prompt builder.

Smallest safe approach:

- determine whether the active provider/model path will use native tools
- thread that flag into `prompt.buildSystemPrompt()`

This may require moving or reusing the same logic already used later in the loop for `native_tools_enabled`.

### Minimal Acceptance Criteria

- XML/non-native path remains unchanged
- native-tool path no longer emits the full textual tool catalog
- request token estimate drops for native-tool providers

## Phase 4: Summarize Tool Results Instead of Replaying Raw Output

### Objective

Reduce cumulative token growth inside a single tool loop.

### Proposed Runtime Behavior

After each tool call batch, append a bounded summary to history instead of the full formatted tool output.

Suggested summary shape:

```text
Tool batch summary:
- shell: success — found 3 matching files
- file_read: success — extracted target function
- http_request: failed — timeout

Use the results above to decide the next step.
```

Optional next step:

- keep full tool outputs in memory only for the current runtime path
- or persist oversized tool outputs under a generated memory/artifact key

Hermes is a useful reference for this phase because it shows that a cheap pre-pass matters even before heavier compression:

- deduplicate repeated tool outputs
- collapse old tool outputs into one-line summaries
- keep the latest actionable detail while shrinking older evidence

### Minimal Code Touchpoints

#### `src/agent/root.zig`

Replace the current block that appends:

- formatted raw tool results
- reflection prompt

with:

- a summarizer over `results_buf.items`
- a compact reflection instruction

Add a local helper near the loop, for example:

- `summarizeToolExecutionResults()`

Do not over-abstract this. A single helper local to `agent/root.zig` is enough.

#### `src/providers/scrub.zig`

No immediate change required for the first pass. Existing scrubbing can remain as a fallback before summary generation if needed.

### Minimal Acceptance Criteria

- tool loops still function correctly
- history growth per iteration is materially reduced
- failures remain understandable to the model

## Phase 4B: Introduce Artifact Handles For Large Tool Results

### Objective

Stop using prompt-visible history as the storage location for bulky execution data.

### Proposed Runtime Behavior

When a tool produces output above a small threshold:

- store the full output in a runtime artifact slot or memory entry
- append only a compact summary plus artifact handle into history

Example:

```text
shell: success — found 12 matches in 3 files.
Artifact: exec_artifact:turn7:tool2
```

### Minimal Code Touchpoints

#### `src/agent/root.zig`

Add a small local artifact table for the current turn or session.

The first version does not need a new subsystem. A simple in-memory map owned by the agent/session is enough.

#### `src/session.zig`

If cross-turn persistence is desired, session ownership is the smallest reasonable place to keep the map.

### Minimal Acceptance Criteria

- large tool outputs no longer enter history verbatim
- the model still receives enough summary to continue work
- full outputs remain retrievable when explicitly needed

## Phase 5: Add In-Turn Tool Compaction Trigger

### Objective

Do not wait until the end of the turn to reduce tool-loop context.

### Proposed Config Key

```json
{
  "agent": {
    "tool_result_summary_trigger_chars": 4000
  }
}
```

### Behavior

If accumulated tool-result summary text for the current turn exceeds the threshold:

- collapse previous tool summaries into a smaller cumulative summary
- keep only the newest batch detail plus the compact cumulative state
- protect the latest user request and latest active task detail from being compacted away

### Minimal Code Touchpoints

#### `src/config_types.zig`

Add:

- `tool_result_summary_trigger_chars: u32 = 4000`

#### `src/config_parse.zig`

Parse it.

#### `src/config.zig`

Serialize it.

#### `src/agent/root.zig`

Track running tool-summary size within `turn()` and compact when the threshold is crossed.

This should stay local to the turn loop, not a global memory lifecycle feature.

Hermes also suggests that the protected recent tail should be chosen by approximate token budget, not only by message count, once a first working implementation exists.

## Phase 6: Turn Delegation Into the Default Tool-Heavy Strategy

### Objective

Make the main agent route work instead of carrying the entire heavy tool surface.

### Key Insight

`nullclaw` already has most of the needed pieces:

- `spawn`
- `SubagentManager`
- `subagentTools()`
- `subagent_runner.runTaskWithTools()`
- skill loading in subagent prompt construction

The smallest effective step is to reuse those pieces instead of building a second worker runtime.

## Phase 6A: Add Synchronous Delegation Through the Subagent Runner

### Proposed Approach

Keep `spawn` as async background work.

Change `delegate` so it can optionally run through the same restricted subagent execution stack used by spawned agents.

Hermes suggests an important contract for this path: the parent should receive only the child summary payload, not the child's full internal tool transcript.

### Proposed Config Key

```json
{
  "agent": {
    "delegate_via_subagent_runner": true
  }
}
```

### Minimal Code Touchpoints

#### `src/config_types.zig`

Add:

- `delegate_via_subagent_runner: bool = false`

#### `src/config_parse.zig`

Parse it.

#### `src/config.zig`

Serialize it.

#### `src/tools/delegate.zig`

Add a second execution path:

- current path: direct provider completion
- new path: build a `TaskRunRequest` and invoke `subagent_runner.runTaskWithTools()` synchronously

The delegated child should keep the same restricted-tool posture already used by `subagentTools()`, including no recursive delegation path back into `delegate`/`spawn`.

To avoid large plumbing changes, thread the extra runtime context into the delegate tool from tool construction time.

#### `src/tools/root.zig`

Extend `DelegateTool` initialization with the data needed to build a `TaskRunRequest`:

- workspace dir
- allowed paths
- tools config
- memory config
- autonomy/security settings
- observer

This should mirror the data already passed into `SpawnTool` and `subagentTools()`.

### Minimal Acceptance Criteria

- delegated work can run through the restricted tool set
- delegated work sees installed skills via the existing subagent prompt path
- root agent receives only a bounded summary/result payload, not the raw child transcript

## Phase 6B: Reduce the Root Agent Tool Surface

### Objective

Make the main agent planner-like and push specialized execution downward.

### Proposed Config Key

```json
{
  "agent": {
    "tool_exposure_mode": "full"
  }
}
```

Allowed values:

- `full`
- `delegation_first`

### Behavior

In `delegation_first` mode, the root agent keeps only a small set such as:

- `delegate`
- `spawn`
- maybe `memory_recall`
- maybe `file_read` or `file_read_hashed`

and omits most direct execution tools.

### Minimal Code Touchpoints

#### `src/config_types.zig`

Add:

- `tool_exposure_mode: []const u8 = "full"`

#### `src/config_parse.zig`

Parse it.

#### `src/config.zig`

Serialize it.

#### `src/tools/root.zig`

Branch in `allTools()`:

- `full`: current behavior
- `delegation_first`: construct a limited root tool list

This is the smallest place to centralize the switch.

### Minimal Acceptance Criteria

- root agent sees fewer tools
- delegated workers still receive the richer restricted tool set
- direct simple tasks remain possible

## Phase 6C: Make Delegation Adaptive

### Objective

Avoid two bad extremes:

- never delegating
- delegating too often and paying repeated setup cost

### Proposed Config Keys

```json
{
  "agent": {
    "delegation_auto": true,
    "delegation_token_threshold": 12000,
    "delegation_tool_count_threshold": 8,
    "delegation_retry_threshold": 2
  }
}
```

### Behavior

When enabled, the runtime should prefer delegation when one or more of these are true:

- estimated next-request token cost exceeds `delegation_token_threshold`
- too many tools are exposed for the current task
- the agent has already looped unsuccessfully `delegation_retry_threshold` times
- the request matches a named specialist or skill with a narrower workspace

### Minimal Code Touchpoints

#### `src/config_types.zig`

Add the new delegation-threshold fields.

#### `src/config_parse.zig`

Parse them.

#### `src/config.zig`

Serialize them.

#### `src/agent/root.zig`

The smallest first version can stay heuristic-based and local to `turn()`.

No planner subsystem is required for the first implementation.

### Minimal Acceptance Criteria

- delegation can happen automatically on obviously expensive tool-heavy turns
- trivial tasks still stay local
- overall token usage improves for multi-step tasks

## Phase 7: Add a First-Class Fresh-Context Handoff Path

### Objective

Borrow the best idea from Amp for context pressure.

### Proposed Change

Add a `handoff`-style tool or slash command that starts a fresh subagent/session/thread when the current one becomes too context-heavy.

This should be separate from tool delegation:

- delegation: specialist execution
- handoff: continue work in a fresh context

### Minimal Code Touchpoints

#### Option A: slash command first

- `src/agent/commands.zig`
- `src/session.zig`

This is the smallest user-facing implementation.

#### Option B: tool later

- new `src/tools/handoff.zig`
- register from `src/tools/root.zig`

### Minimal Acceptance Criteria

- user can explicitly move work to a fresh session/subagent
- the new context gets a short goal, not the full old transcript

### Important Constraint

This phase should land after summarized state and artifact handles.

Otherwise, handoff becomes a substitute for proper state compression, which would repeat one of Amp's likely weak points.

## Suggested Landing Order

### Milestone 1

- prompt profiles
- named-agent `prompt_mode=replace`
- native-tool prompt deduplication

### Milestone 2

- summarized tool results
- in-turn tool-summary compaction

### Milestone 3

- synchronous delegate via subagent runner
- root `delegation_first` tool exposure mode

### Milestone 4

- explicit handoff/fresh-context path

## Smallest High-Value Starting Patch

If only one implementation sprint is available, the highest-value minimal change set is:

1. add `agent.prompt_profile`
2. add `agents.list[].prompt_mode = replace`
3. suppress full textual tool catalog when native tools are enabled
4. replace raw tool-result replay with short summaries

That combination should materially reduce token usage without requiring a major architectural rewrite.

## Final Recommendation

Implement the work in this order:

1. shrink the root prompt
2. stop replaying raw tool output
3. reuse the existing subagent runner for synchronous delegation
4. add fresh-context handoff only after the first three are stable

That sequence gives the best cost reduction for the least architectural risk.
