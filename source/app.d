import pegged.peg : ParseTree;
import std.regex : Regex;
import std.stdio : writefln, writeln;
import vibe.core.core : runApplication;
import vibe.http.common : HTTPMethod;
import vibe.http.router : URLRouter;
import vibe.http.server : HTTPServerRequest, HTTPServerRequestHandler, HTTPServerResponse, HTTPServerSettings, listenHTTP;
import vibe.http.status : HTTPStatus;

class ImproperlyConfigured : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
    }
}

//class PathConverter
//{
//    string regex() @safe
//    {
//        throw new ImproperlyConfigured("Subclass PathConverter before use");
//    }
//
//    string toD(string value) @safe
//    {
//        throw new ImproperlyConfigured("Subclass PathConverter before use");
//    }
//
//    // https://stackoverflow.com/a/31446463
//    void sayHello(this converter)()
//    {
//        writeln("Hello from " ~ typeof(cast(converter) this).stringof ~ " (" ~ (cast(converter) this).regex ~ ")!");
//    }
//}

interface PathConverter
{
    string regex() @safe;
    T toD(T)(const string value) @safe;
}

class NumberConverter(T) : PathConverter
{
    string regex() @safe
    {
        return "[0-9]+";
    }

    T toD(T)(const string value) @safe
    {
        import std.conv : to;

        return to!(T)(value);
    }
}

alias IntConverter = NumberConverter!int;

class StringConverterTemplate(T) : PathConverter
{
    string regex() @safe
    {
        return "[^/]+";
    }

    T toD(T)(const string value) @safe
    {
        return value;
    }
}

alias StringConverter = StringConverterTemplate!string;

class SlugConverter : StringConverter
{
    override string regex() @safe
    {
        return "[-a-zA-Z0-9_]+";
    }
}

// Error: variable <variable name> : Unable to initialize enum with class or pointer to struct. Use static const variable instead.
// Conflicts with:
// 	https://dlang.org/spec/expression.html#associative_array_literals
// 	An AssocArrayLiteral cannot be used to statically initialize anything.

PathConverter[string] allConverters;

void registerPathConverter(PathConverter pathConverter, string converterPathName)
{
    allConverters[converterPathName] = pathConverter;
}

PathConverter getPathConverter(string converterPathName) @safe
{
    auto converterRegistered = converterPathName in allConverters;
    if (converterRegistered is null)
        throw new ImproperlyConfigured("No PathConverter found for converter path name '" ~ converterPathName ~ "'");

    return allConverters[converterPathName];
}

struct PathCaptureGroup
{
    string converterPathName;
    string pathParameter;
    string rawCaptureGroup;
}

string getRegexPath(string path, PathCaptureGroup[] captureGroups, bool isEndpoint=false)
{
    // Django converts 'foo/<int:pk>' to '^foo\\/(?P<pk>[0-9]+)'
    import std.array : replace, replaceFirst;

    string result = ("^" ~ path[]).replace("/", r"\/");
    if (isEndpoint)
        result = result ~ "$";

    foreach (group; captureGroups)
    {
        result = result.replaceFirst(group.rawCaptureGroup, getRegexCaptureGroup(group.converterPathName, group.pathParameter));
    }

    return result;
}

struct ParsedPath
{
    string regexPath;
    PathCaptureGroup[] pathCaptureGroups;
}

string getRegexCaptureGroup(string converterPathName, string pathParameter)
{
    return "(?P<" ~ pathParameter ~ ">" ~ getPathConverter(converterPathName).regex ~ ")";
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
            // No path converter specified so we default to 'string'
                return [PathCaptureGroup("string", p[0].matches[0], p.matches.join)];

            else return [PathCaptureGroup(p[0].matches[0], p[1].matches[0], p.matches.join)];

            default:
            assert(false);
        }
    }

    return walkForGroups(p);
}

ParsedPath parsePath(string path, bool isEndpoint=false)
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

    auto peggedPath = Path(path);
    auto pathCaptureGroups = getCaptureGroups(peggedPath);

    return ParsedPath(getRegexPath(path, pathCaptureGroups, isEndpoint), pathCaptureGroups);
}

