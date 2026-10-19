/// Jinja2 syntax tree.
module pgadmin.jinja.ast;

import pgadmin.core.value;

abstract class Node
{
    size_t line;
}

// ------------------------------------------------------------ expressions

abstract class Expr : Node
{
}

final class Const : Expr
{
    Value value;
    this(Value v) { value = v; }
}

final class NameExpr : Expr
{
    string name;
    this() {}
    this(string n) { name = n; }
}

final class ListExpr : Expr
{
    Expr[] items;
    bool tuple;
}

final class DictExpr : Expr
{
    Expr[] keys;
    Expr[] values;
}

final class GetAttr : Expr
{
    Expr obj;
    string attr;
}

final class GetItem : Expr
{
    Expr obj;
    Expr key;
}

final class SliceExpr : Expr
{
    Expr obj;
    Expr start, stop, step; // any may be null
}

final class CallExpr : Expr
{
    Expr fn;
    Expr[] args;
    string[] kwNames;
    Expr[] kwValues;
    Expr dynArgs;   // *args
    Expr dynKwargs; // **kwargs
}

final class FilterExpr : Expr
{
    Expr value; // null inside a {% filter %} block
    string name;
    Expr[] args;
    string[] kwNames;
    Expr[] kwValues;
}

final class TestExpr : Expr
{
    Expr value;
    string name;
    Expr[] args;
    bool negated;
}

final class BinOp : Expr
{
    string op; // + - * / // % ** ~ == != < <= > >= in notin and or
    Expr left, right;
}

final class UnaryOp : Expr
{
    string op; // not - +
    Expr operand;
}

final class CondExpr : Expr
{
    Expr test, then, else_; // else_ may be null
}

/// Comparison chain `a < b < c`.
final class CompareExpr : Expr
{
    Expr first;
    string[] ops;
    Expr[] rest;
}

// ------------------------------------------------------------ statements

abstract class Stmt : Node
{
}

final class Output : Stmt
{
    string text;   // data part (when expr is null)
    Expr expr;     // {{ expr }}
}

final class If : Stmt
{
    Expr[] tests;
    Stmt[][] bodies;
    Stmt[] else_;
}

final class For : Stmt
{
    Expr target;   // NameExpr or ListExpr (tuple unpacking)
    Expr iter;
    Expr filter;   // optional `if` condition
    Stmt[] body_;
    Stmt[] else_;
    bool recursive;
}

final class Assign : Stmt
{
    Expr target;   // NameExpr, ListExpr (unpacking) or GetAttr (namespace)
    Expr value;
}

final class AssignBlock : Stmt
{
    Expr target;
    Stmt[] body_;
    FilterExpr filter; // optional {% set x | filter %}
}

final class MacroDef : Stmt
{
    string name;
    string[] params;
    Expr[] defaults; // aligned to the end of params
    Stmt[] body_;
}

final class CallBlock : Stmt
{
    CallExpr call;
    string[] params;
    Expr[] defaults;
    Stmt[] body_;
}

final class Import : Stmt
{
    Expr template_;
    string alias_;
    bool withContext;
}

final class FromImport : Stmt
{
    Expr template_;
    string[] names;
    string[] aliases;
    bool withContext;
}

final class Include : Stmt
{
    Expr template_;
    bool ignoreMissing;
    bool withContext = true;
}

final class Extends : Stmt
{
    Expr template_;
}

final class Block : Stmt
{
    string name;
    Stmt[] body_;
    bool scoped;
}

final class With : Stmt
{
    Expr[] targets;
    Expr[] values;
    Stmt[] body_;
}

final class FilterBlock : Stmt
{
    FilterExpr filter;
    Stmt[] body_;
}

final class ExprStmt : Stmt // {% do expr %}
{
    Expr expr;
}

final class AutoEscape : Stmt
{
    Expr enabled;
    Stmt[] body_;
}

/// A parsed template.
final class TemplateAst
{
    string name;
    Stmt[] body_;
    Block[string] blocks;
    bool hasExtends;
}
