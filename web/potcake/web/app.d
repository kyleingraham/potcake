module potcake.web.app;
@safe:

import potcake.http.router : Router;
import std.functional : memoize;
import std.process : processEnv = environment;
import std.variant : Variant;
import vibe.core.log : Logger;
import vibe.http.server : HTTPServerSettings;

public import vibe.core.log : FileLogger, LogLevel;
public import vibe.http.server : HTTPServerRequest, HTTPServerRequestDelegate, HTTPServerResponse, render;
public import potcake.http.router : MiddlewareFunction, MiddlewareDelegate, pathConverter, PathConverterSpec;
public import potcake.web.middleware : useIsSecureRequestMiddleware, useHstsMiddleware, useStaticFilesMiddleware, useRoutingMiddleware, useBrowserHardeningMiddleware, useHandlerMiddleware;

/**
 * Fetch a setting from the currently running web app. Fetched settings are read-only.
 *
 * Initialized by WebApp at instantiation.
 */
alias SettingsDelegate = const(Variant) delegate(string setting);
///
SettingsDelegate getSetting;

alias RouteAdder = void delegate(WebApp webApp);

alias RouteConfig = RouteAdder[];

alias WebAppMiddleware = WebApp function(WebApp webApp);

/**
 * Core settings for Potcake web apps. Provides reasonable defaults.
 *
 * Subclass to make custom settings available to your app.
 */
class WebAppSettings
{
    /**
     * The routes that your web app makes available.
     *
     * Eliminates the need to add routes manually. Intended to be given an array of calls to [route].
     *
     * Example:
     * ---
     * auto settings = new WebAppSettings();
     * settings.rootRouteConfig = [
     *     route("/", &index),
     *     route("/hello/", &hello),
     * ];
     * ---
     */
    RouteConfig rootRouteConfig = [];

    /// Directories containing static files for collection via the '--collectstatic' utility.
    string[] staticDirectories = [];

    /**
     * Directory from which static files are served and also where they are collected into.
     *
     * Static files are collected here by the '--collectstatic' utility. Relied on by [useStaticFilesMiddleware].
     */
    string rootStaticDirectory = "static";

    /**
     * The route prefix at which to serve static files e.g. "/static/".
     *
     * Relied on by [useStaticFilesMiddleware].
     */
    string staticRoutePath = "/static/";

    /// Direct access to the settings controlling the underlying vibe.d server.
    HTTPServerSettings vibed;

    /// Called to set vibe.d-related defaults.
    void initializeVibedSettings()
    {
        vibed = new HTTPServerSettings;
        vibed.bindAddresses = ["127.0.0.1", "localhost", "[::1]"];
        vibed.port = 9000;
    }

    /**
     * Logging configuration for your web app keyed on environment.
     *
     * This setting allows for:
     *   - varying logging between development and production.
     *   - varying log levels and formats between loggers in an environment.
     *
     * vibe.d provides a well-configured console logger. To use it supply [VibedStdoutLogger] via [LoggerSetting].
     *
     * See [initializeLoggingSettings] for a usage example.
     */
    LoggerSetting[][string] logging;

    /// Called to set logging-related defaults.
    void initializeLoggingSettings()
    {
        logging = [
            WebAppEnvironment.development: [
                LoggerSetting(LogLevel.info, new VibedStdoutLogger(), FileLogger.Format.threadTime),
            ],
            WebAppEnvironment.production: [],
        ];
    }

    /// Controls whether vibe.d server access logs should be displayed in the 'development' environment.
    bool logAccessInDevelopment = true;

    /**
     * Signals the evironment that your app is running in.
     *
     * Can be set with the POTCAKE_ENVIRONMENT environment variable.
     *
     * Potcake is pre-configured for [WebAppEnvironment] values but any string can be used.
     */
    string environment = WebAppEnvironment.development;

    /// Sets the web app environment via the process environment.
    void initializeEnvironment()
    {
        environment = processEnv.get("POTCAKE_ENVIRONMENT", WebAppEnvironment.development);
    }

    /// Middlware for the web app. Called forward and in reverse for every request in the order listed.
    WebAppMiddleware[] middleware = [
        &useIsSecureRequestMiddleware,
        &useHstsMiddleware,
        &useStaticFilesMiddleware,
        &useRoutingMiddleware,
        &useBrowserHardeningMiddleware,
        &useHandlerMiddleware,
    ];

    /// Settings for useIsSecureRequestMiddleware. See its docs for details.
    string[][string] allowedHosts;
    bool behindSecureProxy = false;

    void initializeAllowedHosts()
    {
        allowedHosts = [
            WebAppEnvironment.development: ["127.0.0.1", "localhost", "[::1]"],
            WebAppEnvironment.production: [],
        ];
    }

    string[string] secureSchemeHeaders;

    /// Initializes secureSchemeHeaders to defaults.
    void initializeSecureSchemeHeaders()
    {
        secureSchemeHeaders = [
            "X-Forwarded-Protocol": "ssl",
            "X-Forwarded-Proto": "https",
            "X-Forwarded-Ssl": "on",
        ];
    }

    /// Settings for useHstsMiddleware. See its docs for details.
    uint hstsMaxAgeDays = 30;
    bool hstsIncludeSubdomains = false;
    bool hstsPreload = false;
    string[] hstsExcludedHosts = ["127.0.0.1", "localhost", "[::1]"];

    /// Settings for useBrowserHardeningMiddleware. See its docs for details.
    bool contentTypeNoSniff = true;
    string referrerPolicy = "same-origin";
    string crossOriginOpenerPolicy = "same-origin";

