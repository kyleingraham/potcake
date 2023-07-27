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
     * Directory into which to collect static files and optional serve them.
     *
     * Relied on by [WebApp.serveStaticFiles()].
     */
    string rootStaticDirectory;

    /**
     * The route prefix at which to serve static files e.g. "/static/".
     *
     * Relied on by [WebApp.serveStaticFiles()].
     */
    string staticRoutePath;

    /// Direct access to the settings controlling the underlying vibe.d server.
    HTTPServerSettings vibed;

    /// Called to set vibe.d-related defaults.
    void initializeVibedSettings()
    {
        vibed = new HTTPServerSettings;
        vibed.bindAddresses = ["localhost", "127.0.0.1"];
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

    /// Controls whether vibe.d server access logs should be displayed in the 'development' environment for convenience.
    bool logAccessInDevelopment = true;

    /**
     * Signals the evironment that your app is running in.
     *
     * Can be set with the POTCAKE_ENVIRONMENT environment variable.
     *
     * Potcake is pre-configured for WebAppEnvironment values but any string can be used.
     */
    string environment = WebAppEnvironment.development;

    /// Sets environment via the process environment.
    void initializeEnvironment()
    {
        environment = processEnv.get("POTCAKE_ENVIRONMENT", WebAppEnvironment.development);
    }

    this()
    {
        initializeEnvironment();
        initializeVibedSettings();
        initializeLoggingSettings();
    }
}

/// Environment designators that Potcake supports out of the box. Strings to allow end-user flexibility.
enum WebAppEnvironment : string
{
    development = "development",
    production = "production",
}

/// A logger for signifying the desire to use vibe.d's built-in console logger.
final class VibedStdoutLogger : Logger {}

/// Supply to [WebAppSettings.logging] to add a logger for an environment.
struct LoggerSetting
{
    LogLevel logLevel;
    Logger logger;
    FileLogger.Format format = FileLogger.Format.plain; /// Only read from for FileLogger loggers.
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

    WebApp serveStaticFiles()
    {
        import std.exception : enforce;

        enforce!ImproperlyConfigured(
            0 < webAppSettings.rootStaticDirectory.length &&
            0 < webAppSettings.staticRoutePath.length,
            "The 'rootStaticDirectory', 'staticRoutePath' settings must be set to serve static files."
        );

        return serveStaticFiles(webAppSettings.staticRoutePath, webAppSettings.rootStaticDirectory);
    }

    private WebApp serveStaticFiles(string routePath, string directoryPath)
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
        import vibe.core.log : logInfo;

        vibeSettings = new HTTPServerSettings;
        vibeSettings.bindAddresses = webAppSettings.allowedHosts;
        vibeSettings.port = webAppSettings.port;

        addRoutes(webAppSettings.rootRouteConfig);

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
