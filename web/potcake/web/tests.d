module web.potcake.web.tests;
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
    Thread.sleep(dur!"msecs"(500));

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

        auto app = new WebApp;
        app.serveStaticFiles("/static", staticFile.dirName.absolutePath);
        app.addRoute("/stopapp/", &stopApp);
        app.run();
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

        app.serveStaticFiles();
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
