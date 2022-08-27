import pegged.peg : ParseTree;
import std.stdio : writeln;

class PathConverter
{
    // https://stackoverflow.com/a/31446463
    void sayHello(this converter)()
    {
        writeln("Hello from " ~ typeof(cast(converter) this).stringof ~ " (" ~ (cast(converter) this).regex ~ ")!");
    }
}

class IntConverter : PathConverter
{
    enum regex = "[0-9]+";

    int toD(string value)
    {
        import std.conv : to;

        return to!int(value);
    }
}

class StringConverter : PathConverter
{
    enum regex = "[^/]+";

    string toD(string value)
    {
        return value;
    }
}

class SlugConverter : StringConverter
{
    enum regex =  "[-a-zA-Z0-9_]+";
}

// Error: variable <variable name> : Unable to initialize enum with class or pointer to struct. Use static const variable instead.
// Conflicts with:
// 	https://dlang.org/spec/expression.html#associative_array_literals
// 	An AssocArrayLiteral cannot be used to statically initialize anything.

struct BoundPathConverter
{
    string moduleName;
    string className;
    string converterPathName;
}

BoundPathConverter bindPathConverter(alias pathConverter, string converterPathName)()
{
    import std.traits : moduleName;

    return BoundPathConverter(moduleName!pathConverter, __traits(identifier, pathConverter), converterPathName);
}

enum frameworkConverters = [bindPathConverter!(SlugConverter, "slug")];

enum myConverters = [
    bindPathConverter!(StringConverter, "string"), bindPathConverter!(IntConverter, "int")
];

// The framework should be the only one to call this.
template registerConverters(BoundPathConverters...)
{
    import std.algorithm.iteration : joiner;
    import std.array : array;
    import std.range : only;

    enum registerConverters = BoundPathConverters.only.joiner.array;
}

enum allConverters = registerConverters!(myConverters, frameworkConverters);

class ImproperlyConfigured : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

// TODO: Can we memoize this?
BoundPathConverter getPathConverter(string pathName)()
{
    foreach (boundPathConverter; allConverters)
    {
        if (boundPathConverter.converterPathName == pathName)
            return boundPathConverter;
    }

    throw new ImproperlyConfigured("No PathConverter found for converter path name '" ~ pathName ~ "'");
}

template joinParameters(string[] parameters) if (parameters.length)
{
    import std.array : join;

    enum joinParameters = parameters.join(", ");
}

struct PathCaptureGroup
{
    string converterPathName;
    string pathParameter;
    string rawCaptureGroup;
}

template getRegexPath(string path, PathCaptureGroup[] captureGroups, bool isEndpoint=false)
{
    // Django converts 'foo/<int:pk>' to '^foo\\/(?P<pk>[0-9]+)'
    import std.array : replace, replaceFirst;

    string getRegexPath()
    {
        string result = ("^" ~ path[]).replace("/", r"\/");
        if (isEndpoint)
            result = result ~ "$";

        static foreach (group; captureGroups)
        {
            result = result.replaceFirst(group.rawCaptureGroup, getRegexCaptureGroup!(group.converterPathName, group.pathParameter));
        }

        return result;
    }

}

template callDummy(PathCaptureGroup[] captureGroups)
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.conv : to;
    import std.range : iota, zip;

    enum paramNums = captureGroups.length.iota.array;

    void callDummy()
    {
        static foreach (group, paramNum; zip(captureGroups, paramNums))
        {
            mixin("import " ~ getPathConverter!(group.converterPathName).moduleName ~ " : " ~ getPathConverter!(group.converterPathName).className ~ ";");
            mixin("auto " ~ group.pathParameter ~ to!string(paramNum) ~ " = new " ~ getPathConverter!(group.converterPathName).className ~ "();");
            mixin(group.pathParameter ~ to!string(paramNum) ~ ".sayHello;");
        }

        static if (0 < captureGroups.length)
            pragma(msg,joinParameters!(zip(captureGroups, paramNums).map!(a => a[0].pathParameter ~ to!string(a[1])).array));
    }
}

