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

    string reverse(T...)(string routeName, T pathArguments) const
    {
        return router.reverse(routeName, pathArguments);
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

    int run()
    {
        import vibe.http.server : listenHTTP;
        import vibe.core.core : runApplication;

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
}

// TODO: Add library goals to README
// Sane and safe defaults
// Easy to use how you want or with our opinionated structure
// Useful components to prevent re-inventing the wheel
