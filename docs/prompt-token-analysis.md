# Prompt, Tool, and Delegation Analysis

## Scope

This document evaluates three requirements against the current `nullclaw` codebase:

1. Reduce the token cost of the opening helper/system prompt.
2. Stop tool use from exploding token consumption across a single turn.
3. Move tool-heavy work behind delegation so the main model does not need every tool detail.

The analysis is based on the current implementation in:

- `src/agent/prompt.zig`
- `src/agent/root.zig`
- `src/tools/root.zig`
- `src/tools/delegate.zig`
- `src/tools/spawn.zig`
- `src/subagent.zig`
- `src/subagent_runner.zig`
- `src/config.zig`
- `src/config_types.zig`

## Executive Assessment

The current runtime already has a few useful knobs for reducing token waste, but they do not fully solve the three requirements.

- Requirement 1 is not satisfied by config alone. The base system prompt is always large, and named-agent prompts are additive rather than replacement prompts.
- Requirement 2 is only partially mitigated by existing config. The main reason for high token spend is architectural: the tool loop keeps resending accumulated history and tool results.
- Requirement 3 is partially implemented. `spawn` already runs restricted subagents with workspace skills available, but `delegate` is still just a direct LLM call, and the main agent still sees the full tool surface.

## Requirement 1: Smaller Beginning Prompt

### What the code does now

`src/agent/prompt.zig` builds a single large system prompt in `buildSystemPrompt()`.

That prompt always includes all of the following sections:

- project/workspace identity files such as `AGENTS.md`, `SOUL.md`, `TOOLS.md`, `CONFIG.md`, `IDENTITY.md`, `USER.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`, and `MEMORY.md`
- a fixed safety section
- scheduling guidance
- skills metadata
- workspace and runtime metadata
- a full tool protocol block
- a full list of available tools with descriptions and JSON schemas

Important limits exist, but they are still large:

- per bootstrap file excerpt cap: `20_000` chars
- total injected workspace bootstrap budget: `24_000` chars

Those caps protect against extreme cases, but they still allow a very large opening prompt.

### Existing config/customization levers

There are a few current ways to make the opening cheaper without code changes:

- shorten workspace prompt files, especially `AGENTS.md`, `SOUL.md`, `TOOLS.md`, and `IDENTITY.md`
- avoid `always=true` skills unless they are truly universal, because always-on skills are expanded directly into the prompt
- use smaller agent workspaces via `agents.list[].workspace_path` so spawned specialists inherit less project context
- use named agents with concise `system_prompt`

### Why config is not enough

The main limitation is that the base prompt shape is hard-coded.

There is no current config like:

- `agent.prompt_profile = "compact"`
- `agent.prompt_style = "amp"`
- `agent.system_prompt_path` for the root agent
- per-section toggles for workspace files, skills, or tool instructions

Also, named-agent `system_prompt` does not replace the base prompt. In `src/agent/root.zig`, the named profile prompt is prepended under `## Agent Profile`, then the full default system prompt is still appended. That means a named agent currently adds more prompt text; it does not create a truly slim root preamble.

### Assessment

- Config-only mitigation available: yes, but limited.
- Full requirement satisfied with config only: no.

## Requirement 2: Tool Use Causes Context and Token Blow-Up

### What the code does now

The main tool loop lives in `Agent.turn()` in `src/agent/root.zig`.

For each tool iteration, the runtime does this:

1. Rebuilds the provider message slice from history.
2. Sends another model request.
3. Executes tool calls.
4. Formats the tool results.
5. Appends the formatted tool results plus a reflection prompt back into history as a new user message.
6. Repeats.

This means token cost grows with every loop because the next request includes:

- the original system prompt
- the earlier conversation
- the assistant message that requested tools
- the tool results from previous steps
- the reflection instruction added after the tool results

This is why a model with a 20k effective context can still consume more than 100k cumulative tokens over several tool iterations. The server is not keeping a hidden incremental state; each round is another full request.

### Important implementation details

#### Full tool results are appended into history

After tool execution, the code appends a new user message containing the formatted tool results plus a reflection instruction. That is the dominant source of per-iteration growth.

#### Tool outputs are truncated, but still large

`src/providers/scrub.zig` truncates tool output to `100_000` characters before scrubbing. That protects against catastrophic output, but it is still large enough to materially bloat later turns.

#### Native tools still duplicate tool information

When native tools are supported, `src/agent/root.zig` passes `turn_tool_specs` to the provider request. But the system prompt from `src/agent/prompt.zig` still contains the full textual tool protocol and full tool catalog.

So on native-tool providers, tool metadata may be duplicated:

- once in the system prompt as text
- again in the provider `tools` field as structured tool specs

That is unnecessary prompt overhead.

#### Compaction happens too late for this problem

