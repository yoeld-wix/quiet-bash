# Graph Options

The README currently uses `assets/savings-compact.svg` and `assets/workflow-context-stacks.svg`.
These alternatives are ready-to-use if you want a different visual emphasis.

## Option A: Compact Benchmark Snapshot

Use when the headline should be the strongest possible proof point:
`536,957` raw command-output tokens became `250` summary tokens.

<p align="center">
  <img src="../assets/savings-compact.svg" alt="Compact benchmark snapshot" width="820">
</p>

## Option B: Workflow Context Stacks

Use when the audience needs to understand why total bill savings vary by
workflow. It makes the assumption visible: quiet-bash saves the log-output slice
of the session, not every token in the session.

<p align="center">
  <img src="../assets/workflow-context-stacks.svg" alt="Workflow context stacks" width="760">
</p>

## Current README Graphs

The existing graphs are still good defaults when you want a detailed command
breakdown and a simple workflow summary.

<p align="center">
  <img src="../assets/savings-compact.svg" alt="Token savings per command" width="820">
</p>

<p align="center">
  <img src="../assets/workflow-context-stacks.svg" alt="Total token cost saved per dev workflow" width="760">
</p>
