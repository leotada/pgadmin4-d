/// Renders templates for differential testing against Python's Jinja2.
///
/// Usage: jinja-cli <pgadmin dir> < cases.jsonl > results.jsonl
/// Each input line: {"t": "<template name>", "ctx": {...}}. Each output line: {"out": "..."} or {"err": "..."}.
module jinja_cli;

import std.stdio;
import std.string : chomp;
import pgadmin.core.value;
import pgadmin.core.templates;

void main(string[] args)
{
    auto env = createEnvironment(args[1]);
    foreach (line; stdin.byLineCopy)
    {
        auto l = line.chomp;
        if (l.length == 0)
            continue;
        auto res = Value.newDict();
        try
        {
            auto c = parseJson(l);
            Value[string] vars;
            foreach (k, v; c["ctx"].dict)
                vars[k] = v;
            res["out"] = env.render(c["t"].str, vars);
        }
        catch (Exception e)
            res["err"] = e.msg;
        writeln(res.toJson);
        stdout.flush();
    }
}
