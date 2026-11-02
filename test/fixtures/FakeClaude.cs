using System;
using System.IO;
using System.Threading;

public static class FakeClaude
{
    public static int Main()
    {
        string home = Environment.GetEnvironmentVariable("USERPROFILE");
        File.WriteAllText(Path.Combine(home, "fake-claude-command-line.txt"), Environment.CommandLine);
        string claudeDir = Path.Combine(home, ".claude");
        Directory.CreateDirectory(claudeDir);
        File.WriteAllText(Path.Combine(claudeDir, "settings.json"), "{\"theme\":\"dark\",\"model\":\"" + Environment.GetEnvironmentVariable("FAKE_CLAUDE_MODEL") + "\"}");
        string seconds = Environment.GetEnvironmentVariable("FAKE_CLAUDE_SECONDS");
        if (!string.IsNullOrEmpty(seconds)) Thread.Sleep(int.Parse(seconds) * 1000);
        return 0;
    }
}
