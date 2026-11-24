namespace SoulspireLauncher.Models;

public sealed class ServerStatus
{
    public bool IsOnline { get; set; }
    public bool LobbyReachable { get; set; }
    public bool SearchReachable { get; set; }
    public bool? ProfileReachable { get; set; }
    public bool? ProfilePortReachable { get; set; }
    public bool? ProfileIrcPortReachable { get; set; }
    public string? ProfileFailureDetail { get; set; }
    public int LatencyMs { get; set; }
    public string Host { get; set; } = string.Empty;
    public DateTimeOffset CheckedAt { get; set; } = DateTimeOffset.UtcNow;
    public string SummaryText { get; set; } = "Checking server...";
}
