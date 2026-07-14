# GWSInstallDependencies — Rewrite Spec

This is a functional overview of an existing PowerShell tool, written as a request for a rewrite. It describes what the tool needs to do and why, not how it currently does it — no existing code or implementation detail is included below.

## Goal

Keep a local Business Central (BC) AL development container in sync with the latest GWS/VEO dependency apps, so a developer never has to manually hunt down, download, or publish dependency package artifacts by hand.

Concretely, given a specific AL project (a main app, and often a companion test app), the tool needs to:

- Figure out the full set of dependency apps that project actually needs, including dependencies-of-dependencies, using whatever the newest available build of each dependency is — not necessarily the minimum version the project happens to declare, since that declared version is a loose, frequently-stale signal rather than an exact target.
- Get those dependency apps installed on a local BC container, handling whatever state the container is already in (nothing installed, an old version installed, already up to date).
- Optionally, also drop those same dependency files into the project's own local compile-dependency folder, for developers who want to compile against them in an editor — but only when asked, since this is a less common need than just keeping the container current.

This tool is run many times a day by one developer, against a rotating set of local projects and containers, so minimizing repetitive manual input matters as much as correctness.

## High-Level Flow

Three steps, run in sequence, each independently skippable where it makes sense:

1. **Download.** Find the most recent successful build from a specific continuous-integration pipeline (a designated "release" pipeline within a specific Azure DevOps organization and project) and download every app package artifact it produced. This step can be skipped to reuse whatever was downloaded most recently, for faster iteration when nothing new has shipped.

2. **Resolve dependencies (and optionally copy them locally).** Read the target project's declared dependencies, then walk that dependency graph transitively (each dependency's own dependencies, and so on), matching each one against the downloaded artifacts by publisher and app name — always preferring the newest available matching version, and skipping anything that's a platform/Microsoft dependency rather than a GWS/VEO one. The result is a single, deduplicated, correctly ordered list of every dependency app actually needed. This resolution always happens, because the next step depends on it — but the resolved files are only written into the project's own dependency folder when that's explicitly requested; a normal run doesn't touch the project folder at all.

3. **Publish.** Get every resolved dependency installed on the target BC container, with different handling depending on what's already there — already at the right version, at a different version, or not installed at all — and continuing past any single failure so everything gets attempted and every problem is reported together at the end. This step can be skipped entirely, for a "just fetch and resolve" run.

Before any of this runs, the tool needs three things resolved: which local AL project to operate on, which local BC container to publish to (skippable if publishing is skipped), and that container's login credentials. All three should be effortless to either specify explicitly or have the tool figure out interactively — a developer works across many project folders and sometimes more than one local container, and shouldn't have to remember or retype full paths and names every time.

## Specific Problems and Solutions

**Calling an external CLI tool doesn't give you normal error handling for free.** A failing external process call can look exactly like a successful one to the calling script unless the process's own exit status is explicitly checked after every single invocation. Any step that shells out to an external tool needs to check that tool's own success/failure signal itself, and fail immediately with a message identifying exactly which external call failed — not fail silently or continue with bad data.

**Every "which one" input should be optional, but an unspecified input must always resolve to something concrete before use — never a silent blank.** Which project, which container, and the container password are all things the tool can often figure out on its own by looking at what actually exists on the machine. When exactly one candidate exists, use it with no prompt at all. When several exist, offer a short, filterable pick-list rather than requiring the exact full name or path to be typed out. This must never degenerate into "just proceed with an empty value" — an unresolved input is always actively resolved to something real, one way or another, before it's used for anything.

**Not every folder that looks like a project candidate actually is one, and some "candidates" are actually containers of several real candidates.** When offering a list of project folders to choose from, only include folders that genuinely contain an AL project (a recognizable project descriptor, whether at the folder's root or in one of the conventional main-app/test-app subfolder layouts) — documentation folders, tooling folders, and folders that merely hold multiple parallel checkouts of the same project (rather than being a project themselves) must never show up as pickable options. Only offer the top-level folder; don't try to guess which specific checkout within such a container is meant.

**A typed shorthand should behave like the equivalent picker choice, not like a raw filesystem path.** If a developer already knows the project name and wants to skip the interactive picker by typing it directly, that short name needs to resolve the same way picking it from the list would — relative to the known projects root — rather than being interpreted as a path relative to wherever the terminal's current working directory happens to be, which essentially never matches and produces a confusing "not found" error instead of doing the obviously intended thing.

**Login credentials must never be stored in the clear, but re-prompting every single run is unacceptable friction.** The container password should be cached in an encrypted form tied to the current machine and user account (so a copied cache file is useless anywhere else), shared with the sibling tool that creates new local containers (since they operate against the same container), and only re-prompted for when there's no cache yet, the cache turns out to be stale, or a fresh prompt is explicitly requested.

**Writing into the developer's project folder is a real side effect and must be opt-in, not incidental.** Keeping the container current is the everyday reason to run this tool; occasionally refreshing the project's own local dependency files for compiling is a separate, much less frequent need. Resolving the dependency graph always has to happen (publishing needs it), but actually writing those files into the project folder should only happen when explicitly asked for — a default run should be free of any side effects on the project directory at all.

**How to fix a wrong or missing dependency install depends on both its version and how it's currently scoped, not just whether it matches.** A dependency already installed at the correct version, however it's scoped, needs no action. A wrong version installed under a normal/production-style scope should be upgraded in place, falling back to a full remove-and-reinstall only if that in-place upgrade itself fails. A wrong version installed under a developer/debug scope should always be fully removed and reinstalled, since in-place upgrades aren't reliable in that scope. Anything not installed at all just needs a fresh install. A single dependency failing shouldn't stop the run — every dependency should still be attempted, with every failure collected and reported together at the end.

**The right version to install is deliberately not the one the project declares.** Declared dependency versions in a project file tend to lag behind reality, so resolving strictly against the declared minimum would frequently install stale dependencies. The tool should always prefer the newest version actually available among the freshly downloaded artifacts, treating the declared version as a loose compatibility hint rather than an exact target to match.

**This entire workflow requires elevated privileges to reach the local container engine**, and that's an environmental precondition the tool can't work around — it should detect and report insufficient privileges clearly and immediately, rather than running partway through a multi-step process and failing with an unrelated-looking permissions error deep inside a later step.
