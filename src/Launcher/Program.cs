using System;
using System.IO;
using System.IO.Compression;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static int Main(string[] arguments)
    {
        bool validateOnly = arguments.Length == 1 && arguments[0] == "--self-test";
        try
        {
            string runtimeRoot = ExtractRuntime();
            string guiPath = Path.Combine(runtimeRoot, "scripts", "windows", "Show-CodexProfiles.ps1");
            // Host the existing PowerShell logic on this EXE's STA thread, without a console child.
            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            using (PowerShell shell = PowerShell.Create())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                shell.Runspace = runspace;
                shell.AddScript(File.ReadAllText(guiPath, Encoding.UTF8));
                shell.AddParameter("RuntimeRoot", runtimeRoot);
                if (validateOnly)
                {
                    shell.AddParameter("ValidateOnly");
                }
                shell.Invoke();
                if (shell.HadErrors)
                {
                    StringBuilder errors = new StringBuilder();
                    foreach (ErrorRecord error in shell.Streams.Error)
                    {
                        errors.AppendLine(error.ToString());
                    }
                    throw new InvalidOperationException(errors.ToString());
                }
                return 0;
            }
        }
        catch (Exception error)
        {
            if (validateOnly)
            {
                Console.Error.WriteLine(error.ToString());
            }
            if (!validateOnly)
            {
                MessageBox.Show(error.Message, "Codex Profiles 启动失败",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            return 1;
        }
    }

    private static string ExtractRuntime()
    {
        byte[] payload;
        using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("CodexProfiles.Runtime.zip"))
        using (MemoryStream buffer = new MemoryStream())
        {
            if (resource == null)
            {
                throw new InvalidOperationException("The embedded runtime is missing.");
            }
            resource.CopyTo(buffer);
            payload = buffer.ToArray();
        }

        string hash;
        using (SHA256 algorithm = SHA256.Create())
        {
            hash = BitConverter.ToString(algorithm.ComputeHash(payload)).Replace("-", "").ToLowerInvariant();
        }
        string runtimeBase = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CodexProfilesLauncher", "runtime");
        // Keep extracted paths within the Windows PowerShell 5.1 / .NET Framework path limit.
        string runtimeRoot = Path.Combine(runtimeBase, hash.Substring(0, 24));

        // A version-specific lock and atomic directory rename prevent partial runtime reuse.
        using (Mutex mutex = new Mutex(false, "Local\\CodexProfilesRuntime." + hash))
        {
            bool ownsMutex;
            try
            {
                ownsMutex = mutex.WaitOne(TimeSpan.FromSeconds(30));
            }
            catch (AbandonedMutexException)
            {
                ownsMutex = true;
            }
            if (!ownsMutex)
            {
                throw new TimeoutException("Another launcher is preparing the runtime. Try again shortly.");
            }
            try
            {
                if (Directory.Exists(runtimeRoot))
                {
                    return runtimeRoot;
                }
                Directory.CreateDirectory(runtimeBase);
                string stagingRoot = Path.Combine(runtimeBase, "tmp-" + Guid.NewGuid().ToString("N").Substring(0, 12));
                Directory.CreateDirectory(stagingRoot);
                using (MemoryStream stream = new MemoryStream(payload))
                using (ZipArchive archive = new ZipArchive(stream, ZipArchiveMode.Read))
                {
                    foreach (ZipArchiveEntry entry in archive.Entries)
                    {
                        string destination = Path.GetFullPath(Path.Combine(stagingRoot, entry.FullName));
                        if (!destination.StartsWith(stagingRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                        {
                            throw new InvalidDataException("An embedded runtime path is invalid.");
                        }
                        Directory.CreateDirectory(Path.GetDirectoryName(destination));
                        entry.ExtractToFile(destination);
                    }
                }
                Directory.Move(stagingRoot, runtimeRoot);
                return runtimeRoot;
            }
            finally
            {
                mutex.ReleaseMutex();
            }
        }
    }
}