`compact_context`, `trimHistory()`, and `autoCompactHistory()` help at session level, but they do not fundamentally change the within-turn tool loop strategy. Most of the tool-driven growth happens before the final answer is produced.

#### Some apparent config knobs do not currently help

`agent.parallel_tools` and `agent.tool_dispatcher` are parsed and saved in config, but they do not currently drive the runtime behavior in the files reviewed. They should not be treated as active token-optimization controls right now.

### Existing config mitigations that do help

These are real current levers:

- `agent.max_tool_iterations`: caps runaway tool loops
- `agent.max_history_messages`: bounds retained history between turns
- `agent.compact_context`: helps longer-lived sessions
- `agent.token_limit`: keeps the request budget aligned with the actual model context window
- `agent.tool_filter_groups`: reduces which MCP tool schemas are sent for a given turn
- `models.providers.<name>.native_tools = true`: better than XML-only tool use on supported providers, though still not enough because of duplicated prompt text

### What config cannot fix

Config cannot change these architectural behaviors:

- raw tool results being appended back into model-visible history
- the full prompt being resent on every tool round
- the tool protocol and tool catalog always being present in the system prompt
- the main agent seeing every tool instead of delegating tool-heavy work to a worker

### Assessment

- Config-only mitigation available: yes.
- Full requirement satisfied with config only: no.

## Requirement 3: Tool Use Should Be Delegation-Centered

### What already exists

There are two relevant mechanisms today.

#### `spawn` is already a real subagent path

`src/tools/spawn.zig` launches background subagents through `SubagentManager`.

That path is meaningful because:

- `src/subagent.zig` runs the task in an isolated thread
- `src/subagent_runner.zig` builds a restricted tool set via `tools.subagentTools()`
- `subagentTools()` intentionally excludes `message`, `spawn`, and `delegate`
- `buildSubagentSystemPrompt()` includes both the tool instructions and the workspace skills section

So a spawned subagent already has:

- a smaller, restricted tool set than the main agent
- access to installed workspace skills
- its own model/provider/profile context when a named agent is used

This is the closest existing implementation to the requested delegation model.

#### `delegate` is not the same thing

`src/tools/delegate.zig` does not use the subagent runner. It does a direct `chatWithSystem()` or `complete()` style completion against another provider/model.

That means:

- no restricted tool loop
- no skill-loading behavior from `subagent_runner.zig`
- no subagent workspace execution model
- no skill-specialized worker behavior

It is delegation in name, but not in the sense requested here.

### Why the current design does not satisfy the requirement

The main model still receives the full tool surface because `allTools()` in `src/tools/root.zig` registers the core tools, memory tools, delegate tool, and spawn tool together.

Then `buildSystemPrompt()` advertises the full tool protocol and all tool schemas to the main model.

So the current root-agent contract is still:

- know all tools
- decide which concrete tool to call
- observe detailed tool results
- keep looping in the same agent turn

The requested design is different:

- root agent should know how to route work
- specialized worker should know tool details
- worker should apply the relevant skill instructions
- root agent should receive a summarized result, not the full tool transcript

### Assessment

- Infrastructure for skill-aware subagents already exists: yes
- Current runtime matches the requested delegation model: no
- Requirement can be solved by config only: no

## Comparison With Amp

This section is based on direct inspection of the local Amp bundle at `~/.amp/package/dist/main.js`.
Because it is a minified distribution artifact, the comparison should be treated as observational rather than a full architectural reverse-engineering.

### What Amp clearly appears to do differently

#### 1. It has multiple built-in prompt profiles or modes

The bundle contains several different system-prompt builders, including:

- the main `You are Amp...` prompt
- a more generic coding-agent prompt
- a smaller "optimized for speed and efficiency" prompt
- a distinct `Rush Mode`

The CLI also exposes `--mode` with text stating that mode controls:

- model
- system prompt
- tool selection

This is directly relevant to requirement 1. Amp appears to treat prompt shape as a first-class runtime mode rather than one fixed prompt with only additive custom text.

#### 2. It supports direct system-prompt override

The bundle exposes hidden `--sp` and `--system-prompt` flags, and the implementation shows that the override may be either:

- raw prompt text
- a file path whose contents are loaded

That is materially more flexible than the current `nullclaw` root-agent setup, where the base prompt shape is fixed and named-agent prompts are prepended instead of replacing the default prompt.

#### 3. It treats context pressure as a thread-management problem, not only a compaction problem

Amp has a first-class `handoff` tool and `threads handoff` command.

The handoff description explicitly says it should be used when:

- the current thread is getting too long and context is degrading
- the current thread's context window is near capacity
- the user wants work to continue in a fresh context

That is a notable architectural difference from `nullclaw`, which currently tries to keep the work inside one agent turn plus compaction. Amp clearly externalizes some long-running work into a fresh thread rather than only compressing the existing one.

