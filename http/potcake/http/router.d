module potcake.http.router;

import pegged.peg : ParseTree;
import std.regex : Regex;
import vibe.core.log : logDebug;
import vibe.http.common : HTTPMethod;
import vibe.http.server : HTTPServerRequestHandler;
import vibe.http.status : HTTPStatus;

// TODO: Restrict the symbols exported from this module
// vibe.d components that are part of potcake.http.router's public API
public import vibe.http.server : HTTPServerRequest, HTTPServerRequestDelegate, HTTPServerResponse;

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
        // TODO: Handle std.conv.ConvOverflowException (1451412341412414)
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

private struct PathCaptureGroup
{
    string converterPathName;
    string pathParameter;
    string rawCaptureGroup;
}

private struct ParsedPath
{
    string regexPath;
    PathCaptureGroup[] pathCaptureGroups;
}

private alias HandlerDelegate = void delegate(HTTPServerRequest req, HTTPServerResponse res, PathCaptureGroup[] pathCaptureGroups) @safe;

alias MiddlewareDelegate = HTTPServerRequestDelegate delegate(HTTPServerRequestDelegate next) @safe;
alias MiddlewareFunction = HTTPServerRequestDelegate function(HTTPServerRequestDelegate next) @safe;
// TODO: tests for function middleware
// TODO: warn user when middlware not safe

private struct Route
{
    Regex!char pathRegex;
    HandlerDelegate handler;
    PathCaptureGroup[] pathCaptureGroups;
}

alias PathConverterDelegate = void delegate(string value, void* convertedValue) @safe;

struct PathConverterSpec
{
    string converterPathName;
    PathConverterDelegate converterDelegate;
    string converterRegex;
}

PathConverterSpec pathConverter(PathConverterObject)(string converterPathName, PathConverterObject pathConverterObject)
{
    import core.lifetime : emplace;
    import std.traits : isBasicType, isSomeString, moduleName, ReturnType;

    PathConverterDelegate pcd = (value, convertedValue) @safe {
        alias returnType = ReturnType!(pathConverterObject.toD);

        static if (!(isBasicType!(returnType) || isSomeString!(returnType)))
        {
            mixin("import " ~ moduleName!(returnType) ~ " : " ~ __traits(identifier, returnType) ~ ";");
        }

        // TODO: Is this safe? Are we trusting the user to use the right type for the destination buffer?
            (() @trusted => emplace(cast(mixin(returnType.stringof ~ "*"))convertedValue, pathConverterObject.toD(value)))();
    };

    return PathConverterSpec(converterPathName, pcd, pathConverterObject.regex);
}

PathConverterSpec[] defaultPathConverters = [
    pathConverter("int", IntConverter()),
    pathConverter("string", StringConverter()),
    pathConverter("slug", SlugConverter()),
    pathConverter("uuid", UUIDConverter()),
    pathConverter("path", URLPathConverter())
];

final class Router : HTTPServerRequestHandler
{
    private {
        // TODO: Optimize maps after they are built.
        PathConverterDelegate[string] converterMap;
        string[string] regexMap;
        Route[][HTTPMethod] routes;
        MiddlewareDelegate[] middleware;
        bool handlerNeedsUpdate = true;
        HTTPServerRequestDelegate handler;
    }

    this()
    {
        addPathConverters;
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

        HTTPServerRequestDelegate middleware(HTTPServerRequestDelegate next)
        {
            void middlewareDelegate(HTTPServerRequest req, HTTPServerResponse res)
            {
                // Do something before routing...
                next(req, res);
                // Do something after routing...
            }

            return &middlewareDelegate;
        }

        auto router = new Router;
        router.get("/hello/<name>/<int:age>/", &helloUser);
        router.addMiddleware(&middleware);
    }

    void addMiddleware(MiddlewareDelegate middleware) @safe
    {
        this.middleware ~= middleware;
        handlerNeedsUpdate = true;
    }

    void handleRequest(HTTPServerRequest req, HTTPServerResponse res) @safe
    {
        if (handlerNeedsUpdate)
        {
            updateHandler();
            handlerNeedsUpdate = false;
        }

        handler(req, res);
    }

    private void updateHandler() @safe
    {
        handler = &routeRequest;

        foreach_reverse (ref mw; middleware)
            handler = mw(handler);
    }

