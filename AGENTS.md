# BrainTrace repository instructions

- Target Windows PowerShell 5.1 and keep the MVP small and understandable.
- Keep DEV topology and operational values configuration-driven.
- Never use command-supplied cleanup paths; CLEAN uses trusted local node configuration only.
- Preserve the global rule that CLEAN cannot begin unless every required STOP succeeds.
- Keep `-DryRun` free of command publication and physical effects.
- Update `CHANGELOG.md` whenever a change is notable to users, operators, configuration, safety, compatibility, or releases.
- At the end of every implementation response, suggest one concise English commit message describing the completed change.