#### 4. It has explicit subagent guidance

The bundle contains a `using_subagents` instruction block that says, in effect:

- do not spawn a subagent for work you can do directly
- fan out subagents only for genuinely independent work
- include all required context in the subagent prompt
- summarize subagent results for the user because the user cannot see subagent output directly

This aligns closely with your third requirement. Amp appears to formalize subagents as a normal operating pattern rather than treating delegation as only a different model call.

#### 5. It appears to reduce prompt pressure by relying on targeted runtime context

The bundle exposes IDE integration text saying Amp can automatically include:

- the open file
- the text selection

with each message.

That suggests Amp is willing to depend on narrow, task-local runtime context instead of forcing the opening system prompt to carry as much global context. This is not a complete answer to prompt size, but it is directionally important.

### What Amp suggests for the three requirements

#### Requirement 1

Amp strongly suggests that prompt size should be mode-based and overrideable.

The key idea to borrow is:

- one runtime should be able to choose between multiple prompt profiles
- a custom prompt should be able to replace the base prompt, not only prepend to it

#### Requirement 2

Amp's visible bundle does not prove exactly how it minimizes cumulative tool-loop tokens internally.

However, two visible patterns are relevant:

- it varies tool selection by mode
- it uses handoff to a fresh thread when context becomes degraded

So even without full internal visibility, Amp appears to reduce token pressure partly by avoiding a one-thread-forever approach.

#### Requirement 3

Amp is the clearest confirmation that delegation should be treated as a first-class execution strategy.

The most important lesson is not merely "have a delegate tool". It is:

- keep subagents intentional
- give them focused context
- let them work independently
- return summaries back to the main interaction surface

### Where Amp also appears suboptimal

Amp is useful as a reference, but the visible bundle also suggests some tradeoffs that should not be copied blindly.

#### 1. Handoff is a relief valve, not a real compression strategy

Fresh-thread handoff helps when context is already degraded, but it is still a coarse reset.

The downside is:

- work continuity moves from structured runtime state back into natural-language goal text
- some context must be re-explained to the new thread
- long tasks can become fragmented across multiple threads

That is better than letting one thread decay forever, but it is still not as efficient as preserving compact machine-readable state inside the same workflow.

#### 2. Prompt modes alone do not solve tool-loop cost

Multiple prompt variants are good, but they are only the first layer.

If the runtime still:

- replays too much tool output
- replays too much conversation history
- relies on full natural-language summaries between workers

then the token problem simply moves around instead of being solved.

#### 3. Subagents can duplicate setup cost

Subagents are useful, but every subagent loses part of the parent context and must be re-seeded with:

- the task
- relevant file paths
- conventions
- verification requirements

If overused, subagents can reduce planner complexity while increasing total token and orchestration cost.

#### 4. Narrow runtime context can become brittle

Using IDE file and selection context is efficient when the signal is correct.

It is less efficient when:

- the relevant context is broader than one open file
- the selection is stale or misleading
- the user wants cross-cutting work rather than local edits

So targeted runtime context is helpful, but it should complement structured state, not replace it.

#### 5. Custom prompt override is powerful but easy to misuse

Direct system-prompt override is flexible, but it can also create:

- prompt drift across users and repos
- hard-to-debug behavior changes
- large custom prompts that recreate the same token problem in another form

That means override support should exist, but it should be budget-aware and profile-aware.

## Comparison With Hermes Agent

This section is based on direct inspection of `github.com/nousresearch/hermes-agent`, especially:

- `agent/prompt_builder.py`
- `run_agent.py`
- `agent/context_engine.py`
- `agent/context_compressor.py`
- `agent/prompt_caching.py`
- `tools/delegate_tool.py`
- `tools/tool_result_storage.py`
- `agent/skill_utils.py`
- `tools/skills_tool.py`

Hermes is a more useful reference than Amp for in-session context control and summary-only delegation, but it is weaker than Amp as a reference for prompt-profile modes and handoff-style thread resets.

### What Hermes clearly appears to do differently

#### 1. It treats the system prompt as a stable cached prefix

Hermes builds the main system prompt once, caches it for the session, and only rebuilds it when compression invalidates that cache.

It also keeps some dynamic guidance out of that cached prefix by appending an `ephemeral_system_prompt` at request time instead of folding every transient detail into the base prompt.

That is relevant to requirement 1 because it treats prompt stability as an architectural concern, not just prompt size.

#### 2. It keeps skills lightweight in the base prompt

Hermes does not appear to inject full skill bodies into the default system prompt.

Instead, it builds a compact skills index and expects the model to load the full skill content on demand through a tool.

That is a stronger answer to skill-related token pressure than `nullclaw`'s current always-on skill expansion.

