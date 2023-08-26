module potcake.http.router;

import pegged.peg : ParseTree;
import std.regex : Regex;
import vibe.core.log : logTrace;
import vibe.http.common : HTTPMethod;
import vibe.http.server : HTTPServerRequestHandler;
import vibe.http.status : HTTPStatus;
import std.variant : Variant;

// vibe.d components that are part of potcake.http.router's public API
public import vibe.http.server : HTTPServerRequest, HTTPServerRequestDelegate, HTTPServerResponse;

class ImproperlyConfigured : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
    }
}

class NoReverseMatch : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
    }
}

class ConversionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
    }
}

@safe struct IntConverter
{
    import std.conv : ConvOverflowException, to;

    enum regex = "[0-9]+";

    int toD(const string value)
    {
        try {
            return to!int(value);
        } catch (ConvOverflowException e) {
            throw new ConversionException(e.msg);
        }
    }

    string toPath(int value)
    {
        return to!string(value);
    }
}

@safe mixin template StringConverterMixin()
{
    string toD(const string value)
    {
        return value;
    }

    string toPath(string value)
    {
        return value;
    }
}

@safe struct StringConverter
{
    enum regex = "[^/]+";

    mixin StringConverterMixin;
}

@safe struct SlugConverter
{
    enum regex = "[-a-zA-Z0-9_]+";

    mixin StringConverterMixin;
}

@safe struct UUIDConverter
{
    import std.uuid : UUID;

    enum regex = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";

    UUID toD(string value)
    {
        return UUID(value);
    }

    string toPath(UUID value)
    {
        return value.toString();
    }
}

@safe struct URLPathConverter
{
    enum regex = ".+";

    mixin StringConverterMixin;
}

package struct PathCaptureGroup
{
    string converterPathName;
    string pathParameter;
    string rawCaptureGroup;
}

private struct ParsedPath
{
    string path;
    string regexPath;
    PathCaptureGroup[] pathCaptureGroups;
}

private alias HandlerDelegate = void delegate(HTTPServerRequest req, HTTPServerResponse res, PathCaptureGroup[] pathCaptureGroups) @safe;

alias MiddlewareDelegate = HTTPServerRequestDelegate delegate(HTTPServerRequestDelegate next) @safe;
alias MiddlewareFunction = HTTPServerRequestDelegate function(HTTPServerRequestDelegate next) @safe;

private struct Route
{
    Regex!char pathRegex;
    HandlerDelegate handler;
    PathCaptureGroup[] pathCaptureGroups;
}

private alias ToDDelegate = Variant delegate(string value) @safe;
private alias ToPathDelegate = string delegate(Variant value) @safe;

struct PathConverterSpec
{
    string converterPathName;
    string regex;
    ToDDelegate toDDelegate;
    ToPathDelegate toPathDelegate;
}

PathConverterSpec pathConverter(PathConverterObject)(string converterPathName, PathConverterObject pathConverterObject) @safe
{
    ToDDelegate tdd = (value) @trusted {
        return Variant(pathConverterObject.toD(value));
    };

    ToPathDelegate tpd = (value) @trusted {
        import std.traits : Parameters;

        alias paramType = Parameters!(pathConverterObject.toPath)[0];
        return pathConverterObject.toPath(value.get!paramType);
    };

    return PathConverterSpec(converterPathName, pathConverterObject.regex, tdd, tpd);
}

PathConverterSpec[] defaultPathConverters = [
    pathConverter("int", IntConverter()),
    pathConverter("string", StringConverter()),
    pathConverter("slug", SlugConverter()),
    pathConverter("uuid", UUIDConverter()),
    pathConverter("path", URLPathConverter())
];

alias ConverterPathName = string;
alias PathConverterRegex = string;
alias RouteName = string;

@safe final class Router : HTTPServerRequestHandler
{
    private {
        PathConverterSpec[ConverterPathName] converterMap;
        ParsedPath[RouteName] pathMap;
        Route[][HTTPMethod] routes;
        MiddlewareDelegate[] middleware;
        bool handlerNeedsUpdate = true;
        HTTPServerRequestDelegate handler;
    }

