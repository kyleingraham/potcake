# typed-router
A [vibe.d](https://vibed.org/) router that implements [Django's](https://www.djangoproject.com/) URL dispatching system.

```d
import potcake;

import vibe.core.core : runApplication;
import vibe.http.server : HTTPServerSettings, listenHTTP;
import vibe.http.status : HTTPStatus;

int main()
{
    auto router = new Router!();
    router.get!"/hello/<name>/<int:age>/"(&helloUser);

    auto settings = new HTTPServerSettings;
    settings.bindAddresses = ["127.0.0.1"];
    settings.port = 9000;

    auto listener = listenHTTP(settings, router);
    scope (exit)
    listener.stopListening();

    return runApplication();
}

void helloUser(HTTPServerRequest req, HTTPServerResponse res, string name, int age) @safe
{
    import std.conv : to;

    res.contentType = "text/html; charset=UTF-8";
    res.writeBody(`
<!DOCTYPE html>
<html lang="en">
    <head></head>
    <body>
        Hello, ` ~ name ~ `. You are ` ~ to!string(age) ~ ` years old.
    </body>
</html>`,
    HTTPStatus.ok);
}
```

## Details
typed-router uses D's flexibility to implement key components of Django's URL dispatching system. The end result is a
blending of the ergonomics available in Django with the, to me, superior development experience of D.

Key components of Django's [URL dispatching system](https://docs.djangoproject.com/en/dev/topics/http/urls/#url-dispatcher) are:
- The URL path expression scheme
- The ability to extend the path expression scheme through path converters

### URL Path Expression Scheme
Django allows the developer to [specify values to be captured](https://docs.djangoproject.com/en/dev/topics/http/urls/#example).
This is similar to functionality available in most web frameworks (including vibe.d). Identifiers in angle brackets will be used to extract
values from matched paths. Those values are then made available to handlers as strings. After matching the following
example path on structure, Django would make `name` and `age` string values available to the path's associated handler:

```python
"/hello/<name>/<age>/"
```

Where things get interesting is Django's URL path expression scheme's path converters.

### Path Converters
Captured value specifications can optionally include a path converter. Path converters influence both how their portion
of the path is matched when routing, and the type of value passed to an associated handler. Take the following path as
an example:

```python
"/hello/<name>/<int:age>/"
```

`name` has no path converter and so would be matched as a string. `age` on the other hand has the `int` path converter
which matches against integers and passes an integer value to the path's handler. A request to `/hello/ash/12/` would
match against this path while a request to `/hello/ash/twelve/` would not.

Behind the scenes, path converters are objects that:
- Hold a regex pattern for values they match against
- Understand how to convert string values to the path converter's return type

### TypedURLRouter
typed-router provides `TypedURLRouter` which is a vibe.d router that understands Django's URL path expression scheme.
Paths are parsed at compile-time using built-in or user-provided path converters. Built-in path converters match
[Django's built-in set](https://docs.djangoproject.com/en/dev/topics/http/urls/#path-converters). User-specified path
converters must first be defined as structs with the following properties:

- An `enum` member named `regex` with a regex character class representing strings to match against within a requested path.
- A `@safe` `toD` function that accepts a `const string`. The return type can be any desired outside `void`. This function converts strings to the type produced by the path converter.

#### User-defined Path Converter Example

```d
import potcake;

import vibe.core.core : runApplication;
import vibe.http.server : HTTPServerSettings, listenHTTP;
import vibe.http.status : HTTPStatus;

struct NoNinesIntConverter
{
    enum regex = "[0-8]+"; // Ignores '9'

    int toD(const string value) @safe
    {
        import std.conv : to;

        return to!int(value);
    }
}

int main()
{
    auto router = new Router!([bindPathConverter!(NoNinesIntConverter, "nonines")]);
    router.get!"/hello/<name>/<nonines:age>/"(&helloUser);

    auto settings = new HTTPServerSettings;
    settings.bindAddresses = ["127.0.0.1"];
    settings.port = 9000;

    auto listener = listenHTTP(settings, router);
    scope (exit)
    listener.stopListening();

    return runApplication();
}

void helloUser(HTTPServerRequest req, HTTPServerResponse res, string name, int age) @safe {
    import std.conv : to;

    res.contentType = "text/html; charset=UTF-8";
    res.writeBody(`
<!DOCTYPE html>
<html lang="en">
    <head></head>
    <body>
        Hello, ` ~ name ~ `. You are ` ~ to!string(age) ~ ` years old.
    </body>
</html>`,
    HTTPStatus.ok);
}
```

#### Handlers
Handlers given to `TypedURLRouter` (like with `URLRouter`) should at the very least return `void` and accept an
`HTTPServerRequest` and an `HTTPServerResponse`. Values extracted from the request's path are saved to
`HTTPServerRequest.params` as strings.

If the parameter signature for a handler is extended with the types returned by its path's path converters then
`TypedURLRouter` will additionally use the path converters' `toD` functions to pass converted values to the handler.


## Roadmap
- Middleware
    - [x] Middleware system
    - Convenience middleware
        - [ ] Static files
        - [ ] CORS
    - [ ] Post-routing middleware
    - [ ] Health-check endpoint middleware
    - [ ] Class-based middleware
- Matching the API for vibe.d's `URLRouter`
    - [ ] Set of valid handler signatures
    - [ ] Handler registration functions e.g. `post`
    - [ ] Per-router path prefixes