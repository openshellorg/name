/// Import the platform PATH into the `legacy/` subtree (NS-5).
module name_tool.pathimport;

import std.algorithm : splitter, map, filter, canFind, endsWith;
import std.array : array;
import std.path : buildPath, baseName, extension, stripExtension;
import std.string : toLower, strip;
import std.uni : sicmp;
import command_namespace;

/// Lists the regular file names in a folder. Swappable so tests need no real disk layout.
alias ListDir = string[] delegate(string dir);

/// Settings for one import.
struct PathImportOptions
{
    string pathVar;           /// raw PATH value
    char sep = ':';           /// ';' on Windows
    string[] exts;            /// PATHEXT entries in order (".COM", ".EXE", ...); empty = take any file as-is
    bool caseInsensitive;     /// fold names (Windows)
    ListDir listDir;          /// defaults to the real file system
}

/// Default options for the running platform, read from the environment map.
PathImportOptions platformOptions(string[string] env)
{
    PathImportOptions o;
    version (Windows)
    {
        o.sep = ';';
        o.caseInsensitive = true;
        auto pe = "PATHEXT" in env;
        string raw = pe ? *pe : ".COM;.EXE;.BAT;.CMD";
        o.exts = raw.splitter(';').map!(x => x.strip).filter!(x => x.length > 0).array;
        foreach (k, v; env) if (sicmp(k, "PATH") == 0) { o.pathVar = v; break; }
    }
    else
    {
        if (auto p = "PATH" in env) o.pathVar = *p;
    }
    return o;
}

/// Real directory lister: regular files (and, off Windows, only executable ones).
string[] listRealDir(string dir)
{
    import std.file : dirEntries, SpanMode, exists, isDir, FileException;
    string[] r;
    try
    {
        if (!exists(dir) || !isDir(dir)) return r;
        foreach (e; dirEntries(dir, SpanMode.shallow, false))
        {
            try
            {
                if (!e.isFile) continue;
                version (Posix) { if ((e.attributes & octal!111) == 0) continue; }
                r ~= baseName(e.name);
            }
            catch (FileException) {}
        }
    }
    catch (FileException) {}
    return r;
}

private import std.conv : octal;

/// Turn a file name into a legacy command name, or null when the file is not a command.
/// Returns the rank of its extension in PATHEXT (lower wins inside one folder).
private string commandName(string file, const PathImportOptions o, out size_t rank)
{
    rank = 0;
    if (o.exts.length)
    {
        auto ext = extension(file);
        if (ext.length == 0) return null;
        foreach (i, x; o.exts)
            if (sicmp(x, ext) == 0) { rank = i; return toLower(stripExtension(file)); }
        return null;
    }
    return o.caseInsensitive ? toLower(file) : file;
}

/// Register every PATH command under `legacy/<name>`, PATH order first, shadowing reported.
/// Returns the number of names that could not be expressed as node paths (skipped).
size_t importPath(Registry reg, PathImportOptions o)
{
    import std.functional : toDelegate;
    ListDir lister = o.listDir !is null ? o.listDir : toDelegate(&listRealDir);
    size_t skipped;
    bool[string] seenDir;
    foreach (rawDir; o.pathVar.splitter(o.sep))
    {
        auto dir = rawDir.strip;
        if (dir.length >= 2 && dir[0] == '"' && dir[$ - 1] == '"') dir = dir[1 .. $ - 1];
        if (dir.length == 0) continue;
        auto key = o.caseInsensitive ? toLower(dir) : dir;
        if (key in seenDir) continue; // duplicate PATH entries are not real conflicts
        seenDir[key] = true;

        // inside one folder, keep the best PATHEXT match per name
        string[string] bestFile;
        size_t[string] bestRank;
        foreach (f; lister(dir))
        {
            size_t rank;
            auto name = commandName(f, o, rank);
            if (name is null) continue;
            if (auto br = name in bestRank) { if (rank >= *br) continue; }
            bestRank[name] = rank;
            bestFile[name] = f;
        }
        import std.algorithm : sort;
        auto names = bestFile.keys;
        names.sort();
        foreach (name; names)
        {
            auto p = "legacy/" ~ name;
            if (!isValidPath(p)) { skipped++; continue; }
            Node n;
            n.path = p;
            n.kind = NodeKind.command;
            n.argv = [buildPath(dir, bestFile[name])];
            n.source = "legacy:PATH:" ~ dir;
            n.policy = ConflictPolicy.shadowWithWarning;
            reg.register(n);
        }
    }
    return skipped;
}

unittest
{
    string[][string] fs = [
        "/a": ["git", "python3", "Weird Name"],
        "/b": ["git", "node"],
    ];
    PathImportOptions o;
    o.pathVar = "/a:/b:/a:";
    o.listDir = (string d) => fs.get(d, null);
    auto reg = new Registry;
    assert(importPath(reg, o) == 1); // "Weird Name" is not a valid word
    auto r = reg.resolve("legacy/git");
    assert(r.status == ResolveStatus.found);
    assert(r.node.source == "legacy:PATH:/a");
    assert(r.others.length == 1 && r.others[0].source == "legacy:PATH:/b");
    assert(reg.conflicts().length == 1); // /a listed twice is not a conflict
}

unittest
{
    // Windows: PATHEXT order inside a folder, case folding, ';' separator.
    string[][string] fs = [
        `C:\x`: ["Tool.CMD", "tool.exe", "readme.txt", "Git.exe"],
        `C:\y`: ["git.EXE"],
    ];
    PathImportOptions o;
    o.pathVar = `C:\x;"C:\y"`;
    o.sep = ';';
    o.exts = [".COM", ".EXE", ".BAT", ".CMD"];
    o.caseInsensitive = true;
    o.listDir = (string d) => fs.get(d, null);
    auto reg = new Registry;
    importPath(reg, o);
    auto t = reg.resolve("legacy/tool");
    assert(t.status == ResolveStatus.found);
    assert(t.node.argv[0].endsWith("tool.exe"));
    assert(t.others.length == 0); // same-folder pick is not a conflict
    assert(reg.resolve("legacy/readme").status == ResolveStatus.notFound);
    assert(reg.resolve("legacy/git").others.length == 1);
}
