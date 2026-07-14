# GWS BC/AL PowerShell Utilities

A small collection of PowerShell scripts that automate the local
**Business Central (BC) AL** development workflow for the **GWS / VEO** product
suite: standing up local BC Docker containers, keeping them in sync with the
latest GWS dependency apps, importing the dev license, and resetting a container
to a clean state.

Everything is driven from a menu-based **launcher** so you don't have to remember
script names, paths, or parameters — but each script also runs standalone.

> These scripts are GWS-specific: they pull artifacts from the `GWS-gevis / VEO`
> Azure DevOps project, build `de` sandbox containers, and filter for the `GWS`
> publisher. They're meant for the GWS AL dev team's machines.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **Windows + PowerShell 5.1+** | Windows PowerShell 5.1 or PowerShell 7. |
| **Docker** | Required for BC containers (Docker Desktop / Docker Engine for Windows containers). |
| **[BcContainerHelper](https://www.powershellgallery.com/packages/BcContainerHelper)** | `Install-Module BcContainerHelper` |
| **Azure CLI + `azure-devops` extension** | Only for `Install GWS Dependencies` (artifact download). `az extension add --name azure-devops` |
| **A BC developer license** (`.bclicense`) | Not included in this repo — see [Configuration](#configuration). |
| **An elevated (Administrator) session** | Every task talks to Docker/BC. The launcher self-elevates for you. |

First-time Azure DevOps sign-in (needed before the dependency download works):

```powershell
az login --allow-no-subscriptions --tenant 31f142f5-df76-4112-80a3-19bce6a47b15
```

---

## Quick start

```powershell
git clone <this-repo-url>
cd powershell-scripts

# Open the menu (self-elevates via a UAC prompt if you're not already admin)
powershell -ExecutionPolicy Bypass -File .\Launch.ps1
```

The first thing to do in the menu is open **`Settings...`** and set your `AlRoot`
(where your AL project repos live) and `LicenseFile` (path to your `.bclicense`).
See [Configuration](#configuration).

That's it — pick a task, answer the prompts, and it runs. Read on for the two
optional conveniences (a `launch` command and a pinned Start Menu shortcut).

---

## Repository layout

```
powershell-scripts/
├── Launch.ps1                 # Entry point: opens the launcher menu
├── New-LauncherShortcut.ps1   # Creates a pinnable, elevated Start Menu shortcut
├── README.md
│
├── Scripts/                   # The workflow scripts the launcher runs
│   ├── new-container.ps1
│   ├── New-ProjectContainer.ps1
│   ├── GWSInstallDependencies.ps1
│   ├── UploadLicense.ps1
│   ├── Remove-GWSApps.ps1
│   └── Common/                # Shared helpers (pickers, settings, credentials)
│
├── ScriptLauncher/            # The launcher module (menu engine)
│   ├── ScriptLauncher.psm1 / .psd1
│   ├── Install.ps1            # Registers the module so `launch` works anywhere
│   └── Config/
│       ├── Tasks.psd1              # Menu definition (which script each entry runs)
│       └── Settings.template.json  # Template for your per-user Settings.json
│
├── Tests/                     # Zero-dependency unit test for the tricky logic
└── docs/                      # Design notes
```

Only two scripts live at the root: **`Launch.ps1`** (the launcher) and
**`New-LauncherShortcut.ps1`**. The actual work is done by the scripts under
`Scripts/`, which you normally reach through the launcher.

---

## Using the launcher

`Launch.ps1` opens an arrow-key / type-to-filter menu. It checks for an elevated
session and, if you're not admin, relaunches itself in a new elevated window
(accept the UAC prompt). Pick a task and it introspects that script's parameters,
prompts you for what it needs, shows you the exact command it's about to run, and
executes it.

Menu entries:

| Entry | What it does |
|---|---|
| **New Container → Development** | Fresh `de` sandbox container, no test toolkit (everyday dev). |
| **New Container → Test** | Fresh `de` sandbox container **with** the test toolkit. |
| **Create Project Container** | One step: new test-ready container **+** installs a project's deps (test mode). |
| **Install GWS Dependencies → Development** | Installs a project's transitive GWS deps, skipping test-only apps. |
| **Install GWS Dependencies → Test** | Same, including the project's `app test` dependencies. |
| **Install GWS Dependencies → Customize** | Full control over download / publish / copy / test-app switches. |
| **Upload BC License** | Imports a `.bclicense` into an existing container and restarts it. |
| **Remove GWS Apps** | Uninstalls/unpublishes GWS apps to reset a container (supports a dry run). |
| **Clear Credential Cache** | Forgets the cached container username/password so you're re-prompted. |
| **Settings...** | Edit `AlRoot` and `LicenseFile`. |

### Optional: a `launch` command in every session

Register the module once so you can just type `launch` in any elevated PowerShell:

```powershell
.\ScriptLauncher\Install.ps1
# then, in any new session:
launch
```

`Install.ps1` symlinks (or copies) the `ScriptLauncher` module into your
PowerShell modules folder. A symlink means edits in this repo take effect
immediately; a copy needs a re-run after changes.

### Optional: a pinned Start Menu shortcut

```powershell
.\New-LauncherShortcut.ps1
```

Creates an always-elevated **GWS Launcher** shortcut. Press the Windows key, type
its name, then right-click → *Pin to Start* / *Pin to taskbar*. One click prompts
for UAC once and opens the menu. Re-run this after moving the repo.

---

## Configuration

Two machine-specific paths are configurable; everything else is either a per-run
choice or a fixed team constant.

| Setting | Meaning |
|---|---|
| `AlRoot` | Root folder that contains your AL project checkouts. A bare project name (e.g. `Core`) is resolved as a folder under here, so set this — otherwise pass `-ProjectRoot` as a full path, or the scripts stop with a "configure AlRoot" message. |
| `LicenseFile` | Full path to your BC developer license (`.bclicense`). |

Set them from the launcher's **`Settings...`** menu (recommended), or edit the
file directly:

- `ScriptLauncher/Config/Settings.template.json` — committed, keys present but empty.
- `ScriptLauncher/Config/Settings.json` — **your** per-user copy, created on first
  use and **git-ignored** (so nobody inherits anyone else's paths).

An unset setting falls back to each script's built-in default, so an explicit
parameter on the command line always wins over configuration.

### License file

The `.bclicense` is **never committed** (it's git-ignored). Put your own at
`Scripts/DEV.bclicense` (the default location the scripts look for), or point the
`LicenseFile` setting at wherever you keep it.

### Container credentials

You're prompted **in-terminal** for the BC container username/password the first
time they're needed. They're cached DPAPI-encrypted under
`%LOCALAPPDATA%\GWSInstallDependencies\` (tied to your Windows user + machine) and
shared between the scripts. Use **Clear Credential Cache** in the menu to reset
them.

---

## Running the scripts directly

You don't need the launcher — each script under `Scripts/` runs standalone.
Mandatory parameters prompt natively if omitted. All of these need an elevated
session (except a download/resolve-only dependency run).

| Script | Purpose | Key parameters |
|---|---|---|
| `new-container.ps1` | Create a BC sandbox container + import the license. | `-ContainerName` (required), `-IncludeTestToolkit`, `-LicenseFile` |
| `New-ProjectContainer.ps1` | One step: test-ready container + a project's deps. | `-ContainerName` (required), `-ProjectRoot` (required), `-AlRoot` |
| `GWSInstallDependencies.ps1` | Download → resolve → publish GWS dependency apps. | `-ProjectRoot` (required), `-ContainerName` (required to publish), `-SkipDownload`, `-SkipPublish`, `-SkipTestApps`, `-CopyToProject`, `-AlRoot` |
| `UploadLicense.ps1` | Import a `.bclicense` into an existing container. | `-ContainerName` (required), `-LicenseFile` |
| `Remove-GWSApps.ps1` | Uninstall/unpublish GWS apps to reset a container. | `-ContainerName` (required), `-WhatIf` |

Examples:

```powershell
# Create a dev container
.\Scripts\new-container.ps1 -ContainerName GWS

# Start work on a project: container + its test-mode dependencies in one step
.\Scripts\New-ProjectContainer.ps1 -ContainerName GWS-Core -ProjectRoot Core

# Sync a container with the latest GWS dependency apps
.\Scripts\GWSInstallDependencies.ps1 -ProjectRoot Core -ContainerName GWS

# Download + resolve only — no elevation or container needed
.\Scripts\GWSInstallDependencies.ps1 -ProjectRoot Core -SkipPublish

# Dry-run a reset before actually removing anything
.\Scripts\Remove-GWSApps.ps1 -ContainerName GWS -WhatIf
```

---

## Testing

One self-contained unit test (no Pester needed) guards the trickiest pure logic —
version comparison, highest-version selection, numeric run-folder sorting, and the
auth-failure probe:

```powershell
.\Tests\Test-GWSInstallDependencies.ps1
```

It exits non-zero on failure. If you have PSScriptAnalyzer installed, you can also
lint with `Invoke-ScriptAnalyzer`.

---

## Notes

- **Team constants are hardcoded on purpose**: country `de`, the
  `GWS-gevis / VEO / Release-Canary` Azure DevOps coordinates, and the `GWS`
  publisher filter are the same for everyone and aren't parameters.
- **`GWSInstallDependencies.ps1`** always installs the *newest* dependency app
  version found in the latest CI artifacts (not the minimum declared in
  `app.json`), and never republishes the project's own apps over your local dev
  copy.
- See [`docs/GWSInstallDependencies-Spec.md`](docs/GWSInstallDependencies-Spec.md)
  for the dependency installer's design in detail.