unittest
{
    import std.range : zip;

    auto inputs = [
        "model/<string:model>/make/<int:make>",
        "<int:pk>",
        "no/converter/path",
        "<int:pk>/",
        "",
        "/<int:pk>",
        "<pk>"
    ];

    auto expectedResults = [
        ParsedPath(r"^model\/(?P<model>[^/]+)\/make\/(?P<make>[0-9]+)$", [PathCaptureGroup("string", "model", "<string:model>"), PathCaptureGroup("int", "make", "<int:make>")]),
        ParsedPath(r"^(?P<pk>[0-9]+)$", [PathCaptureGroup("int", "pk", "<int:pk>")]),
        ParsedPath(r"^no\/converter\/path$", []),
        ParsedPath(r"^(?P<pk>[0-9]+)\/$", [PathCaptureGroup("int", "pk", "<int:pk>")]),
        ParsedPath(r"^$", []),
        ParsedPath(r"^\/(?P<pk>[0-9]+)$", [PathCaptureGroup("int", "pk", "<int:pk>")]),
        ParsedPath(r"^(?P<pk>[^/]+)$", [PathCaptureGroup("string", "pk", "<pk>")]),
    ];

    registerPathConverter(new StringConverter(), "string");
    registerPathConverter(new IntConverter(), "int");

    foreach (input, expectedResult; zip(inputs, expectedResults))
        assert(parsePath(input, true) == expectedResult);
}

void helloWorld(HTTPServerRequest req, HTTPServerResponse res, string name) @safe
{
    res.contentType = "text/html; charset=UTF-8";
    res.writeBody(`<!DOCTYPE html><html lang="en"><head></head><body>Hello, ` ~ name ~ `World!</body></html>`, HTTPStatus.ok);
}

alias HandlerDelegate = void delegate(HTTPServerRequest req, HTTPServerResponse res, PathCaptureGroup[] pathCaptureGroups) @safe;

void testFunc(HandlerDelegate myD)
{
    //
}

struct Route
{
    Regex!char pathRegex;
    HandlerDelegate handler;
    PathCaptureGroup[] pathCaptureGroups;
}

final class TypedURLRouter : HTTPServerRequestHandler
{
    Route[][HTTPMethod] routes;

    private
    {
        string _prefix;
    }
    
    this (string prefix = null)
    {
        _prefix = prefix;
        // TODO: register only if not already registered
        registerPathConverter(new StringConverter(), "string");
        registerPathConverter(new IntConverter(), "int");
    }

    void handleRequest(HTTPServerRequest req, HTTPServerResponse res)
    {
        import std.regex : matchAll;

        foreach (route; routes[req.method])
        {
            auto matches = matchAll(req.path, route.pathRegex);

            if (matches.empty())
                continue;

            foreach (i; 0 .. route.pathRegex.namedCaptures.length)
            {
                req.params[route.pathRegex.namedCaptures[i]] = matches.captures[route.pathRegex.namedCaptures[i]];
            }

            // TODO: we need to allow for more than one handler to check the request. check for res.headerWritten.
            // middleware is the answer. after route is matched we can then call all middleware.
            route.handler(req, res, route.pathCaptureGroups);
        }
    }

    TypedURLRouter setHandler(Handler)(HTTPMethod method, string path, Handler handler)
    {
        import std.regex : regex;
        import std.traits : Parameters;
        import std.typecons : tuple;

        HandlerDelegate handlerDelegate = (req, res, pathCaptureGroups) @safe {
            auto tailArgs = tuple!(Parameters!(handler)[2..$]);

            static foreach (i; 0 .. tailArgs.length)
            {
                tailArgs[i] = getPathConverter(pathCaptureGroups[i].converterPathName).toD!(Parameters!(handler)[i + 2])(req.params[pathCaptureGroups[i].pathParameter]);
                           //`allConverters[pathCaptureGroups[0].converterPathName].toD(req.params.get(pathCaptureGroups[0].pathParameter, delegate const(string)() pure nothrow @nogc @safe => null))`
            }

            handler(req, res, tailArgs.expand);
        };

        auto methodPresent = method in routes;
        if (methodPresent is null)
            routes[method] = [];

        auto parsedPath = parsePath(path, true);
        routes[method] = routes[method] ~ Route(regex(parsedPath.regexPath), handlerDelegate, parsedPath.pathCaptureGroups);

        return this;
    }

