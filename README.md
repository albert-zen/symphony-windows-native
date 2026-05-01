# Symphony Windows Native

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

This repository is a community Windows-native edition of OpenAI's Symphony prototype. It keeps the
original Apache-2.0 licensed reference implementation and adds a Windows local-worker path for
PowerShell hooks and clean Codex app-server stdio startup.

If you are trying to run Symphony directly on Windows, start here:

- [Windows native setup guide](elixir/docs/windows-native.md)
- [Windows workflow example](elixir/WORKFLOW.windows.example.md)
- [PowerShell launcher](elixir/scripts/start-windows-native.ps1)

The Windows path is experimental, but the local Linear -> Symphony -> Codex -> Linear loop has been
validated end to end. See the Windows guide for known limitations and test-fixture gaps.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is an engineering preview for testing in trusted environments. This Windows-native
> edition is not an official OpenAI-maintained distribution.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
