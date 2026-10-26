import std.stdio : stdout, stderr;
import std.process : environment;
import name_tool.cli : run;

int main(string[] args)
{
    return run(args[1 .. $], stdout, stderr, environment.toAA());
}
