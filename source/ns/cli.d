/// `ns` command line: read-only inspection of the command namespace.
/// CLI Dispatch: bare = help (exit 0); unknown command/flag = exit 2 with did-you-mean; stray args = exit 2.
module ns.cli;

import std.algorithm : map, startsWith, min;
import std.algorithm.comparison : levenshteinDistance;
import std.array : array, join;
import std.format : format;
import std.json;
import std.stdio : File;
import command_namespace;
import ns.pathimport;

enum nsVersion = "0.1.0";

enum Exit : int { ok = 0, notFound = 1, conflicts = 1, usage = 2 }

immutable string[] commands = ["which", "conflicts", "help"];

private enum helpText = `ns - inspect the command namespace (read-only)

Usage:
  ns <command> [options]

Commands:
  which <name>   Show what <name> resolves to and what it shadows
  conflicts      List every name claimed more than once
  help           Show this help

Options:
  --json         Machine-readable output (which, conflicts)
  -h, --help     Show help
  --version      Show version

Today ns reads only the legacy PATH import (legacy/...).
Exit codes: 0 ok, 1 not found / conflicts present, 2 usage error.
`;

/// Generic line-writer so tests can capture output.
interface Sink { void put(string s); }

final class FileSink : Sink
{
    File f;
    this(File f) { this.f = f; }
    void put(string s) { f.write(s); }
}

final class BufSink : Sink
{
    string data;
    void put(string s) { data ~= s; }
}

int run(string[] args, File out_, File err_, string[string] env)
{
    return run(args, new FileSink(out_), new FileSink(err_), env, null);
}

private string[] didYouMean(string word, const(string)[] options)
{
    string[] r;
    foreach (o; options)
        if (levenshteinDistance(word, o) <= (word.length <= 4 ? 1 : 2) || o.startsWith(word) && word.length >= 2)
            r ~= o;
    return r;
}

private int usageError(Sink err, string msg, string[] hints = null)
{
    err.put("ns: " ~ msg ~ "\n");
    if (hints.length) err.put("Did you mean: " ~ hints.join(", ") ~ "?\n");
    err.put("Run 'ns --help' for usage.\n");
    return Exit.usage;
}

/// Entry point used by main and tests. `regOverride` lets tests supply a registry.
int run(string[] args, Sink out_, Sink err, string[string] env, Registry regOverride)
{
    if (args.length == 0) { out_.put(helpText); return Exit.ok; }

    // global flags before the command
    bool json;
    string[] rest;
    foreach (a; args)
    {
        if (a == "--json") json = true;
        else rest ~= a;
    }
    if (rest.length == 0) { out_.put(helpText); return Exit.ok; }

    auto cmd = rest[0];
    auto params = rest[1 .. $];
    if (cmd == "-h" || cmd == "--help" || cmd == "help")
    {
        if (params.length) return usageError(err, format("'%s' takes no arguments", cmd));
        out_.put(helpText);
        return Exit.ok;
    }
    if (cmd == "--version")
    {
        if (params.length) return usageError(err, "'--version' takes no arguments");
        out_.put("ns " ~ nsVersion ~ "\n");
        return Exit.ok;
    }
    if (cmd.startsWith("-"))
        return usageError(err, format("unknown option '%s'", cmd), didYouMean(cmd, ["--help", "--version", "--json"]));

    foreach (p; params)
        if (p == "-h" || p == "--help") { out_.put(helpText); return Exit.ok; }
    foreach (p; params)
        if (p.startsWith("-") && p.length > 1)
            return usageError(err, format("unknown option '%s' for '%s'", p, cmd), didYouMean(p, ["--json", "--help"]));

    Registry reg() { return regOverride !is null ? regOverride : loadRegistry(env); }

    switch (cmd)
    {
        case "which":
            if (params.length == 0) return usageError(err, "'which' needs a name: ns which <name>");
            if (params.length > 1) return usageError(err, format("'which' takes one name, got %s: %s", params.length, params.join(" ")));
            return cmdWhich(reg(), params[0], json, out_, err);
        case "conflicts":
            if (params.length) return usageError(err, format("'conflicts' takes no arguments, got: %s", params.join(" ")));
            return cmdConflicts(reg(), json, out_);
        default:
            return usageError(err, format("unknown command '%s'", cmd), didYouMean(cmd, commands));
    }
}

