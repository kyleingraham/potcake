module potcake.web.app;
@safe:

import potcake.http.router : Router;
import std.functional : memoize;
import std.variant : Variant;

public import vibe.http.server : HTTPServerRequest, HTTPServerRequestDelegate, HTTPServerResponse;
public import potcake.http.router : MiddlewareFunction, MiddlewareDelegate, pathConverter, PathConverterSpec;

alias SettingsDelegate = Variant delegate(string setting);

SettingsDelegate getSetting;

alias RouteAdder = void delegate(WebApp webApp);
alias RouteConfig = RouteAdder[];

class WebAppSettings
{
    string[] allowedHosts = ["localhost", "127.0.0.1"];
    ushort port = 9000;
    RouteConfig rootRouteConfig = [];
    string[] staticDirectories = [];
    string rootStaticDirectory;
    string staticRoutePath;
}

RouteAdder route(Handler)(string path, Handler handler, string name=null)
{
    RouteAdder routeAdder = (webApp) {
        webApp.addRoute(path, handler, name);
    };

    return routeAdder;
}

string reverse(T...)(string routeName, T pathArguments)
{
    return getInitializedApp().reverse(routeName, pathArguments);
}

static immutable char urlSeparator = '/';

string staticPathImpl(string relativePath)
{
    import urllibparse : urlJoin;

    auto basePath = (() @trusted => getSetting("staticRoutePath").get!string)();
    assert(0 < basePath.length, "The 'rootStaticDirectory' setting must be set to generate static paths.");

    if (basePath[$-1] != urlSeparator)
        basePath ~= urlSeparator;

    return urlJoin(basePath, relativePath);
}

alias staticPath = memoize!staticPathImpl;

const(WebApp) getInitializedApp() {
    return initializedApp;
}

private WebApp initializedApp;

final class WebApp
{
    import potcake.http.router : ImproperlyConfigured;
    import vibe.http.server : HTTPServerSettings;

    private {
        HTTPServerSettings vibeSettings;
        Router router;
        WebAppSettings webAppSettings;
    }

    this()
    {
        auto webAppSettings = new WebAppSettings;
        this(webAppSettings);
    }

    this(PathConverterSpec[] pathConverters = [])
    {
        auto webAppSettings = new WebAppSettings;
        this(webAppSettings, pathConverters);
    }

    this(T)(T webAppSettings, PathConverterSpec[] pathConverters = [])
    if (is(T : WebAppSettings))
    {
        this.webAppSettings = webAppSettings;

        router = new Router;
        router.addPathConverters(pathConverters);

        getSetting = (setting) {
            Variant fetchedSetting;

            switch (setting) {
                static foreach (member; [__traits(allMembers, T)])
                {
                    import std.traits : isFunction;

                    // Prevent latching onto built-in functions. Downside here is leaving out zero-parameter functions. Could use arity.
                    static if (mixin("!isFunction!(T." ~ member ~ ")") && member != "Monitor")
                    {
                        mixin("case \"" ~ member ~ "\":");
                        //Variant a = 3; // This is not safe
                        //return () @trusted {Variant a = 3; return a;}(); // But this is
                        mixin("return () @trusted {fetchedSetting = __traits(getMember, webAppSettings, \"" ~ member ~ "\"); return fetchedSetting;}();");
                    }
                }

                default: throw new ImproperlyConfigured("Unknown setting: " ~ setting);
            }
        };
    }

    WebApp addMiddleware(MiddlewareFunction middleware)
    {
        import std.functional : toDelegate;

        addMiddleware((() @trusted => toDelegate(middleware))());
        return this;
    }

    WebApp addMiddleware(MiddlewareDelegate middleware)
    {
        router.addMiddleware(middleware);
        return this;
    }

    WebApp addRoute(Handler)(string path, Handler handler, string name=null)
    {
        router.any(path, handler, name);
        return this;
    }

    string reverse(T...)(string routeName, T pathArguments) const
    {
        return router.reverse(routeName, pathArguments);
    }

    WebApp serveStaticFiles()
    {
        import std.exception : enforce;

        enforce!ImproperlyConfigured(
            0 < webAppSettings.rootStaticDirectory.length &&
            0 < webAppSettings.staticDirectories.length &&
            0 < webAppSettings.staticRoutePath.length,
            "The 'rootStaticDirectory', 'staticDirectories', and 'staticRoutePath' settings must be set to serve collected static files."
        );

        return serveStaticFiles(webAppSettings.staticRoutePath, webAppSettings.rootStaticDirectory);
    }

    WebApp serveStaticFiles(string routePath, string directoryPath)
    {
        import std.string : stripRight;
        import vibe.http.fileserver : HTTPFileServerSettings, serveStaticFiles;

        auto routePathPrefix = routePath.stripRight("/");
        auto settings = new HTTPFileServerSettings(routePathPrefix);
        router.get(routePathPrefix ~ "<path:static_file_path>", serveStaticFiles(directoryPath, settings));
        return this;
    }

    int run(string[] args = [])
    {
        import vibe.http.server : listenHTTP;
        import vibe.core.core : runApplication;

        vibeSettings = new HTTPServerSettings;
        vibeSettings.bindAddresses = webAppSettings.allowedHosts;
        vibeSettings.port = webAppSettings.port;

        addRoutes(webAppSettings.rootRouteConfig);

        initializedApp = this;

        auto returnCode = handleArgs(args);
        if (returnCode != -1)
            return returnCode;

        auto listener = listenHTTP(vibeSettings, router);

        scope (exit)
        {
            listener.stopListening();
        }

        return runApplication();
    }

    private WebApp addRoutes(RouteConfig routeConfig)
    {
        foreach (routeAdder; routeConfig)
            routeAdder(this);

        return this;
    }

    private int handleArgs(string[] args)
    {
        import potcake.web.commands : collectStaticFilesCommand;

        if (args.length <= 1)
            return -1;

        if (args[1] == "--collectstatic")
        {
            return collectStaticFilesCommand();
        }
        else
        {
            return -1;
        }
    }
}

// TODO: Add library goals to README
// Sane and safe defaults
// Easy to use how you want or with our opinionated structure
// Useful components to prevent re-inventing the wheel
