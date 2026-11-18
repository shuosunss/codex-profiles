using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

internal sealed class SharedProjectSnapshot
{
    private const int MaxStateBytes = 16 * 1024 * 1024;
    private static readonly Regex Identifier = new Regex("^[a-zA-Z0-9_-]{1,128}$", RegexOptions.CultureInvariant);
    private static readonly Regex ProfileName = new Regex("^[a-z0-9]+(?:-[a-z0-9]+)*$", RegexOptions.CultureInvariant);
    private readonly string home;
    private readonly string profilesRoot;
    private readonly Dictionary<string, ProjectState> memberStates = new Dictionary<string, ProjectState>(StringComparer.OrdinalIgnoreCase);
    private bool wasShared;
    private string cachedSnapshot = "null";

    public SharedProjectSnapshot(string profileHome, string profilesRoot)
    {
        home = LocalPath(profileHome);
        this.profilesRoot = LocalPath(profilesRoot);
    }

    public string Expression(string conversationScript, string projectScript, bool refreshIndependent = true)
    {
        string snapshot = Read();
        if (snapshot == "null" && !wasShared) return refreshIndependent ? conversationScript : null;
        wasShared = snapshot != "null";
        string argument = snapshot == "null" ? "null" : Json.Stringify(snapshot);
        // Quote the snapshot as data and keep the two refreshes independent if either renderer API changes.
        return "(async () => { let project; try { project = (" + projectScript + ")(" + argument
            + "); } catch { project = {status:'retrying'}; } const conversation = await (" + conversationScript
            + "); return {...conversation, project}; })()";
    }

