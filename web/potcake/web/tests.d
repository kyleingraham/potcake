module potcake.web.tests;
@safe:

import potcake.web.app;

void runTest(void delegate() runAppFunction, void delegate() testAppFunction) @trusted
{

    import core.thread.osthread : Thread;
    import core.time : dur;
    import std.concurrency : spawn;
    import std.net.curl : HTTPStatusException;
    import unit_threaded.assertions : shouldNotThrow;

    spawn(runAppFunction.funcptr);
    Thread.sleep(dur!"msecs"(300));

    shouldNotThrow!HTTPStatusException(testAppFunction());
}

void stopApp(HTTPServerRequest req, HTTPServerResponse res)
{
    import vibe.core.core : exitEventLoop;
    import vibe.http.status : HTTPStatus;

    res.contentType = "text/html; charset=UTF-8";
    res.writeBody("Stopping app...", HTTPStatus.ok);
    exitEventLoop();
}

void nameHandler(HTTPServerRequest req, HTTPServerResponse res, string name)
{
    import vibe.core.core : exitEventLoop;
    import vibe.http.status : HTTPStatus;

    res.contentType = "text/html; charset=UTF-8";
    res.writeBody(name, HTTPStatus.ok);
    exitEventLoop();
}

void doNothingHandler(HTTPServerRequest req, HTTPServerResponse res)
{
    res.writeBody("done");
}

