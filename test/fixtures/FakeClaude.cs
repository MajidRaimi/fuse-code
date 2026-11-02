using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class FakeClaude
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int count);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    private static string[] SplitCommandLine(string commandLine)
    {
        int count;
        IntPtr argv = CommandLineToArgvW(commandLine, out count);
        try
        {
            string[] arguments = new string[count];
            for (int index = 0; index < count; index++) arguments[index] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, index * IntPtr.Size));
            return arguments;
        }
        finally
        {
            LocalFree(argv);
        }
    }

    private static string EncodeLines(string[] arguments)
    {
        StringBuilder lines = new StringBuilder();
        for (int index = 1; index < arguments.Length; index++) lines.AppendLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(arguments[index])));
        return lines.ToString();
    }

    public static int Main()
    {
        string home = Environment.GetEnvironmentVariable("USERPROFILE");
        File.WriteAllText(Path.Combine(home, "fake-claude-command-line.txt"), Environment.CommandLine);
        File.WriteAllText(Path.Combine(home, "fake-claude-argv.txt"), EncodeLines(SplitCommandLine(Environment.CommandLine)));
        string claudeDir = Path.Combine(home, ".claude");
        Directory.CreateDirectory(claudeDir);
        File.WriteAllText(Path.Combine(claudeDir, "settings.json"), "{\"theme\":\"dark\",\"model\":\"" + Environment.GetEnvironmentVariable("FAKE_CLAUDE_MODEL") + "\"}");
        string seconds = Environment.GetEnvironmentVariable("FAKE_CLAUDE_SECONDS");
        if (!string.IsNullOrEmpty(seconds)) Thread.Sleep(int.Parse(seconds) * 1000);
        return 0;
    }
}
