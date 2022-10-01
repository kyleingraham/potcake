module typed_router.router;

import pegged.peg : ParseTree;
import std.regex : Regex;
import vibe.core.core : runApplication;
import vibe.core.log : logDebug, LogLevel, setLogLevel;
import vibe.http.common : HTTPMethod;
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

mixin template StringToD()
{
    string toD(const string value) @safe
    {
        return value;
    }
}

struct StringConverter
{
    enum regex = "[^/]+";

    mixin StringToD;
}

struct SlugConverter
{
    enum regex = "[-a-zA-Z0-9_]+";

    mixin StringToD;
}

struct UUIDConverter
{
    import std.uuid : UUID;

    enum regex = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";

    UUID toD(const string value) @safe
    {
        return UUID(value);
    }
}

struct URLPathConverter
{
    enum regex = ".+";

    mixin StringToD;
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

PathConverterRef[string] pathConverterMap(BoundPathConverter[] boundPathConverters)() @trusted
{
    mixin("PathConverterRef[string] converters;");

    static foreach_reverse (boundPathConverter; boundPathConverters)
    {
        mixin("import " ~ boundPathConverter.moduleName ~ " : " ~ boundPathConverter.objectName ~ ";");
        mixin("converters[\"" ~ boundPathConverter.converterPathName ~ "\"] = PathConverterRef(cast(void*) new " ~ boundPathConverter.objectName ~ ");");
    }

    return mixin("converters");
}

template TypedURLRouter(BoundPathConverter[] userPathConverters = [])
{
    import std.array : join;

    enum boundPathConverters = [
        userPathConverters, [
            bindPathConverter!(IntConverter, "int"),
            bindPathConverter!(StringConverter, "string"),
            bindPathConverter!(SlugConverter, "slug"),
            bindPathConverter!(UUIDConverter, "uuid"),
            bindPathConverter!(URLPathConverter, "path"),
        ]
    ].join;

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
        private {
            Route[][HTTPMethod] routes;
            PathConverterRef[string] pathConverters;
        }

        this()
        {
            pathConverters = pathConverterMap!boundPathConverters;
        }

        unittest
        {
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

            auto router = new TypedURLRouter!();
            router.get!"/hello/<name>/<int:age>/"(&helloUser);
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

                route.handler(req, res, route.pathCaptureGroups);
                break ;
            }
        }

        TypedURLRouter get(string path, Handler)(Handler handler)
        if (isValidHandler!Handler)
        {
            return match!path(HTTPMethod.GET, handler);
        }

        TypedURLRouter match(string path, Handler)(HTTPMethod method, Handler handler)
        if (isValidHandler!Handler)
        {
            import std.conv : to;
            import std.format : format;
            import std.range.primitives : back;
            import std.regex : regex;
            import std.traits : Parameters;
            import std.typecons : tuple;

            enum parsedPath = parsePath!(path, true);

            HandlerDelegate handlerDelegate = (req, res, pathCaptureGroups) @trusted {
                static if (Parameters!(handler).length == 2)
                    handler(req, res);
                else
                {
                    enum nonReqResParamCount = Parameters!(handler).length - 2;

                    static assert(parsedPath.pathCaptureGroups.length == nonReqResParamCount, format("Path (%s) handler's non-request/response parameter count (%s) does not match path parameter count (%s)", path, parsedPath.pathCaptureGroups.length, nonReqResParamCount));

                    auto tailArgs = tuple!(Parameters!(handler)[2..$]);

                    static foreach (i; 0 .. tailArgs.length)
                    {
                        mixin("import " ~ getBoundPathConverter!(parsedPath.pathCaptureGroups[i].converterPathName).moduleName ~ " : " ~ getBoundPathConverter!(parsedPath.pathCaptureGroups[i].converterPathName).objectName ~ ";");

                        tailArgs[i] = (cast(mixin(getBoundPathConverter!(parsedPath.pathCaptureGroups[i].converterPathName).objectName ~ "*")) pathConverters[pathCaptureGroups[i].converterPathName].ptr).toD(req.params.get(pathCaptureGroups[i].pathParameter));
                    }

                    handler(req, res, tailArgs.expand);
                }
            };

            auto methodPresent = method in routes;

            if (methodPresent is null)
                routes[method] = [];

            routes[method] ~= Route(regex(parsedPath.regexPath, "s"), handlerDelegate, parsedPath.pathCaptureGroups); // Single-line mode works hand-in-hand with $ to exclude trailing slashes when matching.

            logDebug("Added %s route: %s", to!string(method), routes[method].back);

            return this;
        }
    }
}

template isValidHandler(Handler)
{
    import std.traits : Parameters, ReturnType;

    static if (
        2 <= Parameters!(Handler).length &&
        is(Parameters!(Handler)[0] : HTTPServerRequest) &&
        is(Parameters!(Handler)[1] : HTTPServerResponse) &&
        is(ReturnType!Handler : void)
    )
    {
        enum isValidHandler = true;
    }
    else
    {
        enum isValidHandler = false;
    }
}
