module web.potcake.web.tests;

import potcake.web.app;
import core.thread.osthread : Thread;
import core.time : dur;
import std.concurrency : spawn;
import std.net.curl : get, HTTPStatusException;
import vibe.core.core : exitEventLoop;

void runTest(void function() runAppFunction, void function() testAppFunction)
{
    spawn(runAppFunction);
    Thread.sleep(dur!"msecs"(500));

    try
    {
        testAppFunction();
    } catch (HTTPStatusException e)
    {
        assert(false, e.msg);
    }
}

void nameHandler(HTTPServerRequest req, HTTPServerResponse res, string name) @safe
{
    import vibe.http.status : HTTPStatus;

    res.contentType = "text/html; charset=UTF-8";
    res.writeBody(name, HTTPStatus.ok);
    exitEventLoop();
}

unittest
{
    // Do we add routes via 'addRoute' as expected?
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
        assert(content == expectedName, "Web app did not respond with exptected content.");
    }

    runTest((&runApp).funcptr, (&testApp).funcptr);
}

unittest
{
    // Do we add path converters via 'addPathConverters' as expected?
    struct TestStringConverter
    {
        enum regex = "[^/]+";

        string toD(const string value) @safe
        {
            return "PASS";
        }

        string toPath(const string value) @safe
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
        assert(content == expectedName, "Web app did not pass path converter to router.");
    }

    runTest((&runApp).funcptr, (&testApp).funcptr);
}

unittest
{
    // Do we reverse paths correctly?
    void runApp()
    {
        void reverser(HTTPServerRequest req, HTTPServerResponse res, string routeName) @safe
        {
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
        auto content = get("http://127.0.0.1:9000/hello/reverser/");
        assert(content == "/hello/PASS/", "reverse failed to provided reversed path");
    }

    runTest((&runApp).funcptr, (&testApp).funcptr);
}