    TypedURLRouter get(Handler)(string path, Handler handler)
    {
        return setHandler(HTTPMethod.GET, path, handler);
    }
}

int main()
{
    //import std.regex : matchAll, regex;
    //
    //registerPathConverter(new StringConverter(), "string");
    //registerPathConverter(new IntConverter(), "int");
    //auto parsedPath = parsePath("model/porsche/make/911", true); //model/<string:model>/make/<int:make>
    //auto r = regex(parsedPath.regexPath, "s"); // Single-line mode works hand-in-hand with $ to exclude trailing slashes when matching.
    //auto c = matchAll("model/porsche/make/911", r).captures;
    //writefln("%s", r.namedCaptures.length);
    //writefln("%s", c);
    //writefln("%s", r.empty);
    //writeln(c["model"]);
    //writeln(c["make"]);


    auto router = new TypedURLRouter;
    router.get("/hello/<string:name>/", &helloWorld);

    auto settings = new HTTPServerSettings;
    settings.bindAddresses = ["127.0.0.1"];
    settings.port = 9000;

    auto listener = listenHTTP(settings, router);
    scope (exit)
    listener.stopListening();

    return runApplication();


    //import std.traits : Parameters;
    //import std.typecons : tuple;
    //
    //void tester(string name, int age, string location)
    //{
    //    writefln("%s %s %s", name, age, location);
    //}
    //
    //auto tailArgs = tuple!(Parameters!(tester)[1..$]);
    //writeln(tailArgs.length);
    //static foreach (i; 0 .. tailArgs.length)
    //{
    //    static if (i == 0)
    //    {
    //        tailArgs[i] = 34;
    //    }
    //    else
    //    {
    //        tailArgs[i] = "Toronto";
    //    }
    //}
    //
    //tester("Kyle", tailArgs.expand);


    //import std.algorithm.iteration : joiner, permutations;
    //import std.array : array;
    //import std.conv : to;
    //import std.datetime.stopwatch : benchmark;
    //import std.range : zip;
    //import std.regex : matchAll, regex, Regex;
    //
    //string[] paths = [];
    //
    //foreach (perm1, perm2; zip(["model"].joiner.array.permutations, ["makes"].joiner.array.permutations))
    //    paths = paths ~ (to!string(perm1) ~ "/<string:model>/" ~ to!string(perm2) ~ "/<int:make>");
    //
    //registerPathConverter(new StringConverter(), "string");
    //registerPathConverter(new IntConverter(), "int");
    //registerPathConverter(new SlugConverter(), "slug");
    //
    //ParsedPath[] parsedPaths = [];
    //
    //foreach (path; paths)
    //    parsedPaths = parsedPaths ~ parsePath(path, true);
    //
    //Regex!char[] rgxs = [];
    //
    //foreach (parsedPath; parsedPaths)
    //    rgxs = rgxs ~ regex(parsedPath.regexPath, "s");
    //
    //void benchmarkFunc()
    //{
    //    string testPath = r"dolem/kyle/kasem/88";
    //    int routesTried = 0;
    //    bool matchFound = false;
    //
    //    foreach (rgx; rgxs)
    //    {
    //        auto routeMatch = matchAll(testPath, rgx).captures;
    //        routesTried += 1;
    //
    //        if (routeMatch.length)
    //        {
    //            matchFound = true;
    //            break;
    //        }
    //    }
    //
    //    assert(routesTried == 120);
    //    assert(matchFound == true);
    //}
    //
    //int runs = 100;
    //auto result = benchmark!(benchmarkFunc)(runs);
    //auto average = result[0].total!"msecs" / to!float(runs);
    //writefln("Average msecs / run: %s", average);
    //
    //return 0;
}
