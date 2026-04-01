# Error patterns for Windows builds
# Return array of hashtables: @{ Pattern = "..."; Description = "..."; Fix = { param($log) ... } }

@(
    @{
        Pattern     = "'[^']+ is not recognized as an internal or external command"
        Description = "Command not found"
        Fix         = { param($log) Fix-MissingCommand $log }
    },
    @{
        Pattern     = "The system cannot find the (file|path) specified"
        Description = "Missing file or directory"
        Fix         = { param($log) Fix-MissingPath $log }
    },
    @{
        Pattern     = "Access is denied"
        Description = "Access denied (permission or file lock)"
        Fix         = { param($log) Fix-Permission $log }
    },
    @{
        Pattern     = "error MSB\d+"
        Description = "MSBuild error"
        Fix         = { param($log) Fix-MSBuild $log }
    },
    @{
        Pattern     = "error LNK\d+"
        Description = "MSVC linker error"
        Fix         = { param($log) Fix-Linker $log }
    },
    @{
        Pattern     = "fatal error C\d+"
        Description = "C/C++ compiler fatal error"
        Fix         = { param($log) Fix-CompilerFatal $log }
    },
    @{
        Pattern     = "error: could not compile"
        Description = "Rust compilation error"
        Fix         = { param($log) Fix-RustCompile $log }
    },
    @{
        Pattern     = "cargo is not recognized|cargo: command not found"
        Description = "Cargo not installed"
        Fix         = { param($log) Fix-InstallRust $log }
    },
    @{
        Pattern     = "The Windows SDK .* was not found"
        Description = "Windows SDK missing"
        Fix         = { param($log) Fix-WindowsSDK $log }
    },
    @{
        Pattern     = "There is not enough space on the disk"
        Description = "Disk full"
        Fix         = { param($log) Fix-DiskSpace $log }
    },
    @{
        Pattern     = "The process cannot access the file because it is being used"
        Description = "File locked by another process"
        Fix         = { param($log) Fix-FileLock $log }
    },
    @{
        Pattern     = "npm ERR!"
        Description = "npm error"
        Fix         = { param($log) Fix-NpmError $log }
    },
    @{
        Pattern     = "nuget.*Unable to resolve"
        Description = "NuGet dependency resolution failure"
        Fix         = { param($log) Fix-NuGet $log }
    },
    @{
        Pattern     = "error: failed to run custom build command"
        Description = "Rust build script failure"
        Fix         = { param($log) Fix-RustBuildScript $log }
    }
)
