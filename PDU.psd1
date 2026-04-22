@{
    ModuleVersion     = '1.0.0'
    GUID              = 'a3f1e2d4-5b6c-4d7e-8f9a-0b1c2d3e4f5a'
    Author            = 'YourNameHere'           # <-- replace with your name / GitHub username
    Copyright         = '(c) 2026 YourNameHere'  # <-- replace
    Description       = 'Interactive TUI disk usage browser for PowerShell, modelled on NCDU. Navigate your filesystem by size with keyboard-driven browsing.'
    PowerShellVersion = '5.1'
    RootModule        = 'PDU.psm1'
    FunctionsToExport = @('Start-PDU')
    AliasesToExport   = @('pdu')
    PrivateData       = @{
        PSData = @{
            Tags        = @('disk', 'usage', 'tui', 'ncdu', 'interactive', 'filesystem', 'du', 'console')
            ProjectUri  = 'https://github.com/YourNameHere/PDU'  # <-- replace with your repo URL
            LicenseUri  = 'https://github.com/YourNameHere/PDU/blob/main/LICENSE'  # <-- optional but recommended
            ReleaseNotes = 'Initial release. NCDU-style interactive disk usage browser for PowerShell.'
        }
    }
}