struct ParsedPath
{
    string regexPath;
    PathCaptureGroup[] pathCaptureGroups;
}

string getRegexCaptureGroup(string converterPathName, string pathParameter)()
{
    mixin("import " ~ getPathConverter!(converterPathName).moduleName ~ " : " ~ getPathConverter!(converterPathName).className ~ ";");

    return "(?P<" ~ pathParameter ~ ">" ~ mixin(getPathConverter!(converterPathName).className ~ ".regex") ~ ")";
}

PathCaptureGroup[] getCaptureGroups(ParseTree p)
{
    PathCaptureGroup[] walkForGroups(ParseTree p)
    {
        import std.array : join;

        switch (p.name)
        {
            case "Path":
            return walkForGroups(p.children[0]);

            case "Path.PathCaptureGroups":
            PathCaptureGroup[] result = [];
            foreach (child; p.children)
                result ~= walkForGroups(child);

            return result;

            case "Path.PathCaptureGroup":
            if (p.children.length == 1)
                return [PathCaptureGroup("string", p[0].matches[0], p.matches.join)];

            else return [PathCaptureGroup(p[0].matches[0], p[1].matches[0], p.matches.join)];

            default:
            assert(false);
        }
    }

    return walkForGroups(p);
}

ParsedPath parsePath(string path, bool isEndpoint=false)()
{
    import pegged.grammar;

    // Regex can be compiled at compile-time but can't be used. pegged to the rescue.
    mixin(grammar(`
    Path:
        PathCaptureGroups   <- ((;UrlChars PathCaptureGroup?) / (PathCaptureGroup ;UrlChars) / (PathCaptureGroup ;endOfInput))*
        UrlChars            <- [A-Za-z0-9-._~/]+
        PathCaptureGroup    <- '<' (ConverterPathName ':')? PathParameter '>'
        ConverterPathName   <- identifier
        PathParameter       <- identifier
    `));

    enum peggedPath = Path(path);
    enum pathCaptureGroups = getCaptureGroups(peggedPath);

    return ParsedPath(getRegexPath!(path, pathCaptureGroups, isEndpoint), pathCaptureGroups);
}

unittest
{
    import std.range : zip;

    enum inputs = [
        "model/<string:model>/make/<int:make>",
        "<int:pk>",
        "no/converter/path",
        "<int:pk>/",
        "",
        "/<int:pk>",
        "<pk>"
    ];

    enum expectedResults = [
        ParsedPath(r"^model\/(?P<model>[^/]+)\/make\/(?P<make>[0-9]+)$", [PathCaptureGroup("string", "model", "<string:model>"), PathCaptureGroup("int", "make", "<int:make>")]),
        ParsedPath(r"^(?P<pk>[0-9]+)$", [PathCaptureGroup("int", "pk", "<int:pk>")]),
        ParsedPath(r"^no\/converter\/path$", []),
        ParsedPath(r"^(?P<pk>[0-9]+)\/$", [PathCaptureGroup("int", "pk", "<int:pk>")]),
        ParsedPath(r"^$", []),
        ParsedPath(r"^\/(?P<pk>[0-9]+)$", [PathCaptureGroup("int", "pk", "<int:pk>")]),
        ParsedPath(r"^(?P<pk>[^/]+)$", [PathCaptureGroup("string", "pk", "<pk>")]),
    ];

    static foreach (input, expectedResult; zip(inputs, expectedResults))
    static assert(parsePath!(input, true) == expectedResult);
}

void main()
{
    import std.regex : ctRegex, matchAll, regex;

    writeln(allConverters);

    enum parsedPath = parsePath!("model/<string:model>/make/<int:make>", true);
    callDummy!(parsedPath.pathCaptureGroups);

    auto r = ctRegex!(parsedPath.regexPath, "s"); // Single-line mode works hand-in-hand with $ to exclude trailing slashes when matching.
    auto c = matchAll("model/porsche/make/911", r).captures;
    writeln(c["model"]);
    writeln(c["make"]);
}
