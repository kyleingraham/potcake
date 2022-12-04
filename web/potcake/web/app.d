module potcake.web.app;

import potcake.http.router;
import std.variant : Variant;

public import vibe.http.server : HTTPServerRequest, HTTPServerRequestDelegate, HTTPServerResponse;
public import potcake.http.router : pathConverter;

alias SettingsDelegate = Variant delegate(string setting) @safe;

SettingsDelegate getSetting;

alias RouteAdder = void delegate(WebApp webApp) @safe;
alias RouteConfig = RouteAdder[];

class WebAppSettings
{
    string[] allowedHosts = ["localhost", "127.0.0.1"];
    ushort port = 9000;
    RouteConfig rootRouteConfig = [];
    string[] staticDirectories = [];
    string staticRoot;
    string staticRoutePath;
}

RouteAdder route(Handler)(string path, Handler handler, string name=null) @safe
{
    RouteAdder routeAdder = (webApp) @safe {
        webApp.addRoute(path, handler, name);
    };

    return routeAdder;
}

string reverse(T...)(string routeName, T pathArguments) @safe
{
    return getInitializedApp().reverse(routeName, pathArguments);
}

string staticPath(string relativePath) @safe
{
    import urllibparse : urlJoin;

    auto basePath = (() @trusted => getSetting("staticRoutePath").get!string)();
    assert(0 < basePath.length, "The 'staticRoot' setting must be set to generate static paths.");
    return urlJoin(basePath, relativePath);
}

const(WebApp) getInitializedApp() @safe {
    return initializedApp;
}

private WebApp initializedApp;

@safe final class WebApp
{
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

        getSetting = (setting) @safe {
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
        // TODO: Add exception logging middleware
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
            0 < webAppSettings.staticRoot.length &&
            0 < webAppSettings.staticDirectories.length &&
            0 < webAppSettings.staticRoutePath.length,
            "The 'staticRoot', 'staticDirectories', and 'staticRoutePath' settings must be set to serve collected static files."
        );

        return serveStaticFiles(webAppSettings.staticRoutePath, webAppSettings.staticRoot);
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

        bool shouldExit = handleArgs(args);
        if (shouldExit)
            return 0;

        vibeSettings = new HTTPServerSettings;
        vibeSettings.bindAddresses = webAppSettings.allowedHosts;
        vibeSettings.port = webAppSettings.port;

        addRoutes(webAppSettings.rootRouteConfig);

        auto listener = listenHTTP(vibeSettings, router);

        scope (exit)
        {
            listener.stopListening();
        }

        initializedApp = this;

        return runApplication();
    }

    private WebApp addRoutes(RouteConfig routeConfig)
    {
        foreach (routeAdder; routeConfig)
            routeAdder(this);

        return this;
    }

    private bool handleArgs(string[] args)
    {
        if (args.length <= 1)
            return false;

        if (args[1] == "--collectstatic")
        {
            collectStaticFiles();
            return true;
        }

        return false;
    }

    private void collectStaticFiles()
    {
        import std.array : join;
        import std.exception : enforce;
        import std.file : exists, isDir, mkdir, rmdirRecurse;
        import std.path : absolutePath, buildPath, isAbsolute;
        import std.process : execute;
        import std.stdio : writeln;

        enforce!ImproperlyConfigured(
            0 < webAppSettings.staticRoot.length,
            "The 'staticRoot' setting must be set to collect static files."
        );

        enforce!ImproperlyConfigured(
            0 < webAppSettings.staticDirectories.length,
            "The 'staticDirectories' setting must be set to collect static files."
        );

        writeln("Collecting static files...");

        auto staticRootPath =
        webAppSettings.staticRoot.isAbsolute ? webAppSettings.staticRoot : webAppSettings.staticRoot.absolutePath;

        if (staticRootPath.exists && staticRootPath.isDir)
            staticRootPath.rmdirRecurse;

        staticRootPath.mkdir;

        version(Windows)
        {
            string[] paths = [];

            foreach (staticDirectory; webAppSettings.staticDirectories)
            {
                auto staticDirectoryPath = staticDirectory.isAbsolute ? staticDirectory : staticDirectory.absolutePath;
                staticDirectoryPath = "'" ~ staticDirectoryPath.buildPath("*") ~ "'";
                paths ~= staticDirectoryPath;
            }

            auto joinedPaths = paths.join(",");

            auto command = ["powershell", "Copy-Item", "-Path", joinedPaths, "-Destination", "'" ~ staticRootPath ~ "'", "-Recurse", "-Force"];

            auto copyExecution = execute(command);

            if (copyExecution.status != 0)
            {
                writeln("Static file collecting failed:\n", copyExecution.output);
                assert(false);
            }
        }
        else
        {
            assert(false, "Static file collecting has only been implemented for Windows.");
        }

        writeln("Collected static files.");
    }
}

// TODO: Add library goals to README
// Sane and safe defaults
// Easy to use how you want or with our opinionated structure
// Useful components to prevent re-inventing the wheel