    private string Read()
    {
        if (home == null || profilesRoot == null) return "null";
        try
        {
            string source = SharedHome(home) ?? home;
            var homes = new List<string> { source };
            if (!SamePath(home, source)) homes.Add(home);
            // All registered instances with the same source share one group. Recheck membership after creation or removal.
            if (Directory.Exists(profilesRoot))
            {
                foreach (string profile in Directory.GetDirectories(profilesRoot).OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
                {
                    if (SamePath(profile, source) || SamePath(profile, home) || !ProfileName.IsMatch(Path.GetFileName(profile))) continue;
                    if (SamePath(SharedHome(profile), source)) homes.Add(profile);
                }
            }
            var active = new HashSet<string>(homes, StringComparer.OrdinalIgnoreCase);
            bool changed = memberStates.Count != active.Count;
            foreach (string stale in memberStates.Keys.Where(path => !active.Contains(path)).ToArray()) memberStates.Remove(stale);
            if (homes.Count < 2)
            {
                memberStates.Clear();
                cachedSnapshot = "null";
                return cachedSnapshot;
            }

            foreach (string member in homes)
            {
                ProjectState state;
                if (!memberStates.TryGetValue(member, out state))
                {
                    state = new ProjectState();
                    memberStates.Add(member, state);
                    changed = true;
                }
                if (state.Load(Path.Combine(member, ".codex-global-state.json"))) changed = true;
            }
            if (!changed) return cachedSnapshot;

            var projects = new Dictionary<string, object>();
            var memberships = new Dictionary<string, string>();
            var order = new List<string>();
            var orderedProjectIds = new HashSet<string>();
            string[] peers = homes.Where(member => !SamePath(member, home)).OrderBy(member => !SamePath(member, source))
                .ThenBy(member => member, StringComparer.OrdinalIgnoreCase).ToArray();
            var knownProjects = new HashSet<string>(memberStates[home].Projects.Keys);
            foreach (string peer in peers)
            {
                foreach (var entry in memberStates[peer].Projects)
                {
                    if (!projects.ContainsKey(entry.Key)) projects.Add(entry.Key, entry.Value);
                    knownProjects.Add(entry.Key);
                }
                foreach (string id in memberStates[peer].Order)
                {
                    if (orderedProjectIds.Add(id)) order.Add(id);
                }
            }
            // A chat can be assigned in one instance to a project created by another. Resolve IDs against the whole group.
            foreach (string peer in peers)
            {
                foreach (var entry in memberStates[peer].Memberships)
                {
                    if (knownProjects.Contains(entry.Value) && !memberships.ContainsKey(entry.Key)) memberships.Add(entry.Key, entry.Value);
                }
            }
            cachedSnapshot = Json.Stringify(new { projects = projects, memberships = memberships, order = order });
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        catch (InvalidOperationException) { }
        return cachedSnapshot;
    }

    private static string SharedHome(string path)
    {
        try
        {
            string manifest = Path.Combine(path, "codex-profile.json");
            if (!File.Exists(manifest)) return null;
            string source = LocalPath(Json.Text(ReadObject(manifest), "SharedHome"));
            return SamePath(source, path) ? null : source;
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
        catch (ArgumentException) { return null; }
        catch (InvalidOperationException) { return null; }
    }

    private static string LocalPath(string path)
    {
        if (string.IsNullOrEmpty(path) || !Regex.IsMatch(path, @"^[a-zA-Z]:[/\\]")) return null;
        string full = Path.GetFullPath(path);
        return full.Length == 3 ? full : full.TrimEnd('\\');
    }

    private static bool SamePath(string left, string right)
    {
        return string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
    }

    private sealed class ProjectState
    {
        private DateTime cachedTimestamp;
        private long cachedSize = -1;
        public Dictionary<string, object> Projects = new Dictionary<string, object>();
        public Dictionary<string, string> Memberships = new Dictionary<string, string>();
        public string[] Order = new string[0];

        public bool Load(string statePath)
        {
            try { return LoadIfChanged(statePath); }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
            catch (ArgumentException) { return false; }
            catch (InvalidOperationException) { return false; }
        }

        private bool LoadIfChanged(string statePath)
        {
            var file = new FileInfo(statePath);
            // A temporary read failure retains this member's last complete snapshot until the next tick.
            if (!file.Exists) return false;
            DateTime timestamp = file.LastWriteTimeUtc;
            long size = file.Length;
            if (timestamp == cachedTimestamp && size == cachedSize) return false;
            var state = ReadObject(statePath);
            var projects = new Dictionary<string, object>();
            foreach (var entry in Json.Object(state, "local-projects"))
            {
                var project = entry.Value as Dictionary<string, object>;
                if (project == null || !IsIdentifier(entry.Key) || entry.Key.StartsWith("g-p-", StringComparison.Ordinal)
                    || Json.Text(project, "id") != entry.Key || Json.Text(project, "name").Length == 0) continue;
                if (project.Keys.Any(key => key.IndexOf("ChatGptBacking", StringComparison.OrdinalIgnoreCase) >= 0
                    && project[key] != null)) continue;
                object created;
                object updated;
                string[] paths = Strings(project, "rootPaths");
                if (paths.Length == 0 || !project.TryGetValue("createdAt", out created)
                    || !project.TryGetValue("updatedAt", out updated) || !IsNumber(created) || !IsNumber(updated)) continue;
                // Send only local catalog fields. No account data, project backing, or chat contents enter the payload.
                projects.Add(entry.Key, new { id = entry.Key, name = Json.Text(project, "name"), rootPaths = paths,
                    createdAt = created, updatedAt = updated });
            }
            var memberships = new Dictionary<string, string>();
            var hosts = Json.Object(state, "thread-project-membership-host-ids");
            foreach (var entry in Json.Object(state, "thread-project-assignments"))
            {
                var membership = entry.Value as Dictionary<string, object>;
                if (membership == null || !IsIdentifier(entry.Key) || Json.Text(membership, "projectKind") != "local"
                    || Json.Text(membership, "projectOrigin") == "chatgpt") continue;
                string host = Json.Text(hosts, entry.Key);
                string inlineHost = Json.Text(membership, "hostId");
                if ((host != "" && host != "local") || (inlineHost != "" && inlineHost != "local")) continue;
                string projectId = Json.Text(membership, "projectId");
                if (IsIdentifier(projectId)) memberships.Add(entry.Key, projectId);
            }
            Projects = projects;
            Memberships = memberships;
            Order = Strings(state, "project-order").Where(projects.ContainsKey).ToArray();
            cachedTimestamp = timestamp;
            cachedSize = size;
            return true;
        }
    }

    private static Dictionary<string, object> ReadObject(string path)
    {
        using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var reader = new StreamReader(file, new UTF8Encoding(false, true)))
        {
            if (file.Length > MaxStateBytes) throw new InvalidOperationException("Project state is too large.");
            var parser = new JavaScriptSerializer { MaxJsonLength = MaxStateBytes };
            return parser.Deserialize<Dictionary<string, object>>(reader.ReadToEnd()) ?? new Dictionary<string, object>();
        }
    }

    private static string[] Strings(Dictionary<string, object> data, string key)
    {
        object value;
        if (!data.TryGetValue(key, out value) || !(value is System.Collections.IList)) return new string[0];
        return ((System.Collections.IList)value).OfType<string>().Where(item => !string.IsNullOrWhiteSpace(item)).ToArray();
    }

    private static bool IsIdentifier(string value)
    {
        return value != "__proto__" && value != "constructor" && value != "prototype" && Identifier.IsMatch(value);
    }

    private static bool IsNumber(object value)
    {
        return value is int || value is long || value is decimal || value is double;
    }
}
