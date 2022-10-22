module potcake.web.app;

import potcake.http.router;
import std.variant : Variant;

class WebAppBuilder(WebAppBuildSettings buildSettings = WebAppBuildSettings())
{
    static WebApp!(buildSettings.userPathConverters) build(WebAppSettings appSettings = new WebAppSettings())
    {
        return new WebApp!(buildSettings.userPathConverters)(appSettings);
    }
}

struct WebAppBuildSettings
{
    BoundPathConverter[] userPathConverters = [];
}

// How can we store a route handler? I've never stored one outside a delegate.
// Variants are run-time objects.
// The compiler needs to know how much space to allocate for storage.
// Store calls to register route?

alias RouteAdder = void delegate(T)(scope ref T webAppSettings) @safe;

RouteAdder route(string path, Handler)(Handler handler, string name)
{
    // TODO: Do something with `name` for reversing
    return (webAppSettings) @safe {
        webAppSettings.addRoute!(path)(&handler);
    };
}

class WebAppSettings
{
    string[] allowedHosts = ["localhost", "127.0.0.1", "::1"];
    ushort port = 9000;
}

alias SettingsDelegate = Variant delegate(string setting) @safe;
SettingsDelegate getSetting;

class WebApp(BoundPathConverter[] userPathConverters = [])
{
    import vibe.http.server : HTTPServerSettings;

    private {
        HTTPServerSettings vibeSettings;
        alias WebAppRouter = Router!(userPathConverters);
        WebAppRouter router;
        WebAppSettings webAppSettings;
    }

    this(T)(T webAppSettings)
    if (is(T : WebAppSettings))
    {
        this.webAppSettings = webAppSettings;
        router = new WebAppRouter;

        getSetting = (setting) @safe {
            //Variant a = 3; // This is not safe
            //return () @trusted {Variant a = 3; return a;}(); // But this is
            Variant fetchedSetting;

            switch (setting) {
                static foreach (member; [__traits(allMembers, T)])
                {
                    import std.traits : isFunction;

                    // Prevent latching onto built-in functions. Downside here is leaving out zero-parameter functions.
                    static if (mixin("!isFunction!(T." ~ member ~ ")") && member != "Monitor")
                    {
                        mixin("case \"" ~ member ~ "\":");
                        mixin("return () @trusted {fetchedSetting = __traits(getMember, webAppSettings, \"" ~ member ~ "\"); return fetchedSetting;}();");
                    }
                }

                default:
                    throw new ImproperlyConfigured("Unknown setting: " ~ setting);
            }
        };
    }

    void addMiddleware(MiddlewareFunction middleware)
    {
        import std.functional : toDelegate;

        addMiddleware(toDelegate(middleware));
    }

    void addMiddleware(MiddlewareDelegate middleware)
    {
        // TODO: Add exception logging middleware
        router.addMiddleware(middleware);
    }

    void addRoute(string path, Handler)(Handler handler)
    {
        // TODO: Handle ImproperlyConfigured and return useful message
        // TODO: & or no-& for handler?
        router.any!(path)(handler);
    }

    int run()
    {
        import vibe.http.server : listenHTTP;
        import vibe.core.core : runApplication;

        vibeSettings = new HTTPServerSettings;
        vibeSettings.bindAddresses = webAppSettings.allowedHosts;
        vibeSettings.port = webAppSettings.port;

        auto listener = listenHTTP(vibeSettings, router);

        scope (exit)
        {
            listener.stopListening();
        }

        return runApplication();
    }
}

// TODO: Add library goals to README
// Sane and safe defaults
// Easy to use how you want or with our opinionated structure
// Useful components to prevent re-inventing the wheel
