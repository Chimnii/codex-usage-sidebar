# Copy patcher

The managed-copy workflow invokes Invoke-AppRepatch.ps1 on an owned copy.
It validates JavaScript structure, adds Layer, updates the EXE's ASAR integrity
resource, and verifies the resulting pair.

Build-AppPatch.ps1 prepares a new pair. Apply-AppPatch.ps1 and Restore-AppPatch.ps1
provide verified file replacement and restoration. Unknown or ambiguous hooks are
rejected. Electron fuses are unchanged. Modified EXEs lose their original publisher signature.

Use root Setup.cmd / Update.cmd; do not point low-level tools at WindowsApps.
See the root THIRD_PARTY_NOTICES.md for dependencies.
