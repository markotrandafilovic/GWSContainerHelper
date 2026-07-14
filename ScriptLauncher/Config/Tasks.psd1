@{
    # Script paths are resolved by ScriptLauncher.psm1 against the module root
    # (this file's parent's parent folder), not by Import-PowerShellDataFile --
    # .psd1 data files can't contain variables, so relative-path resolution has
    # to happen in code. Absolute paths also work if you ever need one.
    #
    # A top-level entry is either:
    #   - a GROUP: has a 'Submenu' array of leaf tasks. Selecting it in the menu
    #     opens a submenu (arrow-key/type-to-filter, Esc to go back).
    #   - a LEAF task: has a 'Script'. Selecting it runs the script.
    #
    # A leaf task can optionally set:
    #   - Parameters (hashtable): silent preset values -- never prompted for.
    #     That's how the two "New Container" entries share one script but each
    #     pin IncludeTestToolkit differently, and how the Development dependency
    #     entry pins SkipTestApps.
    #   - PromptParameters (string[]): curates which *optional* parameters get
    #     asked about. If present, every optional parameter not listed here (and
    #     not in Parameters/Pickers) is silently skipped. Omit the key entirely
    #     to fall back to asking about every optional parameter.
    #   - Pickers (hashtable): resolves a parameter from an interactive list up
    #     front instead of a text prompt. 'Container' lists BC containers;
    #     'ALProject' lists AL projects. Takes precedence over PromptParameters.
    #     The "New Container" entries omit it so ContainerName stays a typed NEW
    #     (and mandatory) name.
    #
    # Menu order below is the on-screen order. The launcher appends two synthetic
    # entries after these -- "Clear Credential Cache" then "Settings..." (last).
    Tasks = @(
        @{
            Name    = 'New Container'
            Submenu = @(
                # Dev container: no test toolkit. Test container: with it. Each
                # only asks for the mandatory (typed) ContainerName.
                @{
                    Name             = 'Development'
                    Script           = '..\Scripts\new-container.ps1'
                    Parameters       = @{ IncludeTestToolkit = $false }
                    PromptParameters = @()
                }
                @{
                    Name             = 'Test'
                    Script           = '..\Scripts\new-container.ps1'
                    Parameters       = @{ IncludeTestToolkit = $true }
                    PromptParameters = @()
                }
            )
        }
        # One-shot "start work on a project": creates a fresh container WITH the
        # test toolkit, then installs that project's dependencies in test mode
        # (both behaviours are baked into New-ProjectContainer.ps1). Pick the
        # project from a list; type the NEW container name (mandatory, no
        # picker); nothing else is asked (AlRoot uses its default).
        @{
            Name             = 'Create Project Container'
            Script           = '..\Scripts\New-ProjectContainer.ps1'
            Pickers          = @{ ProjectRoot = 'ALProject' }
            PromptParameters = @()
        }
        @{
            Name    = 'Install GWS Dependencies'
            Submenu = @(
                # Dev flavour: skips the project's 'app test' layout so no
                # test-only apps are published. Container + project picked from
                # lists; AlRoot uses its default.
                @{
                    Name             = 'Development'
                    Script           = '..\Scripts\GWSInstallDependencies.ps1'
                    Parameters       = @{ SkipTestApps = $true }
                    Pickers          = @{ ContainerName = 'Container'; ProjectRoot = 'ALProject' }
                    PromptParameters = @()
                }
                # Test flavour: full behaviour (includes 'app test' deps).
                @{
                    Name             = 'Test'
                    Script           = '..\Scripts\GWSInstallDependencies.ps1'
                    Pickers          = @{ ContainerName = 'Container'; ProjectRoot = 'ALProject' }
                    PromptParameters = @()
                }
                # Full-control entry: container + project still picked from lists,
                # but AlRoot and the download/publish/copy/test-app skips are all
                # asked, for tweaked runs.
                @{
                    Name             = 'Customize'
                    Script           = '..\Scripts\GWSInstallDependencies.ps1'
                    Pickers          = @{ ContainerName = 'Container'; ProjectRoot = 'ALProject' }
                    PromptParameters = @('AlRoot', 'SkipDownload', 'CopyToProject', 'SkipPublish', 'SkipTestApps')
                }
            )
        }
        @{
            Name    = 'Upload BC License'
            Script  = '..\Scripts\UploadLicense.ps1'
            Pickers = @{ ContainerName = 'Container' }
        }
        @{
            Name             = 'Remove GWS Apps'
            Script           = '..\Scripts\Remove-GWSApps.ps1'
            Pickers          = @{ ContainerName = 'Container' }
            PromptParameters = @('WhatIf')
        }
    )
}