    this()
    {
        addPathConverters();
        middleware = [&routingMiddleware, &handlerMiddleware];
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

    void addMiddleware(MiddlewareDelegate middleware)
    {
        this.middleware ~= middleware;
        handlerNeedsUpdate = true;
    }

    /**
       Clear all middleware from this router's middleware chain.

       Call before adding your own middleware if middlware must run pre-routing or pre-handling.
     */
    void clearMiddleware()
    {
        this.middleware = [];
        handlerNeedsUpdate = true;
    }

    void handleRequest(HTTPServerRequest req, HTTPServerResponse res)
    {
        if (handlerNeedsUpdate)
            updateHandler();

        handler(req, res);
    }

    private void updateHandler()
    {
        import vibe.core.log : logDebug;

        void noopHandler(HTTPServerRequest req, HTTPServerResponse res)
        {
            logDebug("noopHandler called");
        }

        handler = &noopHandler;

        logDebug("Middleware count: %s", middleware.length);

        foreach_reverse (ref mw; middleware)
            handler = mw(handler);

        rehashMaps();
        handlerNeedsUpdate = false;
    }

    private void rehashMaps() @trusted
    {
        converterMap = converterMap.rehash();
        pathMap = pathMap.rehash();
        routes = routes.rehash();
    }

    private const(HTTPServerRequestDelegate) getHandler(HTTPServerRequest req, HTTPServerResponse res)
    {
        import std.regex : matchAll;

        auto methodPresent = req.method in routes;

        if (methodPresent is null)
            return null;

        foreach (route; routes[req.method])
        {
            auto matches = matchAll(req.requestURI, route.pathRegex);

            if (matches.empty())
                continue;

            foreach (i; 0 .. route.pathRegex.namedCaptures.length)
                req.params[route.pathRegex.namedCaptures[i]] = matches.captures[route.pathRegex.namedCaptures[i]];

            return (req, res) {
                route.handler(req, res, route.pathCaptureGroups);
            };
        }

        return null;
    }

    private void routeRequest(HTTPServerRequest req, HTTPServerResponse res)
    {
        if (auto handler = getHandler(req, res))
            handler(req, res);
    }

    /**
       Adds the ability to route a request to a handler. Must be used with and called before useHandlerMiddleware.

       This middleware selects a handler based on the URL path requested but does not call the handler.
       useHandlerMiddleware covers that responsibility. Routing and handling are split to allow adding
       pre-routing and pre-handling middleware.
     */
    Router useRoutingMiddleware()
    {
        addMiddleware(&routingMiddleware);
        return this;
    }

    /**
       Calls a selected handler after routing. Must be used with and called after useRoutingMiddleware.

       This middleware calls the handler selected for a given handler by useRoutingMiddleware.
       Routing and handling are split to allow adding pre-routing and pre-handling middleware.
     */
    Router useHandlerMiddleware()
    {
        addMiddleware(&handlerMiddleware);
        return this;
    }

    private HTTPServerRequestDelegate routingMiddleware(HTTPServerRequestDelegate next) @safe
    {
        import vibe.core.log : logDebug;

        logDebug("routingMiddleware added");

        void middlewareDelegate(HTTPServerRequest req, HTTPServerResponse res)
        {
            logDebug("routingMiddleware, req.requestURI: %s", req.requestURI);

            if (auto handler = getHandler(req, res))
            {
                logDebug("routingMiddleware, handler set");
                    (() @trusted => req.context["handler"] = handler)();
                next(req, res);
            }

            logDebug("routingMiddleware ended");
        }

        return &middlewareDelegate;
    }

    private HTTPServerRequestDelegate handlerMiddleware(HTTPServerRequestDelegate next)
    {
        import vibe.core.log : logDebug;

        logDebug("handlerMiddleware added");

        void middlewareDelegate(HTTPServerRequest req, HTTPServerResponse res)
        {
            logDebug("handlerMiddleware started");
            auto handler = (() @trusted => req.context["handler"].get!(const(HTTPServerRequestDelegate)))();
            handler(req, res);
            logDebug("handlerMiddleware, handler called");
            next(req, res);
            logDebug("handlerMiddleware ended");
        }

        return &middlewareDelegate;
    }

    Router any(Handler)(string path, Handler handler, string routeName=null)
    if (isValidHandler!Handler)
    {
        import std.traits : EnumMembers;

        foreach (immutable method; [EnumMembers!HTTPMethod])
            match(path, method, handler, routeName);

        return this;
    }

    Router get(Handler)(string path, Handler handler, string routeName=null)
    if (isValidHandler!Handler)
    {
        return match(path, HTTPMethod.GET, handler, routeName);
    }

    Router match(Handler)(string path, HTTPMethod method, Handler handler, string routeName=null)
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
                assert(
                    parsedPath.pathCaptureGroups.length == nonReqResParamCount,
                    format(
                        "Path's (%s) handler's non-request/response parameter count (%s) does not match the path's parameter count (%s). ",
                        path,
                        nonReqResParamCount,
                        parsedPath.pathCaptureGroups.length,
                    )
                );

                auto tailArgs = tuple!(Parameters!(handler)[2..$]);

                static foreach (i; 0 .. tailArgs.length)
                {
                    tailArgs[i] = (() @trusted =>
                        converterMap[parsedPath.pathCaptureGroups[i].converterPathName]     // load path converter
                        .toDDelegate(req.params.get(pathCaptureGroups[i].pathParameter))    // convert request param
                        .get!(Parameters!(handler)[i + 2])                                  // convert Variant to type
                    )();
                }

                handler(req, res, tailArgs.expand);
            }
        };

        auto methodPresent = method in routes;

        if (methodPresent is null)
            routes[method] = [];

        routes[method] ~= Route(regex(parsedPath.regexPath, "s"), hd, parsedPath.pathCaptureGroups); // Single-line mode works hand-in-hand with $ to exclude trailing slashes when matching.

        if (!(routeName is null))
            pathMap[routeName] = parsedPath;

        logTrace("Added %s route: %s", to!string(method), routes[method].back);

        return this;
    }

    string reverse(T...)(string routeName, T pathArguments) const
    {
        import std.array : replaceFirst;
        import std.format : format;
        import std.uri : encode;
        import std.variant : Variant, VariantException;

        auto routePresent = routeName in pathMap;

        if (routePresent is null)
            throw new NoReverseMatch(format("No route registered for name '%s'", routeName));

        auto pathData = pathMap[routeName];

        if (!(pathArguments.length == pathData.pathCaptureGroups.length))
            throw new NoReverseMatch("Count of path arguments given doesn't match count for those registered");

        auto result = pathData.path[];

        string toPath(T)(T value, string converterPathName) @trusted
        {
            auto wrappedValue = Variant(value);

            try{
                return converterMap[converterPathName].toPathDelegate(wrappedValue).encode;
            } catch (VariantException e) {
                throw new ConversionException(e.msg);
            }
        }

        foreach (i, pa; pathArguments)
        {
            try {
                result = result.replaceFirst(
                    pathData.pathCaptureGroups[i].rawCaptureGroup,
                    toPath(pa, pathData.pathCaptureGroups[i].converterPathName)
                );
            } catch (ConversionException e) {
                throw new NoReverseMatch(format("Reverse not found for '%s' with '%s'", routeName, pathArguments));
            }
        }

        return result;
    }

    void addPathConverters(PathConverterSpec[] pathConverters = [])
    {
        // This method must be called before adding handlers.
        import std.array : join;

        foreach (pathConverter; [defaultPathConverters, pathConverters].join)
        {
            converterMap[pathConverter.converterPathName] = pathConverter;
        }
    }

    private ParsedPath parsePath(string path, bool isEndpoint=false)
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

        return ParsedPath(path, getRegexPath(path, pathCaptureGroups, isEndpoint), pathCaptureGroups);
    }

    private PathCaptureGroup[] getCaptureGroups(ParseTree p)
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
                    {
                        // No path converter specified so we default to 'string'
                        return [PathCaptureGroup("string", p[0].matches[0], p.matches.join)];
                    }

                    else return [PathCaptureGroup(p[0].matches[0], p[1].matches[0], p.matches.join)];

                default:
                    assert(false);
            }
        }

        return walkForGroups(p);
    }

    /**
    * Convert a path containing named converter captures to one with named regex captures.
    *
    * The regex paths produced here are used in:
    *   - Request route matching
    *   - Request parameter extraction
    *
    * Examples:
    * ---
    * // Returns "^\\/hello\\/(?P<name>[^/]+)\\/*$"
    * getRegexPath("/hello/<string:name>/", [PathCaptureGroup("string", "name", "<string:name>")], true);
    * ---
    */
    private string getRegexPath(string path, PathCaptureGroup[] captureGroups, bool isEndpoint=false)
    {
        import std.algorithm.searching : endsWith;
        import std.array : replace, replaceFirst;

        string result = ("^" ~ path[]).replace("/", r"\/");
        if (isEndpoint) {
            if (result.endsWith(r"\/"))
                result = result ~ "*"; // If the route ends in a '/' we make it optional.

            result = result ~ "$";
        }

        foreach (group; captureGroups)
        {
            result = result.replaceFirst(
                group.rawCaptureGroup,
                getRegexCaptureGroup(group.converterPathName, group.pathParameter)
            );
        }

        return result;
    }

    private string getRegexCaptureGroup(string converterPathName, string pathParameter)
    {
        auto converterRegistered = converterPathName in converterMap;
        if (!converterRegistered)
            throw new ImproperlyConfigured("No path converter registered for '" ~ converterPathName ~ "'.");

        return "(?P<" ~ pathParameter ~ ">" ~ converterMap[converterPathName].regex ~ ")";
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
