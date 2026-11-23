namespace SoulspireLauncher.Models;

public sealed class InstallDiagnostics
{
    public bool FfxiDetected { get; set; }
    public string FfxiRegion { get; set; } = "Unknown";
    public string DetectedFfxiPath { get; set; } = string.Empty;
    public string DetectedPolPath { get; set; } = string.Empty;

    public bool AshitaInstalled { get; set; }
    public bool XiloaderInstalled { get; set; }
    public string XiloaderPath { get; set; } = string.Empty;
    public bool PivotPluginInstalled { get; set; }
    public bool TalentsAddonSynced { get; set; }
    public bool CrystalSocketAddonSynced { get; set; }
    public bool MetricsAddonSynced { get; set; }
    public bool CheckerAddonInstalled { get; set; }
    public bool MobDbAddonSynced { get; set; }
    public bool KazenoeyeAddonSynced { get; set; }
    public bool GearAddonSynced { get; set; }
    public bool DatOverlaySynced { get; set; }

    public bool DirectPlayEnabled { get; set; }
    public bool VcRedistX86Present { get; set; }

    // Read-only native crystaljobs.dll diagnostics (Phase 1)
    public string NativeSelectedChannel { get; set; } = "UNKNOWN";
    public string NativeExpectedDllSha256 { get; set; } = "UNKNOWN";
    public string NativeInstalledDllSha256 { get; set; } = "UNKNOWN";
    public string NativeDllSha256Status { get; set; } = "UNKNOWN";
    public string NativeDllArchitecture { get; set; } = "UNKNOWN";
    public string NativeDllArchitectureStatus { get; set; } = "UNKNOWN";
    public string NativeRegistryCompiledHash { get; set; } = "UNKNOWN";
    public string NativeHookCount { get; set; } = "UNKNOWN";
    public string NativeDllFilePath { get; set; } = "UNKNOWN";
    public string NativeLoadedModuleStatus { get; set; } = "UNKNOWN";
    public string NativeLoadedModuleDetail { get; set; } = "FFXI / pol.exe not inspected";
}
