module driver_probe;
import std.stdio;
import std.file : readText;
import pgadmin.core.value;
import pgadmin.db.pgconn;

void main(string[] args)
{
    auto c = PgConnection.connect(args[1]);
    foreach (arr; [false, true])
    {
        c.arrayToString = arr;
        PgResult a, b;
        c.execute(readText(args[2]), a, b);
        writeln(arr ? "array_to_string" : "default");
        foreach (i, col; a.columns)
            writeln(col.name, " ", a.rows[0][i].toJson);
    }
}