#### 3. It still replays tool results, but it has a real compression pipeline around them

Hermes still appends tool results into conversation history, so it does not fully avoid the architectural problem described for requirement 2.

However, it also has much stronger mitigation than the current `nullclaw` runtime:

- tool-result storage outside the main text transcript when needed
- pruning and deduplication of old tool results
- short tool-result summaries for older entries
- token-budget-based compression with protected head/tail regions

So Hermes does not eliminate tool-loop replay, but it does handle it more deliberately.

#### 4. Its delegation model is meaningfully closer to the desired design

Hermes has a `delegate_task` tool that launches a fresh child agent with its own budget, its own prompt, and its own restricted execution context.

Most importantly, the parent receives only the child summary and metadata. The child's intermediate tool transcript does not get replayed into the parent context window.

That is much closer to the requested requirement 3 than `nullclaw`'s current `delegate` implementation.

#### 5. It explicitly restricts child-agent capabilities

Hermes blocks recursive delegation and certain unsafe or user-coupled tools for delegated children.

That matters because summary-only delegation is most useful when the child is intentionally narrower than the parent and cannot recursively explode complexity.

`nullclaw` already has part of this pattern in `subagentTools()`, but Hermes shows the same idea applied directly to the delegation path.

### What Hermes suggests for the three requirements

#### Requirement 1

Hermes suggests that prompt reduction should not only mean "make the opening smaller". It should also mean:

- keep a stable prompt prefix so it can be cached effectively
- move transient guidance into a separate ephemeral layer
- load full skills or procedures on demand instead of always inlining them

#### Requirement 2

Hermes suggests that if tool results remain part of history, the runtime still needs a dedicated tool-result compression strategy:

- summarize old tool outputs aggressively
- deduplicate repeated reads/searches
- store bulky outputs outside prompt-visible history
- protect the recent tail by token budget, not only message count

That is not the final architecture we want for `nullclaw`, but it is a materially better intermediate step than the current raw replay approach.

#### Requirement 3

Hermes is the clearest confirmation that delegation should return summaries, not transcripts.

The most important lessons are:

- child work should happen in isolated context
- child tools should be restricted
- the parent should receive a bounded summary and metadata
- delegation should contain token growth instead of merely moving the same transcript to another model call

### Where Hermes also appears suboptimal

Hermes is a strong reference, but it still has limits that `nullclaw` should avoid copying blindly.

#### 1. It still pays for within-agent tool replay until compression or delegation happens

Hermes compresses better than `nullclaw`, but the main agent loop still replays tool outputs in history.

That means Hermes is a mitigation model, not a full solution, for requirement 2.

#### 2. Its compression strategy appears mostly reactive

The visible design focuses on compressing after the context grows large or when API pressure is detected.

That is useful, but it is still downstream of the expensive event. A stronger design would also budget large tool reads before they happen.

#### 3. It does not appear to expose a first-class prompt-profile system like Amp

Hermes is strong on cached prompt construction, but it is not the best reference for requirement 1 if the specific goal is multiple operator-facing prompt modes.

Amp remains the better reference for that part.

#### 4. It does not appear to make delegation adaptive by runtime heuristic

Hermes has a strong delegation tool, but the visible design still looks model-directed rather than runtime-directed.

That means `nullclaw` still has room to improve by adding automatic escalation based on token cost, retry count, or tool-surface breadth.

#### 5. It still appears history-centric rather than state-centric

Hermes compresses history well, but the visible design still primarily manages a transcript rather than a compact machine-readable execution state.

`nullclaw` should aim higher than that by keeping explicit summarized state and artifact handles outside normal prompt history.

## Current Controls That Are Worth Using Now

These existing controls are the most practical short-term mitigations.

### Best current config levers

- `agent.max_tool_iterations`
- `agent.compact_context`
- `agent.max_history_messages`
- `agent.token_limit`
- `agent.tool_filter_groups`
- provider-level `native_tools`
- named agents with `workspace_path`

### Best current content levers

- shorten `AGENTS.md`
- shorten `SOUL.md`
- shorten `TOOLS.md`
- move large persistent instructions into optional skills instead of always-on prompt text
- keep only a small set of truly global skills as `always=true`

## Bottom Line

There are worthwhile config and content reductions available today, but they are mitigation, not a full fix.

The core findings are:

- the root prompt is structurally large and lacks a compact profile option
- tool loops resend too much history and too much raw tool output
- the codebase already contains a useful subagent foundation, but the root agent has not yet been redesigned into a delegation-first planner

The external comparisons sharpen that picture:

- Amp is the stronger reference for prompt modes, prompt override, and fresh-context handoff
- Hermes is the stronger reference for cached prompt prefixes, lazy skill loading, tool-result compression, and summary-only delegation

For the exact behavior requested, code changes are needed.
