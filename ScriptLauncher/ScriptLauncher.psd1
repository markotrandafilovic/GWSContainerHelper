@{
    RootModule        = 'ScriptLauncher.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'cff2b621-d985-42c9-a9f2-ca7a2c9b3f3f'
    Author            = 'marko'
    Description       = 'Menu-driven launcher for the scripts in this repo -- shows a picker, introspects the chosen script''s param() block, prompts for values, and runs it.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Start-ScriptLauncher')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('launch')
}