Registry loadRegistry(string[string] env)
{
    auto reg = new Registry;
    importPath(reg, platformOptions(env));
    return reg;
}

private string normalize(string name)
{
    import std.string : toLower;
    version (Windows) return toLower(name);
    else return name;
}

private JSONValue nodeJson(const Node n)
{
    JSONValue j = ["path": n.path, "kind": kindName(n.kind), "source": n.source];
    j["argv"] = JSONValue(n.argv.dup);
    return j;
}

int cmdWhich(Registry reg, string rawName, bool json, Sink out_, Sink err)
{
    auto name = normalize(rawName);
    Resolution res;
    bool tried;
    if (isValidPath(name)) { res = reg.resolve(name); tried = true; }
    if ((!tried || res.status == ResolveStatus.notFound) && !name.startsWith("legacy/") && isValidPath("legacy/" ~ name))
    {
        auto lr = reg.resolve("legacy/" ~ name);
        if (lr.status != ResolveStatus.notFound || !tried) { res = lr; tried = true; }
    }
    if (!tried) res.status = ResolveStatus.notFound;

    final switch (res.status)
    {
        case ResolveStatus.found:
            if (json)
            {
                JSONValue j = ["status": "found"];
                j["node"] = nodeJson(res.node);
                j["chain"] = JSONValue(res.chain.dup);
                j["shadowed"] = JSONValue(res.others.map!(o => nodeJson(o)).array);
                out_.put(j.toString() ~ "\n");
            }
            else
            {
                out_.put(format("%s -> %s\n", res.node.path, res.node.argv.length ? res.node.argv[0] : "(no entry)"));
                out_.put(format("  source: %s\n", res.node.source));
                if (res.chain.length > 1) out_.put("  via: " ~ res.chain.join(" -> ") ~ "\n");
                foreach (o; res.others)
                    out_.put(format("  shadows: %s (%s)\n", o.argv.length ? o.argv[0] : o.path, o.source));
            }
            return Exit.ok;
        case ResolveStatus.ambiguous:
            if (json)
            {
                JSONValue j = ["status": "ambiguous"];
                j["claims"] = JSONValue(res.others.map!(o => nodeJson(o)).array);
                out_.put(j.toString() ~ "\n");
            }
            else
            {
                err.put(format("ns: '%s' is claimed by %s packages and will not be picked silently:\n", rawName, res.others.length));
                foreach (o; res.others) err.put(format("  %s\n", o.source));
            }
            return Exit.notFound;
        case ResolveStatus.aliasLoop:
            err.put(format("ns: '%s' is an alias loop: %s\n", rawName, res.chain.join(" -> ")));
            return Exit.notFound;
        case ResolveStatus.notFound:
            auto leaf = name.startsWith("legacy/") ? name["legacy/".length .. $] : name;
            auto hints = reg.suggest(leaf);
            if (json)
            {
                JSONValue j = ["status": "not-found"];
                j["suggestions"] = JSONValue(hints);
                out_.put(j.toString() ~ "\n");
            }
            else
            {
                err.put(format("ns: '%s' not found in the namespace or on PATH\n", rawName));
                if (hints.length) err.put("Did you mean: " ~ hints.join(", ") ~ "?\n");
            }
            return Exit.notFound;
    }
}