    this()
    {
        initializeEnvironment();
        initializeVibedSettings();
        initializeLoggingSettings();
        initializeSecureSchemeHeaders();
        initializeAllowedHosts();
    }
}

/// Environment designators that Potcake supports out of the box.
enum WebAppEnvironment : string
{
    development = "development",
    production = "production",
}

/// A logger that signals Potcake to use vibe.d's built-in console logger.
final class VibedStdoutLogger : Logger {}

/// Supply to [WebAppSettings.logging] to add a logger for an environment.
struct LoggerSetting
{
    LogLevel logLevel;
    Logger logger;
    FileLogger.Format format = FileLogger.Format.plain; /// Only read for FileLogger loggers.
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

package static immutable char urlSeparator = '/';

private string staticPathImpl(string relativePath)
{
    import urllibparse : urlJoin;

    auto basePath = (() @trusted => getSetting("staticRoutePath").get!string)()[];
    assert(0 < basePath.length, "The 'staticRoutePath' setting must be set to generate static paths.");

    if (basePath[$-1] != urlSeparator)
        basePath ~= urlSeparator;

    return urlJoin(basePath, relativePath);
}

alias staticPath = memoize!staticPathImpl;

const(WebApp) getInitializedApp() {
    return initializedApp;
}

private WebApp initializedApp;

/**
 * Converts exceptions thrown in middleware to error responses.

   Automatically applied to all WebApp middleware. Handles:
    - SuspiciousOperation -> 400 response

   Unhandled exceptions propagate to vibe.d where they are turned into 500 responses.
 */
private MiddlewareDelegate exceptionToRequest(MiddlewareDelegate middleware)
{
    import potcake.core.exceptions : SuspiciousOperation;
    import vibe.http.status : HTTPStatus;

    return (next) {
        auto handler = middleware(next);

        void exceptionToRequestDelegate(HTTPServerRequest req, HTTPServerResponse res)
        {
            try
            {
                handler(req, res);
            }
            catch(SuspiciousOperation e)
            {
                res.writeBody(e.msg, HTTPStatus.badRequest, "text/html; charset=utf-8");
            }
        }

        return &exceptionToRequestDelegate;
    };
}

final class WebApp
{
    import potcake.core.exceptions : ImproperlyConfigured;
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

        initializeGetSetting(webAppSettings);

        initializeLogging();
    }

    private void initializeGetSetting(T)(T webAppSettings)
    if (is(T : WebAppSettings))
    {
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

    private void initializeLogging()
    {
        import vibe.core.log : setLogLevel, registerLogger, setLogFormat;

        setLogLevel(LogLevel.none);

        auto loggerSettings = webAppSettings.logging[webAppSettings.environment];

        foreach (loggerSetting; loggerSettings)
        {
            if (typeid(loggerSetting.logger) == typeid(VibedStdoutLogger))
            {
                setLogLevel(loggerSetting.logLevel);
                setLogFormat(loggerSetting.format, loggerSetting.format);
                continue;
            }

            if (auto logger = cast(FileLogger) loggerSetting.logger)
            {
                logger.format = loggerSetting.format;
            }

            loggerSetting.logger.minLevel = loggerSetting.logLevel;
            auto register = (() @trusted => registerLogger(cast(shared)loggerSetting.logger));
            register();
        }

        if (webAppSettings.environment == WebAppEnvironment.development && webAppSettings.logAccessInDevelopment)
            webAppSettings.vibed.accessLogToConsole = true;
    }

    package WebApp addMiddleware(WebAppMiddleware[] middleware)
    {
        router.clearMiddleware();

        foreach (ref addMiddlewareTo; middleware)
            addMiddlewareTo(this);

        return this;
    }

    WebApp addMiddleware(MiddlewareFunction middleware)
    {
        import std.functional : toDelegate;

        addMiddleware((() @trusted => toDelegate(middleware))());
        return this;
    }

    WebApp addMiddleware(MiddlewareDelegate middleware)
    {
        router.addMiddleware(exceptionToRequest(middleware));
        return this;
    }

    WebApp addRoute(Handler)(string path, Handler handler, string name=null)
    {
        router.any(path, handler, name);
        return this;
    }

    WebApp addRoutes(RouteConfig routeConfig)
    {
        foreach (addRouteTo; routeConfig)
            addRouteTo(this);

        return this;
    }

    string reverse(T...)(string routeName, T pathArguments) const
    {
        return router.reverse(routeName, pathArguments);
    }

    package WebApp useRoutingMiddleware()
    {
        router.useRoutingMiddleware();
        return this;
    }

    package WebApp useHandlerMiddleware()
    {
        router.useHandlerMiddleware();
        return this;
    }

    package string getRegexPath(string path, bool isEndpoint=false)
    {
        return router.parsePath(path, isEndpoint).regexPath;
    }

    int run(string[] args = [])
    {
        import vibe.http.server : listenHTTP;
        import vibe.core.core : runApplication;
        import vibe.core.log : logInfo;

        addRoutes(webAppSettings.rootRouteConfig);

        addMiddleware(webAppSettings.middleware);

        initializedApp = this;

        auto returnCode = handleArgs(args);
        if (returnCode != -1)
            return returnCode;

        auto listener = listenHTTP(webAppSettings.vibed, router);

        scope (exit)
        {
            listener.stopListening();
        }

        logInfo("Running in '%s' environment.", webAppSettings.environment);

        return runApplication();
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