unittest
{
    // Do we add routes via 'addRoute' as expected?
    import std.net.curl : get;
    import unit_threaded.assertions : shouldEqual;

    void runApp()
    {
        auto app = new WebApp;
        app.addRoute("/hello/<string:name>/", &nameHandler);
        app.run();
    }

    void testApp()
    {
        string expectedName = "potcake";
        auto content = get("http://127.0.0.1:9000/hello/" ~ expectedName ~ "/");
        content.shouldEqual(expectedName, "Web app did not respond with exptected content.");
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // Do we add routes via 'addRoutes' as expected?
    import std.net.curl : get;
    import unit_threaded.assertions : shouldEqual;

    void runApp()
    {
        auto app = new WebApp;
        auto routes = [
            route("/hello/1/<string:name>/", &nameHandler, "name-1"),
            route("/hello/2/<string:name>/", &nameHandler, "name-2"),
        ];
        app.addRoutes(routes);
        app.run();
    }

    void testApp()
    {
        string expectedName = "potcake";
        auto content = get("http://127.0.0.1:9000/hello/1/" ~ expectedName ~ "/");
        content.shouldEqual(expectedName, "Web app did not respond with exptected content.");
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // Do we add routes via 'rootRouteConfig' as expected?
    import std.net.curl : get;
    import unit_threaded.assertions : shouldEqual;

    void runApp()
    {
        auto settings = new WebAppSettings;
        settings.rootRouteConfig = [
            route("/hello/1/<string:name>/", &nameHandler, "name-1"),
            route("/hello/2/<string:name>/", &nameHandler, "name-2"),
        ];

        auto app = new WebApp(settings);
        app.run();
    }

    void testApp()
    {
        string expectedName = "potcake";
        auto content = get("http://127.0.0.1:9000/hello/1/" ~ expectedName ~ "/");
        content.shouldEqual(expectedName, "Web app did not respond with exptected content.");
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // Do we add path converters via 'addPathConverters' as expected?
    import std.net.curl : get;
    import unit_threaded.assertions : shouldEqual;

    struct TestStringConverter
    {
        enum regex = "[^/]+";

        string toD(const string value)
        {
            return "PASS";
        }

        string toPath(const string value)
        {
            return value;
        }
    }

    void runApp()
    {
        auto app = new WebApp([pathConverter("string", TestStringConverter())]);
        app.addRoute("/hello/<string:name>/", &nameHandler);
        app.run();
    }

    void testApp()
    {
        string expectedName = "PASS";
        auto content = get("http://127.0.0.1:9000/hello/FAIL/");
        content.shouldEqual(expectedName, "Web app did not pass path converter to router.");
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // Do we reverse paths correctly?
    import std.net.curl : get;
    import unit_threaded.assertions : shouldEqual;

    void runApp()
    {
        void reverser(HTTPServerRequest req, HTTPServerResponse res, string routeName)
        {
            import vibe.core.core : exitEventLoop;
            import vibe.http.status : HTTPStatus;

            res.contentType = "text/html; charset=UTF-8";
            res.writeBody(reverse(routeName, "PASS"), HTTPStatus.ok);
            exitEventLoop();
        }

        auto app = new WebApp;
        app.addRoute("/hello/<string:name>/", &reverser, "reverser");
        app.run();
    }

    void testApp()
    {
        auto expectedReverse = "/hello/PASS/";
        auto content = get("http://127.0.0.1:9000/hello/reverser/");
        content.shouldEqual(expectedReverse, "reverse failed to provided reversed path");
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // Can we serve from a manually-specified static file location?
    import std.file : remove, tempDir, write;
    import std.net.curl : get;
    import std.path : absolutePath, buildPath, dirName;
    import unit_threaded.assertions : shouldEqual;

    void runApp()
    {
        auto staticFile = tempDir.absolutePath.buildPath("test-file-1.css");
        scope(exit) staticFile.remove;
        staticFile.write("PASS");

        auto settings = new WebAppSettings;
        settings.rootStaticDirectory = staticFile.dirName.absolutePath;
        settings.staticRoutePath = "/static/";

        auto app = new WebApp(settings);
        app
        .addRoute("/stopapp/", &stopApp)
        .run();
    }

    void testApp()
    {
        auto expectedContent = "PASS";
        auto content = get("http://127.0.0.1:9000/static/test-file-1.css");
        scope(exit) get("http://127.0.0.1:9000/stopapp/");
        content.shouldEqual(expectedContent, "Failed to serve from a manually-specified static file location");
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // Do we prevent writes to web app settings?
    import std.net.curl : get;
    import unit_threaded.assertions : shouldEqual;

    void handler(HTTPServerRequest req, HTTPServerResponse res)
    {
        import vibe.http.server : HTTPServerSettings;
        import vibe.http.status : HTTPStatus;

        auto vibedSettings = (() @trusted => getSetting("vibed").get!HTTPServerSettings)();

        bool writeToSettingsAllowed = true;
        writeToSettingsAllowed = __traits(
            compiles, vibedSettings.accessLogToConsole = !vibedSettings.accessLogToConsole
        );
        writeToSettingsAllowed.shouldEqual(false);

        res.contentType = "text/html; charset=UTF-8";
        res.writeBody("done", HTTPStatus.ok);
    }

    void runApp()
    {
        auto app = new WebApp;
        app
        .addRoute("/test/", &handler)
        .addRoute("/stopapp/", &stopApp)
        .run();
    }

    void testApp()
    {
        scope(exit) get("http://127.0.0.1:9000/stopapp/");
        get("http://127.0.0.1:9000/test/");
    }

    runTest(&runApp, &testApp);
}

void getSettingHandler(HTTPServerRequest req, HTTPServerResponse res, string setting)
{
    import vibe.http.status : HTTPStatus;

    auto environment = (() @trusted => getSetting(setting).get!string)();
    res.contentType = "text/html; charset=UTF-8";
    res.writeBody(environment, HTTPStatus.ok);
}

unittest
{
    // Do we setup default loggers for the development environment?
    import std.conv : to;
    import std.net.curl : get;
    import vibe.core.log : getLoggers;
    import unit_threaded.assertions : shouldEqual;

    void runApp()
    {
        auto app = new WebApp;
        app
        .addRoute("/getsetting/<setting>/", &getSettingHandler)
        .addRoute("/stopapp/", &stopApp)
        .run();
    }

    void testApp()
    {
        scope(exit) get("http://127.0.0.1:9000/stopapp/");

        auto environment = get("http://127.0.0.1:9000/getsetting/environment/");
        environment.shouldEqual(to!string(WebAppEnvironment.development));

        auto allLoggers = getLoggers();
        allLoggers.length.shouldEqual(1);
        auto logger = cast(FileLogger) allLoggers[0];
        logger.minLevel.shouldEqual(LogLevel.info);
        logger.format.shouldEqual(FileLogger.Format.threadTime);
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // Do we start with zero logging for the production environment?
    import std.conv : to;
    import std.net.curl : get;
    import vibe.core.log : getLoggers;
    import unit_threaded.assertions : shouldEqual;

    void runApp()
    {
        auto settings = new WebAppSettings;
        settings.environment = WebAppEnvironment.production;
        settings.allowedHosts[WebAppEnvironment.production] = ["*"];

        auto app = new WebApp(settings);
        app
        .addRoute("/getsetting/<setting>/", &getSettingHandler)
        .addRoute("/stopapp/", &stopApp)
        .run();
    }

    void testApp()
    {
        scope(exit) get("http://127.0.0.1:9000/stopapp/");

        auto environment = get("http://127.0.0.1:9000/getsetting/environment/");
        environment.shouldEqual(to!string(WebAppEnvironment.production));

        auto allLoggers = getLoggers();
        allLoggers.length.shouldEqual(1);

        auto logger = cast(FileLogger) allLoggers[0];
        logger.minLevel.shouldEqual(LogLevel.none);
        logger.format.shouldEqual(FileLogger.Format.threadTime);
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // Can we add loggers for environments?
    import std.conv : to;
    import std.net.curl : get;
    import std.stdio : stderr, stdout;
    import vibe.core.log : getLoggers;
    import unit_threaded.assertions : shouldEqual;

    void runApp()
    {
        auto settings = new WebAppSettings;
        settings.environment = WebAppEnvironment.production;
        settings.logging[WebAppEnvironment.production] ~= [
            LoggerSetting(LogLevel.warn, new FileLogger(stdout, stderr), FileLogger.Format.thread),
        ];
        settings.allowedHosts[WebAppEnvironment.production] = ["*"];

        auto app = new WebApp(settings);
        app
        .addRoute("/getsetting/<setting>/", &getSettingHandler)
        .addRoute("/stopapp/", &stopApp)
        .run();
    }

    void testApp()
    {
        scope(exit) get("http://127.0.0.1:9000/stopapp/");

        auto environment = get("http://127.0.0.1:9000/getsetting/environment/");
        environment.shouldEqual(to!string(WebAppEnvironment.production));

        auto allLoggers = getLoggers();
        allLoggers.length.shouldEqual(2);

        auto logger = cast(FileLogger) allLoggers[0];
        logger.minLevel.shouldEqual(LogLevel.none);
        logger.format.shouldEqual(FileLogger.Format.threadTime);

        logger = cast(FileLogger) allLoggers[1];
        logger.minLevel.shouldEqual(LogLevel.warn);
        logger.format.shouldEqual(FileLogger.Format.thread);
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // Do we display access logs in the development environment?
    import std.net.curl : get;
    import unit_threaded.assertions : shouldEqual;

    void handler(HTTPServerRequest req, HTTPServerResponse res)
    {
        import vibe.http.server : HTTPServerSettings;
        import vibe.http.status : HTTPStatus;

        auto vibedSettings = (() @trusted => getSetting("vibed").get!HTTPServerSettings)();

        vibedSettings.accessLogToConsole.shouldEqual(true);

        res.contentType = "text/html; charset=UTF-8";
        res.writeBody("done", HTTPStatus.ok);
    }

    void runApp()
    {
        auto app = new WebApp;
        app
        .addRoute("/test/", &handler)
        .addRoute("/stopapp/", &stopApp)
        .run();
    }

    void testApp()
    {
        scope(exit) get("http://127.0.0.1:9000/stopapp/");
        get("http://127.0.0.1:9000/test/");
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // Do we suppress access logs in the production environment?
    import std.net.curl : get;
    import unit_threaded.assertions : shouldEqual;

    void handler(HTTPServerRequest req, HTTPServerResponse res)
    {
        import vibe.http.server : HTTPServerSettings;
        import vibe.http.status : HTTPStatus;

        auto vibedSettings = (() @trusted => getSetting("vibed").get!HTTPServerSettings)();

        vibedSettings.accessLogToConsole.shouldEqual(false);

        res.contentType = "text/html; charset=UTF-8";
        res.writeBody("done", HTTPStatus.ok);
    }

    void runApp()
    {
        auto settings = new WebAppSettings;
        settings.environment = WebAppEnvironment.production;
        settings.allowedHosts[WebAppEnvironment.production] = ["*"];

        auto app = new WebApp(settings);
        app
        .addRoute("/test/", &handler)
        .addRoute("/stopapp/", &stopApp)
        .run();
    }

    void testApp()
    {
        scope(exit) get("http://127.0.0.1:9000/stopapp/");
        get("http://127.0.0.1:9000/test/");
    }

    runTest(&runApp, &testApp);
}

void removeDirectory(string directoryPath, string expectedDirectoryName)
{
    import std.file : exists, isDir, rmdirRecurse;
    import std.path : baseName;

    if (directoryPath.exists && directoryPath.isDir && directoryPath.baseName == expectedDirectoryName)
        directoryPath.rmdirRecurse;
}

unittest
{
    // Can we serve from a collected static file location?
    import std.file : mkdir, remove, tempDir, write;
    import std.net.curl : get;
    import std.path : absolutePath, buildPath, dirName;
    import unit_threaded.assertions : shouldEqual;

    void runApp()
    {
        auto staticFile = __FILE_FULL_PATH__.dirName.buildPath("test_fixtures", "static", "test.css");
        auto rootStaticDirectoryName = "teststaticroot";
        auto rootStaticDirectoryPath = tempDir.absolutePath.buildPath(rootStaticDirectoryName);

        removeDirectory(rootStaticDirectoryPath, rootStaticDirectoryName);
        rootStaticDirectoryPath.mkdir;
        scope(exit) removeDirectory(rootStaticDirectoryPath, rootStaticDirectoryName);

        auto settings = new WebAppSettings;
        settings.staticDirectories = [staticFile.dirName.absolutePath];
        settings.rootStaticDirectory = rootStaticDirectoryPath;
        settings.staticRoutePath = "/static";

        auto app = new WebApp(settings);

        if (app.run(["", "--collectstatic"]) != 0)
            return;

        app.addRoute("/stopapp/", &stopApp);
        app.run();
    }

    void testApp()
    {
        auto expectedContent = "PASS";
        auto content = get("http://127.0.0.1:9000/static/test.css");
        scope(exit) get("http://127.0.0.1:9000/stopapp/");
        content.shouldEqual(expectedContent, "Failed to serve from a manually-specified static file location");
    }

    runTest(&runApp, &testApp);
}

unittest {
    // Do we correctly compute static paths regardless of whether 'staticRoutePath' has a trailing '/'?
    import unit_threaded.assertions : shouldEqual;

    auto expectedPath = "/static/css/styles.css";

    auto settings = new WebAppSettings;
    settings.staticRoutePath = "/static";
    auto app = new WebApp(settings);
    auto computedPath = staticPath("css/styles.css");
    computedPath.shouldEqual(expectedPath);

    settings.staticRoutePath = "/static/";
    app = new WebApp(settings);
    computedPath.shouldEqual(expectedPath);
}

unittest
{
    // useBrowserHardeningMiddleware
    import vibe.http.client : requestHTTP;
    import unit_threaded.assertions : shouldEqual;

    void runApp()
    {
        auto app = new WebApp;
        app
        .addRoute("/test/", &doNothingHandler)
        .addRoute("/stopapp/", &stopApp)
        .run();
    }

    void testApp()
    {
        scope(exit) requestHTTP("http://127.0.0.1:9000/stopapp/", (scope req) {}, (scope res) {});
        requestHTTP("http://127.0.0.1:9000/test/", (scope req) {}, (scope res) {
            res.headers.get("X-Content-Type-Options").shouldEqual("nosniff");
            res.headers.get("Referrer-Policy").shouldEqual("same-origin");
            res.headers.get("Cross-Origin-Opener-Policy").shouldEqual("same-origin");
        });
    }

    runTest(&runApp, &testApp);
}

void assertSecure(HTTPServerRequest req, HTTPServerResponse res)
{
    auto requestIsSecure = (() @trusted => req.context["isSecure"].get!(const(bool)))();

    if (requestIsSecure)
        res.writeBody("1");
    else
        res.writeBody("0");
}

void assertInsecure(HTTPServerRequest req, HTTPServerResponse res)
{
    auto requestIsSecure = (() @trusted => req.context["isSecure"].get!(const(bool)))();

    if (requestIsSecure)
        res.writeBody("0");
    else
        res.writeBody("1");
}

unittest
{
    // useIsSecureRequestMiddleware
    import std.array : byPair;
    import unit_threaded.assertions : shouldEqual;
    import vibe.http.client : requestHTTP;
    import vibe.http.status : HTTPStatus;
    import vibe.stream.operations : readAllUTF8;

    void runApp()
    {
        auto settings = new WebAppSettings;
        settings.environment = WebAppEnvironment.development;
        settings.behindSecureProxy = true;

        auto app = new WebApp(settings);
        app
        .addRoute("/assert/secure/", &assertSecure)
        .addRoute("/assert/insecure/", &assertInsecure)
        .addRoute("/stopapp/", &stopApp)
        .run();
    }

    void testApp()
    {
        scope(exit) requestHTTP("http://127.0.0.1:9000/stopapp/", (scope req) {}, (scope res) {});

        auto settings = new WebAppSettings;

        settings.allowedHosts[WebAppEnvironment.development].shouldEqual(["127.0.0.1", "localhost", "[::1]"]);
        settings.allowedHosts[WebAppEnvironment.production].length.shouldEqual(0);
        settings.secureSchemeHeaders.shouldEqual([
            "X-Forwarded-Protocol": "ssl",
            "X-Forwarded-Proto": "https",
            "X-Forwarded-Ssl": "on",
        ]);

        foreach (secureProxy; settings.allowedHosts[WebAppEnvironment.development])
        {
            foreach (schemeHeader; settings.secureSchemeHeaders.byPair())
            {
                requestHTTP("http://127.0.0.1:9000/assert/secure/", (scope req) {
                    req.host(secureProxy);
                    req.headers[schemeHeader.key] = schemeHeader.value;
                }, (scope res) {
                    res.bodyReader.readAllUTF8.shouldEqual("1");
                });
            }
        }

        // Untrused proxy in host header
        requestHTTP("http://127.0.0.1:9000/assert/insecure/", (scope req) {
            req.host("invalid");
            req.headers["X-Forwarded-Protocol"] = settings.secureSchemeHeaders["X-Forwarded-Protocol"];
        }, (scope res) {
            res.bodyReader.readAllUTF8.shouldEqual(
                "Invalid Host header. Add 'invalid' to WebAppSettings.allowedHosts."
            );
            res.statusCode.shouldEqual(HTTPStatus.badRequest);
        });

        // Multiple valid secure scheme headers
        requestHTTP("http://127.0.0.1:9000/assert/secure/", (scope req) {
            req.host(settings.allowedHosts[WebAppEnvironment.development][0]);
            req.headers["X-Forwarded-Protocol"] = settings.secureSchemeHeaders["X-Forwarded-Protocol"];
            req.headers["X-Forwarded-Proto"] = settings.secureSchemeHeaders["X-Forwarded-Proto"];
        }, (scope res) {
            res.bodyReader.readAllUTF8.shouldEqual("1");
        });

        // Multiple secure scheme headers but one is invalid
        requestHTTP("http://127.0.0.1:9000/assert/insecure/", (scope req) {
            req.host(settings.allowedHosts[WebAppEnvironment.development][0]);
            req.headers["X-Forwarded-Protocol"] = settings.secureSchemeHeaders["X-Forwarded-Protocol"];
            req.headers["X-Forwarded-Proto"] = "invalid";
        }, (scope res) {
            res.bodyReader.readAllUTF8.shouldEqual("1");
        });
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // useIsSecureRequestMiddleware - Test that requests without secure proxy are insecure without vibe.d TLS.
    import unit_threaded.assertions : shouldEqual;
    import vibe.http.client : requestHTTP;
    import vibe.stream.operations : readAllUTF8;

    void runApp()
    {
        auto settings = new WebAppSettings;
        settings.environment = WebAppEnvironment.development;
        settings.behindSecureProxy = false;

        auto app = new WebApp(settings);
        app
        .addRoute("/assert/insecure/", &assertInsecure)
        .addRoute("/stopapp/", &stopApp)
        .run();
    }

    void testApp()
    {
        scope(exit) requestHTTP("http://127.0.0.1:9000/stopapp/", (scope req) {}, (scope res) {});

        auto settings = new WebAppSettings;

        // Allowed host and valid secure scheme headers
        requestHTTP("http://127.0.0.1:9000/assert/insecure/", (scope req) {
            req.host(settings.allowedHosts[WebAppEnvironment.development][0]);
            req.headers["X-Forwarded-Protocol"] = settings.secureSchemeHeaders["X-Forwarded-Protocol"];
        }, (scope res) {
            res.bodyReader.readAllUTF8.shouldEqual("1");
        });
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // useIsSecureRequestMiddleware - Test wildcard for allowedHosts.
    import unit_threaded.assertions : shouldEqual;
    import vibe.http.client : requestHTTP;
    import vibe.stream.operations : readAllUTF8;

    void runApp()
    {
        auto settings = new WebAppSettings;
        settings.environment = WebAppEnvironment.development;
        settings.behindSecureProxy = true;
        settings.allowedHosts[WebAppEnvironment.development] = ["*"];

        auto app = new WebApp(settings);
        app
        .addRoute("/assert/secure/", &assertSecure)
        .addRoute("/stopapp/", &stopApp)
        .run();
    }

    void testApp()
    {
        scope(exit) requestHTTP("http://127.0.0.1:9000/stopapp/", (scope req) {}, (scope res) {});

        auto settings = new WebAppSettings;

        // Allowed host and valid secure scheme headers
        requestHTTP("http://127.0.0.1:9000/assert/secure/", (scope req) {
            req.host("any-host-works-here");
            req.headers["X-Forwarded-Protocol"] = settings.secureSchemeHeaders["X-Forwarded-Protocol"];
        }, (scope res) {
            res.bodyReader.readAllUTF8.shouldEqual("1");
        });
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // splitHost
    import potcake.web.middleware : splitHost;
    import unit_threaded.assertions : shouldEqual;
    import vibe.http.server : createTestHTTPServerRequest;
    import vibe.inet.url : URL;

    auto req = createTestHTTPServerRequest(URL("http://localhost/"));
    req.host("localhost:9000");
    auto hostComponents = req.splitHost;
    hostComponents.host.shouldEqual("localhost");
    hostComponents.port.shouldEqual("9000");

    req.host("example1.com:9000");
    hostComponents = req.splitHost;
    hostComponents.host.shouldEqual("example1.com");
    hostComponents.port.shouldEqual("9000");

    req.host("example2.com.:9000");
    hostComponents = req.splitHost;
    hostComponents.host.shouldEqual("example2.com");
    hostComponents.port.shouldEqual("9000");

    req.host("127.0.0.1");
    hostComponents = req.splitHost;
    hostComponents.host.shouldEqual("127.0.0.1");
    hostComponents.port.shouldEqual("");

    req.host("[::1]");
    hostComponents = req.splitHost;
    hostComponents.host.shouldEqual("[::1]");
    hostComponents.port.shouldEqual("");

    req.host("[::1]:9001");
    hostComponents = req.splitHost;
    hostComponents.host.shouldEqual("[::1]");
    hostComponents.port.shouldEqual("9001");

    req.host("-_-invalid");
    hostComponents = req.splitHost;
    hostComponents[0].shouldEqual("");
    hostComponents[1].shouldEqual("");
}

static foreach (hstsMaxAgeDaysValue; [1, 2])
{
    static foreach (hstsIncludeSubdomainsValue; [true, false])
    {
        static foreach (hstsPreloadValue; [true, false])
        {
            unittest
            {
                // useHstsMiddleware

                import unit_threaded.assertions : shouldEqual;
                import vibe.http.client : requestHTTP;

                void runApp()
                {
                    auto settings = new WebAppSettings;
                    settings.environment = WebAppEnvironment.development;
                    settings.behindSecureProxy = true;
                    settings.allowedHosts[WebAppEnvironment.development] = ["*"];
                    settings.hstsMaxAgeDays = hstsMaxAgeDaysValue;
                    settings.hstsIncludeSubdomains = hstsIncludeSubdomainsValue;
                    settings.hstsPreload = hstsPreloadValue;

                    auto app = new WebApp(settings);
                    app
                    .addRoute("/test/", &doNothingHandler)
                    .addRoute("/stopapp/", &stopApp)
                    .run();
                }

                void testApp()
                {
                    scope(exit) requestHTTP("http://127.0.0.1:9000/stopapp/", (scope req) {}, (scope res) {});

                    string hstsHeaderValue = "max-age=";

                    if (hstsMaxAgeDaysValue == 1)
                        hstsHeaderValue ~= "86400";
                    else if (hstsMaxAgeDaysValue == 2)
                        hstsHeaderValue ~= "172800";

                    if (hstsIncludeSubdomainsValue)
                        hstsHeaderValue ~= "; includeSubDomains";

                    if (hstsPreloadValue)
                        hstsHeaderValue ~= "; preload";

                    // Non-localhost allowed host and valid secure scheme header
                    requestHTTP("http://127.0.0.1:9000/test/", (scope req) {
                        req.host("not localhost");
                        req.headers["X-Forwarded-Protocol"] = "ssl";
                    }, (scope res) {
                        res.headers["Strict-Transport-Security"].shouldEqual(hstsHeaderValue);
                    });
                }

                runTest(&runApp, &testApp);
            }
        }
    }
}

unittest
{
    // useHstsMiddleware - Test that excluded HSTS domains block settings the HSTS header.

    import unit_threaded.assertions : shouldBeNull, shouldEqual;
    import vibe.http.client : requestHTTP;

    void runApp()
    {
        auto settings = new WebAppSettings;
        settings.behindSecureProxy = true;
        settings.allowedHosts[WebAppEnvironment.development] = ["*"];

        auto app = new WebApp(settings);
        app
        .addRoute("/test/", &doNothingHandler)
        .addRoute("/stopapp/", &stopApp)
        .run();
    }

    void testApp()
    {
        scope(exit) requestHTTP("http://127.0.0.1:9000/stopapp/", (scope req) {}, (scope res) {});

        auto settings = new WebAppSettings;

        settings.hstsExcludedHosts.shouldEqual(["127.0.0.1", "localhost", "[::1]"]);

        // Localhost allowed (but HSTS-excluded) host and valid secure scheme header
        requestHTTP("http://127.0.0.1:9000/test/", (scope req) {
            req.host("localhost");
            req.headers["X-Forwarded-Protocol"] = "ssl";
        }, (scope res) {
            res.headers.get("Strict-Transport-Security").shouldBeNull;
        });
    }

    runTest(&runApp, &testApp);
}

unittest
{
    // useHstsMiddleware - Test that WebAppSettings.hstsMaxAgeDays must be greater than zero.

    import potcake.core.exceptions : ImproperlyConfigured;
    import unit_threaded.assertions : shouldThrowWithMessage;

    auto settings = new WebAppSettings;

    settings.hstsMaxAgeDays = 0;

    auto app = new WebApp(settings);
    app
    .run()
    .shouldThrowWithMessage!ImproperlyConfigured(
        "'hstsMaxAgeDays' must be greater than zero."
    );
}
