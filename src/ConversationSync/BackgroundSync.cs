using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

internal static class BackgroundSync
{
    [STAThread]
    private static int Main(string[] arguments)
    {
        if (arguments.Length != 6 || arguments[0] != "--attach") return 2;
        string statusFile = Decode(arguments[3]);
        try
        {
            int processId = int.Parse(arguments[1]);
            string[] uiDirectories = Decode(arguments[2]).Split('\0');
            string lockKey;
            using (SHA256 hash = SHA256.Create())
            {
                lockKey = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(statusFile.ToLowerInvariant()))).Replace("-", "");
            }
            using (Mutex mutex = new Mutex(false, "Local\\CodexProfilesConversationSync." + lockKey))
            {
                bool owns;
                try { owns = mutex.WaitOne(0); }
                catch (AbandonedMutexException) { owns = true; }
                if (!owns)
                {
                    // A recently closed app may still have a helper finishing its last RPC call.
                    try { owns = mutex.WaitOne(20000); }
                    catch (AbandonedMutexException) { owns = true; }
                    if (!owns) return 0;
                }
                try
                {
                    using (Process process = Process.GetProcessById(processId))
                    {
                        // The registry root includes the peer profiles and the real home can differ from the status directory.
                        var snapshot = new SharedProjectSnapshot(Decode(arguments[4]), Decode(arguments[5]));
                        Run(process, uiDirectories, statusFile, snapshot);
                    }
                }
                finally { mutex.ReleaseMutex(); }
            }
            return 0;
        }
        catch
        {
            // Persist a small local status only. Account data and protocol payloads are never logged.
            WriteStatus(statusFile, "connection-failed", 0);
            return 1;
        }
    }

    private static string Decode(string value)
    {
        return Encoding.UTF8.GetString(Convert.FromBase64String(value));
    }

    private static void Run(Process process, string[] uiDirectories, string statusFile, SharedProjectSnapshot snapshot)
    {
        string script = EmbeddedScript("conversation-sync.js");
        string projectScript = EmbeddedScript("project-sync.js");
        WriteStatus(statusFile, "connecting", 0);
        Uri endpoint = WaitForEndpoint(process, uiDirectories);
        if (endpoint == null)
        {
            WriteStatus(statusFile, process.HasExited ? "stopped" : "restart-required", 0);
            return;
        }

        // Reuse the reference enhancer's loopback CDP transport, with no anonymous pipes.
        while (!process.HasExited)
        {
            try
            {
                using (LocalProtocol protocol = new LocalProtocol(new LoopbackChannel(endpoint)))
                {
                    Enhance(process, protocol, script, projectScript, snapshot, statusFile);
                }
            }
            catch
            {
                if (process.HasExited) break;
                WriteStatus(statusFile, "reconnecting", 0);
                Thread.Sleep(2000);
            }
        }
        WriteStatus(statusFile, "stopped", 0);
    }

    private static string EmbeddedScript(string name)
    {
        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        using (StreamReader reader = new StreamReader(stream, Encoding.UTF8)) return reader.ReadToEnd();
    }

    private static Uri WaitForEndpoint(Process process, string[] uiDirectories)
    {
        DateTime oldest = process.StartTime.ToUniversalTime().AddSeconds(-2);
        for (int attempt = 0; attempt < 120 && !process.HasExited; attempt++)
        {
            foreach (string directory in uiDirectories)
            {
                string portFile = Path.Combine(directory, "DevToolsActivePort");
                if (!File.Exists(portFile) || File.GetLastWriteTimeUtc(portFile) < oldest) continue;
                string[] lines;
                try { lines = File.ReadAllLines(portFile); }
                catch (IOException) { continue; }
                int port;
                if (lines.Length >= 2 && int.TryParse(lines[0], out port) && port > 0 && port <= 65535
                    && lines[1].StartsWith("/devtools/browser/", StringComparison.Ordinal)
                    && lines[1].IndexOfAny(new[] { '?', '#', '\\' }) < 0)
                {
                    return new Uri("ws://127.0.0.1:" + port + lines[1]);
                }
            }
            Thread.Sleep(250);
        }
        return null;
    }

    private static void Enhance(Process process, LocalProtocol protocol, string script, string projectScript,
        SharedProjectSnapshot snapshot, string statusFile)
    {
        Dictionary<string, string> sessions = new Dictionary<string, string>();
        string previousStatus = "";
        long previousRefresh = 0;
        string previousProject = "";
        while (!process.HasExited)
        {
            Dictionary<string, object> response = protocol.Call("Target.getTargets");
            HashSet<string> live = new HashSet<string>();
            string expression = snapshot.Expression(script, projectScript);
            foreach (object item in (IEnumerable)response["targetInfos"])
            {
                Dictionary<string, object> target = (Dictionary<string, object>)item;
                // Only the installed app's own main page receives the refresh script.
                if (Json.Text(target, "type") != "page" || Json.Text(target, "url") != "app://-/index.html") continue;
                string id = Json.Text(target, "targetId");
                live.Add(id);
                string session;
                if (!sessions.TryGetValue(id, out session))
                {
                    session = Json.Text(protocol.Call("Target.attachToTarget", new { targetId = id, flatten = true }), "sessionId");
                    sessions[id] = session;
                }
                try
                {
                    Dictionary<string, object> evaluated = protocol.Call("Runtime.evaluate", new {
                        expression = expression, returnByValue = true, awaitPromise = true
                    }, session);
                    Dictionary<string, object> value = Json.Object(Json.Object(evaluated, "result"), "value");
                    string status = evaluated.ContainsKey("exceptionDetails") ? "unsupported-version" : Json.Text(value, "status");
                    long refreshed = value.ContainsKey("lastRefresh") ? Convert.ToInt64(value["lastRefresh"]) : 0;
                    string projectStatus = Json.Text(Json.Object(value, "project"), "status");
                    if (status != previousStatus || refreshed != previousRefresh || projectStatus != previousProject)
                    {
                        WriteStatus(statusFile, status, refreshed, projectStatus);
                        previousStatus = status;
                        previousRefresh = refreshed;
                        previousProject = projectStatus;
                    }
                }
                catch
                {
                    // Renderer replacement invalidates its old CDP session. Attach again on the next tick.
                    sessions.Remove(id);
                }
            }
            foreach (string id in sessions.Keys.Where(id => !live.Contains(id)).ToArray()) sessions.Remove(id);
            Thread.Sleep(2000);
        }
    }

    private static void WriteStatus(string file, string status, long refreshed, string projectStatus = "")
    {
        // The launcher prepares the status directory. A late write must not recreate a removed profile.
        if (!Directory.Exists(Path.GetDirectoryName(file))) return;
        string temporary = file + "." + Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllText(temporary, Json.Stringify(new { state = status, lastRefresh = refreshed, projects = projectStatus }), new UTF8Encoding(false));
        if (File.Exists(file)) File.Replace(temporary, file, null);
        else File.Move(temporary, file);
    }
}
