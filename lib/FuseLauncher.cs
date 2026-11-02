using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

[assembly: AssemblyTitle("fuse-code launcher")]
[assembly: AssemblyProduct("fuse-code")]

public static class FuseLauncher
{
    private const string ArgumentsVariable = "FUSE_ARGUMENTS";
    private const string ArgumentsMarker = ":";

    public static int Main()
    {
        Console.CancelKeyPress += IgnoreCancel;
        Environment.SetEnvironmentVariable(ArgumentsVariable, ArgumentsMarker + ArgumentTail(Environment.CommandLine));
        ProcessStartInfo startInfo = new ProcessStartInfo(WindowsPowerShellPath(), HostArguments(LauncherScriptPath()));
        startInfo.UseShellExecute = false;
        using (Process launcher = Process.Start(startInfo))
        {
            launcher.WaitForExit();
            return launcher.ExitCode;
        }
    }

    private static void IgnoreCancel(object sender, ConsoleCancelEventArgs cancel)
    {
        if (cancel.SpecialKey == ConsoleSpecialKey.ControlC) cancel.Cancel = true;
    }

    private static string WindowsPowerShellPath()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
    }

    private static string LauncherScriptPath()
    {
        return Path.Combine(Environment.GetEnvironmentVariable("USERPROFILE"), ".local", "share", "fuse-code", "bin", "fuse.ps1");
    }

    private static string HostArguments(string scriptPath)
    {
        return "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath + "\"";
    }

    private static bool IsSeparator(char character)
    {
        return character == ' ' || character == '\t';
    }

    private static string ArgumentTail(string commandLine)
    {
        int index = 0;
        if (commandLine.Length > 0 && commandLine[0] == '"')
        {
            int closing = commandLine.IndexOf('"', 1);
            index = closing < 0 ? commandLine.Length : closing + 1;
        }
        else
        {
            while (index < commandLine.Length && !IsSeparator(commandLine[index])) index++;
        }
        while (index < commandLine.Length && IsSeparator(commandLine[index])) index++;
        return commandLine.Substring(index);
    }
}