int cmdConflicts(Registry reg, bool json, Sink out_)
{
    auto cs = reg.conflicts();
    if (json)
    {
        JSONValue[] arr;
        foreach (c; cs)
        {
            JSONValue j = ["path": c.path, "kind": c.kind == ConflictKind.refused ? "refused" : "shadowed"];
            j["claims"] = JSONValue(c.claims.map!(o => nodeJson(o)).array);
            arr ~= j;
        }
        out_.put(JSONValue(arr).toString() ~ "\n");
    }
    else if (cs.length == 0)
        out_.put("No conflicts.\n");
    else
    {
        foreach (c; cs)
        {
            out_.put(format("%s  (%s)\n", c.path, c.kind == ConflictKind.refused ? "conflict" : "shadowed"));
            foreach (i, o; c.claims)
                out_.put(format("  %s %s\n", (i == 0 && c.kind == ConflictKind.shadowed) ? "wins:   " : "shadowed:",
                    o.argv.length ? o.argv[0] : o.source));
        }
        out_.put(format("%s name(s) with more than one claim.\n", cs.length));
    }
    return cs.length ? Exit.conflicts : Exit.ok;
}

version (unittest)
{
    private Registry sample()
    {
        string[][string] fs = ["/a": ["git", "python3"], "/b": ["git", "node"]];
        PathImportOptions o;
        o.pathVar = "/a:/b";
        o.listDir = (string d) => fs.get(d, null);
        auto r = new Registry;
        importPath(r, o);
        return r;
    }

    private int t(string[] args, out string o, out string e, Registry reg = null)
    {
        auto so = new BufSink, se = new BufSink;
        auto code = run(args, so, se, null, reg is null ? sample() : reg);
        o = so.data; e = se.data;
        return code;
    }
}

unittest
{
    import std.algorithm : canFind;
    string o, e;
    // bare = help, exit 0
    assert(t([], o, e) == 0 && o.canFind("Usage:"));
    assert(t(["--help"], o, e) == 0 && o.canFind("Usage:"));
    assert(t(["help"], o, e) == 0);
    assert(t(["--version"], o, e) == 0 && o.canFind(nsVersion));
    // unknown command: exit 2, did-you-mean on stderr
    assert(t(["wich"], o, e) == 2 && e.canFind("unknown command") && e.canFind("which"));
    assert(t(["conflict"], o, e) == 2 && e.canFind("conflicts"));
    // unknown flags
    assert(t(["--jsn"], o, e) == 2 && e.canFind("--json"));
    assert(t(["which", "git", "--bogus"], o, e) == 2);
    // stray args rejected
    assert(t(["which"], o, e) == 2);
    assert(t(["which", "git", "node"], o, e) == 2 && e.canFind("takes one name"));
    assert(t(["conflicts", "extra"], o, e) == 2);
    assert(t(["help", "x"], o, e) == 2);
}

unittest
{
    import std.algorithm : canFind;
    import std.path : buildPath;
    string o, e;
    assert(t(["which", "git"], o, e) == 0);
    assert(o.canFind("legacy/git -> " ~ buildPath("/a", "git")) && o.canFind("shadows: " ~ buildPath("/b", "git")));
    assert(t(["which", "legacy/node"], o, e) == 0 && o.canFind(buildPath("/b", "node")));
    assert(t(["which", "gitt"], o, e) == 1 && e.canFind("legacy/git"));
    assert(t(["which", "Bad Name"], o, e) == 1);
    assert(t(["--json", "which", "git"], o, e) == 0);
    auto j = parseJSON(o);
    assert(j["status"].str == "found" && j["shadowed"].array.length == 1);

    assert(t(["conflicts"], o, e) == 1 && o.canFind("legacy/git") && o.canFind("1 name(s)"));
    assert(t(["conflicts", "--json"], o, e) == 1 && parseJSON(o).array.length == 1);

    auto empty = new Registry;
    assert(t(["conflicts"], o, e, empty) == 0 && o.canFind("No conflicts."));
}

unittest
{
    import std.algorithm : canFind;
    // NS-3 ambiguity surfaces from which
    auto reg = new Registry;
    Node a = { path: "python", source: "manifest:a@1", argv: ["a"] };
    Node b = { path: "python", source: "manifest:b@1", argv: ["b"] };
    reg.register(a); reg.register(b);
    string o, e;
    assert(t(["which", "python"], o, e, reg) == 1 && e.canFind("will not be picked silently"));
}
