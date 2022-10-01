module typed_router.tests;

import typed_router.router : bindPathConverter, isValidHandler, TypedURLRouter;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

// This converter must be placed in a module separate to TypedURLConverter to ensure no regression in being able to use
// converters defined outside of the router's.
package struct TestStringConverter
{
    enum regex = "[^/]+";

    string toD(const string value) @safe
    {
        return "PASS";
    }
}

unittest
{
    // Do we prioritize user path converters that override built-ins?
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    void testHandler(HTTPServerRequest req, HTTPServerResponse res, string name)
    {
        assert(name == "PASS", "Used built-in 'string' path converter instead of user-supplied converter");
    }

    auto router = new TypedURLRouter!([bindPathConverter!(TestStringConverter, "string")]);
    router.get!"/hello/<string:name>/"(&testHandler);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/hello/FAIL/")), res);
}

unittest
{
    // Do we match against URLs with:
    //  - multiple path converters
    //  - one path converter
    //  - no path converters
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "A";
    }
    void b(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "B";
    }
    void c(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "C";
    }
    void d(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "D";
    }

    auto router = new TypedURLRouter!();
    router.get!"/make/<string:model>/model/<int:make>/"(&a);
    router.get!"/<int:value>/"(&b);
    router.get!"/<int:value>"(&c);
    router.get!"/no/path/converters/"(&d);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/")), res);
    assert(result == "", "Matched for non-existent '/' path");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/make/porsche/model/911/")), res);
    assert(result == "A", "Did not match GET with multiple path converter types");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/make/porsche/model/taycan/")), res);
    assert(result == "A", "Did not block GET match on 'int' type");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/1/")), res);
    assert(result == "AB", "Did not match trailing '/'");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/1")), res);
    assert(result == "ABC", "Did not match without trailing '/'");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/no/path/converters/")), res);
    assert(result == "ABCD", "Did not match when no path converters present");
}

unittest
{
    // Do we set 'string' as the default path converter when non is specified?
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "A";
    }

    auto router = new TypedURLRouter!();
    router.get!"/make/<string:model>/model/<make>/"(&a);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/make/porsche/model/911/")), res);
    assert(result == "A", "Did not set path converter to 'string' when no type specified");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/make/porsche/model/taycan/")), res);
    assert(result == "AA", "Did not match against string using default 'string' converter");
}

unittest
{
    // Do we save path values to request.params and convert them for use when calling handlers?
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    void a(HTTPServerRequest req, HTTPServerResponse res)
    {
        assert(req.params["id"] == "123456", "Did not save path value to request params");
    }

    void b(HTTPServerRequest req, HTTPServerResponse res, int id)
    {
        assert(req.params["id"] == "123456", "Did not save path value to request params");
        assert(id == 123456, "Did pass path value to handler");
    }

    auto router = new TypedURLRouter!();
    router.get!"/a/<int:id>/"(&a);
    router.get!"/b/<int:id>/"(&b);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/a/123456/")), res);
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/b/123456/")), res);
}

unittest
{
    // IntConverter
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res, int value)
    {
        result ~= "A";
    }

    auto router = new TypedURLRouter!();
    router.get!"/<int:value>/"(&a);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/1/")), res);
    assert(result == "A", "Did not match 'int' path converter");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/one/")), res);
    assert(result == "A", "Matched with non-integer value");
}

unittest
{
    // SlugConverter
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res, string slug)
    {
        result ~= "A";
    }

    auto router = new TypedURLRouter!();
    router.get!"/<slug:value>/"(&a);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/slug-string/")), res);
    assert(result == "A", "Did not match 'slug' path converter");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/non~slug~string/")), res);
    assert(result == "A", "Matched with non-slug value");
}

unittest
{
    // UUIDConverter
    import std.uuid : UUID;
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res, UUID value)
    {
        result ~= "A";
    }

    auto router = new TypedURLRouter!();
    router.get!"/<uuid:value>/"(&a);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/1234abcd-1234-abcd-1234-abcd1234abcd/")), res);
    assert(result == "A", "Did not match 'uuid' path converter");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/1234ABCD-1234-ABCD-1234-ABCD1234ABCD/")), res);
    assert(result == "A", "Matched with non-uuid value");
}

unittest
{
    // StringConverter & URLPathConverter
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res, string value)
    {
        result ~= "B";
    }

    void b(HTTPServerRequest req, HTTPServerResponse res, string value)
    {
        import std.format : format;

        string expectedValue = "some/valid/path";
        assert(value == expectedValue, format("Path not parsed correctly. Expected '%s' but got '%s'.", expectedValue, value));
        result ~= "A";
    }

    auto router = new TypedURLRouter!();
    router.get!"/<string:value>/"(&a);
    router.get!"/<path:value>/"(&b);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/some/valid/path/")), res);
    assert(result == "A", "Did not match 'path' path converter");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/some-valid-path/")), res);
    assert(result == "AB", "Did not match with 'string' path converter");
}

unittest
{
    // Do we block invalid handlers?
    void handler(HTTPServerRequest req, HTTPServerResponse res) {}

    class HandlerClass
    {
        void handler(HTTPServerRequest req, HTTPServerResponse res) {}
    }

    void typedHandler(HTTPServerRequest req, HTTPServerResponse res, int value) {}

    void test(Handler)(Handler handler)
    {
        static assert(isValidHandler!Handler);
    }

    test(&handler);
    test(&(HandlerClass.handler));
    test(&typedHandler);
    static assert(!isValidHandler!(void function(int value)));
    static assert(!isValidHandler!(void function(HTTPServerRequest req)));
    static assert(!isValidHandler!(void function(HTTPServerResponse res)));
    static assert(!isValidHandler!(int function(HTTPServerResponse res, HTTPServerResponse res)));
}

unittest
{
    // Do we stop calling handlers after calling the first-matched handler?
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "A";
    }

    void b(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "B";
    }


    auto router = new TypedURLRouter!();
    router.get!"/<string:value>/"(&a);
    router.get!"/<string:value>/"(&b);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/value/")), res);
    assert(result == "A", "Called additional handler after first-matched handler");
}