    private void routeRequest(HTTPServerRequest req, HTTPServerResponse res) @safe
    {
        import std.regex : matchAll;

        auto methodPresent = req.method in routes;

        if (methodPresent is null)
            return ;

        foreach (route; routes[req.method])
        {
            auto matches = matchAll(req.requestURI, route.pathRegex);

            if (matches.empty())
                continue ;

            foreach (i; 0 .. route.pathRegex.namedCaptures.length)
                req.params[route.pathRegex.namedCaptures[i]] = matches.captures[route.pathRegex.namedCaptures[i]];

            route.handler(req, res, route.pathCaptureGroups);
            break ;
        }
    }

    Router any(Handler)(string path, Handler handler) @safe
    if (isValidHandler!Handler)
    {
        import std.traits : EnumMembers;

        foreach (immutable method; [EnumMembers!HTTPMethod])
            match(path, method, handler);

        return this;
    }

    Router get(Handler)(string path, Handler handler) @safe
    if (isValidHandler!Handler)
    {
        return match(path, HTTPMethod.GET, handler);
    }

    Router match(Handler)(string path, HTTPMethod method, Handler handler) @safe
    if (isValidHandler!Handler)
    {
        import std.conv : to;
        import std.format : format;
        import std.range.primitives : back;
        import std.regex : regex;
        import std.traits : isBasicType, isSomeString, moduleName, Parameters, ReturnType;
        import std.typecons : tuple;

        auto parsedPath = parsePath(path, true);

        HandlerDelegate hd = (req, res, pathCaptureGroups) @safe {
            static if (Parameters!(handler).length == 2)
                handler(req, res);
            else
            {
                enum nonReqResParamCount = Parameters!(handler).length - 2;
                assert(parsedPath.pathCaptureGroups.length == nonReqResParamCount, format("Path (%s) handler's non-request/response parameter count (%s) does not match path parameter count (%s)", path, parsedPath.pathCaptureGroups.length, nonReqResParamCount));

                auto tailArgs = tuple!(Parameters!(handler)[2..$]);

                static foreach (i; 0 .. tailArgs.length)
                {
                    // TODO: Warn users that handler parameter and path converter return types need to be importable.
                    static if (!(isBasicType!(Parameters!(handler)[i + 2]) || isSomeString!(Parameters!(handler)[i + 2])))
                    {
                        mixin("import " ~ moduleName!(Parameters!(handler)[i + 2]) ~ " : " ~ __traits(identifier, Parameters!(handler)[i + 2]) ~ ";");
                    }

                    mixin(Parameters!(handler)[i + 2].stringof ~ " output" ~ to!string(i) ~ ";");
                        (() @trusted => converterMap[parsedPath.pathCaptureGroups[i].converterPathName](req.params.get(pathCaptureGroups[i].pathParameter), mixin("cast(void*) &output" ~ to!string(i))))();
                    mixin("tailArgs[i] = output" ~ to!string(i) ~ ";");
                }

                handler(req, res, tailArgs.expand);
            }
        };

        auto methodPresent = method in routes;

        if (methodPresent is null)
            routes[method] = [];

        routes[method] ~= Route(regex(parsedPath.regexPath, "s"), hd, parsedPath.pathCaptureGroups); // Single-line mode works hand-in-hand with $ to exclude trailing slashes when matching.

        logDebug("Added %s route: %s", to!string(method), routes[method].back);

        return this;
    }

    void addPathConverters(PathConverterSpec[] pathConverters = []) @safe
    {
        // This method must be called before adding handlers.
        import std.array : join;

        registerPathConverters([defaultPathConverters, pathConverters].join);
    }

    private void registerPathConverters(PathConverterSpec[] pathConverters) @safe
    {
        foreach (pathConverter; pathConverters)
        {
            converterMap[pathConverter.converterPathName] = pathConverter.converterDelegate;
            regexMap[pathConverter.converterPathName] = pathConverter.converterRegex;
        }
    }

    private ParsedPath parsePath(string path, bool isEndpoint=false) @safe
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

    private PathCaptureGroup[] getCaptureGroups(ParseTree p) @safe
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

    private string getRegexPath(string path, PathCaptureGroup[] captureGroups, bool isEndpoint=false) @safe
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

    private string getRegexCaptureGroup(string converterPathName, string pathParameter) @safe
    {
        // TODO: Test membership check
        auto converterRegistered = converterPathName in regexMap;
        if (!converterRegistered)
            throw new ImproperlyConfigured("No path converter registered for '" ~ converterPathName ~ "'.");

        return "(?P<" ~ pathParameter ~ ">" ~ regexMap[converterPathName] ~ ")";
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
