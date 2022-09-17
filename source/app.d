import pegged.peg : ParseTree;
import std.regex : Regex;
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

struct IntConverter
{
    enum regex = "[0-9]+";

    int toD(const string value) @safe
    {
        import std.conv : to;

        return to!int(value);
    }
}

struct StringConverter
{
    enum regex = "[^/]+";

    string toD(const string value) @safe
    {
        return value;
    }
}

struct SlugConverter
{
    enum regex = "[-a-zA-Z0-9_]+";

    string toD(const string value) @safe
    {
        return value;
    }
}

struct PathCaptureGroup
{
    string converterPathName;
    string pathParameter;
    string rawCaptureGroup;
}

struct ParsedPath
{
    string regexPath;
    PathCaptureGroup[] pathCaptureGroups;
}

alias HandlerDelegate = void delegate(HTTPServerRequest req, HTTPServerResponse res, PathCaptureGroup[] pathCaptureGroups) @safe;

struct Route
{
    Regex!char pathRegex;
    HandlerDelegate handler;
    PathCaptureGroup[] pathCaptureGroups;
}

struct BoundPathConverter
{
    string moduleName;
    string objectName;
    string converterPathName;
}

struct PathConverterRef
{
    void* ptr;
}

BoundPathConverter bindPathConverter(alias pathConverter, string converterPathName)()
{
    import std.traits : moduleName;

    return BoundPathConverter(moduleName!pathConverter, __traits(identifier, pathConverter), converterPathName);
}

template pathConverterMap(BoundPathConverters...)
{
    import std.algorithm.iteration : joiner;
    import std.array : array;
    import std.range : only;

    enum boundPathConverters = BoundPathConverters.only.joiner.array;

    PathConverterRef[string] pathConverterMap() @safe
    {
        mixin("PathConverterRef[string] converters;");

        static foreach (boundPathConverter; boundPathConverters)
        {
            mixin("import " ~ boundPathConverter.moduleName ~ " : " ~ boundPathConverter.objectName ~ ";");
            mixin("converters[\"" ~ boundPathConverter.converterPathName ~ "\"] = PathConverterRef(cast(void*) new " ~
            boundPathConverter.objectName ~ ");");
        }

        return mixin("converters");
    }
}

template TypedURLRouter(BoundPathConverters...)
{
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

    string getRegexPath(string path, PathCaptureGroup[] captureGroups, bool isEndpoint=false)()
    {
        // Django converts 'foo/<int:pk>' to '^foo\\/(?P<pk>[0-9]+)'
        import std.array : replace, replaceFirst;

        string result = ("^" ~ path[]).replace("/", r"\/");
        if (isEndpoint)
            result = result ~ "$";

        static foreach (group; captureGroups)
        {
            result = result.replaceFirst(group.rawCaptureGroup, getRegexCaptureGroup!(group.converterPathName, group.pathParameter));
        }

        return result;
    }

    string getRegexCaptureGroup(string converterPathName, string pathParameter)()
    {
        mixin("import " ~ getBoundPathConverter!(converterPathName).moduleName ~ " : " ~ getBoundPathConverter!(converterPathName).objectName ~ ";");
        return "(?P<" ~ pathParameter ~ ">" ~ mixin(getBoundPathConverter!(converterPathName).objectName ~ ".regex") ~ ")";
    }

    import std.algorithm.iteration : joiner;
    import std.array : array;
    import std.range : only;

    enum boundPathConverters = BoundPathConverters.only.joiner.array;

    BoundPathConverter getBoundPathConverter(string pathName)()
    {
        foreach (boundPathConverter; boundPathConverters)
        {
            if (boundPathConverter.converterPathName == pathName)
                return boundPathConverter;
        }

        throw new ImproperlyConfigured("No PathConverter found for converter path name '" ~ pathName ~ "'");
    }

    final class TypedURLRouter : HTTPServerRequestHandler
    {
        Route[][HTTPMethod] routes;
        PathConverterRef[string] pathConverters;

        this()
        {
            // TODO: Register only if not already registered
            pathConverters = pathConverterMap!boundPathConverters;
        }

        void handleRequest(HTTPServerRequest req, HTTPServerResponse res)
        {
            import std.regex : matchAll;

            foreach (route; routes[req.method])
            {
                auto matches = matchAll(req.path, route.pathRegex);

                if (matches.empty())
                    continue ;

                foreach (i; 0 .. route.pathRegex.namedCaptures.length)
                {
                    req.params[route.pathRegex.namedCaptures[i]] = matches.captures[route.pathRegex.namedCaptures[i]];
                }

                // TODO: We need to allow for more than one handler to check the request. Check for res.headerWritten.
                // Middleware is the answer. After route is matched we can then call all middleware.
                route.handler(req, res, route.pathCaptureGroups);
            }
        }

        TypedURLRouter get(string path, Handler)(Handler handler)
        {
            return setHandler!path(HTTPMethod.GET, handler);
        }

        TypedURLRouter setHandler(string path, Handler)(HTTPMethod method, Handler handler)
        {
            import std.regex : regex;
            import std.traits : Parameters;
            import std.typecons : tuple;

            enum parsedPath = parsePath!(path, true);

            HandlerDelegate handlerDelegate = (req, res, pathCaptureGroups) @trusted {
                auto tailArgs = tuple!(Parameters!(handler)[2..$]);

                static foreach (i; 0 .. tailArgs.length)
                {
                    tailArgs[i] = (cast(mixin(getBoundPathConverter!(parsedPath.pathCaptureGroups[i].converterPathName).objectName ~ "*")) pathConverters[pathCaptureGroups[i].converterPathName].ptr).toD(req.params.get(pathCaptureGroups[i].pathParameter));
                }

                handler(req, res, tailArgs.expand);
            };

            auto methodPresent = method in routes;
            if (methodPresent is null)
                routes[method] = [];

            routes[method] = routes[method] ~ Route(regex(parsedPath.regexPath, "s"), handlerDelegate, parsedPath.pathCaptureGroups); // Single-line mode works hand-in-hand with $ to exclude trailing slashes when matching.
            // TODO: Add debug logging of routes registered

            return this;
        }
    }
}

void helloUser(HTTPServerRequest req, HTTPServerResponse res, string name, int age) @safe
{
    import std.conv : to;

    res.contentType = "text/html; charset=UTF-8";
    res.writeBody(`
<!DOCTYPE html>
<html lang="en">
    <head></head>
    <body>
        Hello, ` ~ name ~ `. You are ` ~ to!string(age) ~ ` years old.
    </body>
</html>`,
    HTTPStatus.ok);
}

int main()
{
    enum allConverters = [
        bindPathConverter!(IntConverter, "int"),
        bindPathConverter!(StringConverter, "string"),
    ];

    auto router = new TypedURLRouter!allConverters;
    router.get!"/hello/<name>/<int:age>/"(&helloUser);

    auto settings = new HTTPServerSettings;
    settings.bindAddresses = ["127.0.0.1"];
    settings.port = 9000;

    auto listener = listenHTTP(settings, router);
    scope (exit)
    listener.stopListening();

    return runApplication();
}
