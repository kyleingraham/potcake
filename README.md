# Potcake
An easy to live with, sensible, and dependable web framework built on [vibe.d](https://vibed.org/).

Potcake endeavours to:
- Provide safe and sane defaults
- Be easy to use how you want or with our opinionated structure
- Provide useful components that prevent re-inventing the wheel

## Examples
If you would like to see Potcake in action before reading further, take a look at the [examples](examples) folder. There
you will find demonstration apps for Potcake's features.

Each can be run by cloning this repo, navigating to the example app's base, and running `dub run` 
(on macOS `MACOSX_DEPLOYMENT_TARGET=11 dub run`).

[collect_static_files](examples/collect_static_files)

Demonstrates:
- Adding multiple route handlers at once and static file serving.
- Specifying typed URL handlers. 
- Collection of static files from multiple source directories into a single runtime directory using the 
relevant settings (`staticDirectories`, `rootStaticDirectory`, `staticRoutePath`) and `--collectstatic` file collection.
- Use of `staticPath` for linking to files in the runtime static directory for both inline and DIET templates.

[static_files](examples/static_files)

Demonstrates:
- Adding route handlers and static file serving.
- Serving static files from a single directory.

## Web Framework

### URL Dispatching
Potcake implements [Django's](https://www.djangoproject.com/) URL dispatching system.

```d
@safe:

import potcake.web;

int main()
{
    auto webApp = new WebApp;
    webApp
    .addRoute("/hello/<name>/<int:age>/", &helloUser);

    return webApp.run();
}

void helloUser(HTTPServerRequest req, HTTPServerResponse res, string name, int age)
{
    import std.conv : to;
    import vibe.http.status : HTTPStatus;

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

Potcake uses D's flexibility to implement key components of Django's URL dispatching system. The end result is a
blending of the ergonomics available in Django with the superior runtime performance of D.

Key components of Django's [URL dispatching system](https://docs.djangoproject.com/en/dev/topics/http/urls/#url-dispatcher) are:
- The URL path expression scheme
- The ability to extend the path expression scheme through path converters

#### URL Path Expression Scheme
Django allows the developer to [specify values to be captured](https://docs.djangoproject.com/en/dev/topics/http/urls/#example).
This is similar to functionality available in most web frameworks (including vibe.d). Identifiers in angle brackets will be used to extract
values from matched paths. Those values are then made available to handlers as strings. After matching the following
example path on structure, Django would make `name` and `age` string values available to the path's associated handler:

```python
"/hello/<name>/<age>/"
```

Where things get interesting is Django's URL path expression scheme's path converters.

#### Path Converters
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

#### potcake.http.router.Router
Potcake provides `Router` (used internally by `WebApp`) which is a vibe.d router that understands Django's URL path expression scheme.
Paths are parsed at run-time using built-in or user-provided path converters. Built-in path converters match
[Django's built-in set](https://docs.djangoproject.com/en/dev/topics/http/urls/#path-converters). User-specified path
converters must first be defined as `@safe` structs with the following properties:

- An `enum` member named `regex` with a regex character class representing strings to match against within a requested path.
- A `toD` function that accepts a `const string`. The return type can be any desired outside `void`. This function converts strings to the type produced by the path converter.
- A `toPath` function with a parameter of the path converters type that returns a `string`.

##### User-defined Path Converter Example

```d
import potcake.web;

@safe struct NoNinesIntConverter
{
    import std.conv : to;

    enum regex = "[0-8]+"; // Ignores '9'

    int toD(const string value)
    {
        // Overflow handling left out for simplicity.
        return to!int(value);
    }

    string toPath(int value)
    {
        return to!string(value);
    }
}

int main()
{
    auto webApp = new WebApp([
        pathConverter("nonines", NoNinesIntConverter())
    ])
    .addRoute("/hello/<name>/<nonines:age>/", &helloUser);

    return webApp.run();
}

void helloUser(HTTPServerRequest req, HTTPServerResponse res, string name, int age) @safe {
    import std.conv : to;
    import vibe.http.status : HTTPStatus;

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

##### Handlers
Handlers given to `Router` via `WebApp` should at the very least return `void` and accept an
`HTTPServerRequest` and an `HTTPServerResponse`. Values extracted from the request's path are saved to
`HTTPServerRequest.params` as strings.

If the parameter signature for a handler is extended with the types returned by its path's path converters then
`Router` will additionally use the path converters' `toD` functions to pass converted values to the handler.

### URL Reversing
Potcake provides a utility function for producing absolute URL paths at `potcake.web.reverse`. It allows you to define
route path specifics in one place while using those paths anywhere in your code base. If you make a change to the central
definition, all usages of that definition will be updated.

For example, given the following route definition:

```d
webApp.addRoute("/hello/<name>/<int:age>/", &helloUser, "hello");
```

you can reverse the definition like so:

```d
reverse("hello", "Potcake", 2);
```

producing the following URL path:

```d
"/hello/Potcake/2/"
```

### Static Files
Potcake offers two ways to organize your static files (e.g. images, JavaScript, CSS):
1. In a central directory
2. In multiple directories e.g. a directory per package in a larger project.

#### Central Directory
1. Choose one directory in your project for storing all static files.
2. Set `WebAppSettings.rootStaticDirectory` to the relative path to your static directory from your compiled executable. You will need to deploy this directory alongside your executable.
3. Set `WebAppSettings.staticRoutePath` to the URL to use when referring to static files e.g. "/static/".
4. Use `potcake.web.staticPath` to build URLs for static assets.
5. Call `WebApp.serveStaticfiles()` before running your app.

See [static_files](examples/static_files) for a demonstration.

#### Multiple directories
1. Store your static files in directories throughout your project (in the future we hope to use this to make it possible to build libraries that carry their own static files and templates).
2. Set `WebAppSettings.staticDirectories` to the relative paths to your static directories from your compiled executable.
3. Set `WebAppSettings.rootStaticDirectory` to directory that all of your static files should be collected. You will need to deploy this directory alongside your executable. When files are collected we use a merge strategy. In the future we hope to use this to make it easy to overwrite a library's static files with your own.
4. Set `WebAppSettings.staticRoutePath` to the URL to use when referring to static files e.g. "/static/".
5. Use `potcake.web.staticPath` to build URLs for static assets.
6. Call `WebApp.serveStaticfiles()` before running your app.
7. Add the following lines to your dub file and setup your main entry point function to accept program arguments. Pass these arguments to `WebApp.run`.
```d
postBuildCommands "\"$DUB_TARGET_PATH\\$DUB_ROOT_PACKAGE_TARGET_NAME\" --collectstatic" platform="windows"
postBuildCommands "\"$DUB_TARGET_PATH/$DUB_ROOT_PACKAGE_TARGET_NAME\" --collectstatic" platform="posix"
```

See [collect_static_files](examples/collect_static_files) for a demonstration.

### Middleware
Potcake provides a framework for middleware. Any middleware provided is run after a request has been routed.

To add middleware, create a `MiddlewareDelegate`. A `MiddlewareDelegate` should accept and call a 
`HTTPServerRequestDelegate` that represents the next middleware in the chain. A middleware can carry out actions both
before and after the next middleware has been called. A `MiddlewareDelegate` should return a 
`HTTPServerRequestDelegate` that can be called by the middleware prior to it.

For example:

```d
import potcake.web;

HTTPServerRequestDelegate middleware(HTTPServerRequestDelegate next)
{
    void middlewareDelegate(HTTPServerRequest req, HTTPServerResponse res)
    {
        // Run actions prior to the next middleware.
        next(req, res);
        // Run actions after the next middleware.
    }

    return &middlewareDelegate;
}

int main()
{
    auto webApp = new WebApp;
    webApp
    .addRoute("/", delegate void(HTTPServerRequest req, HTTPServerResponse res) {})
    .addMiddleware(&middleware);

    return webApp.run();
}
```

## Settings
On initial setup, a Potcake `WebApp` accepts a settings class in the family of `WebAppSettings`. `WebAppSettings` has
settings core to Potcake with the framework's defaults. 

You can add your own settings by subclassing `WebAppSettings` and adding your own fields. 

Potcake provides a way to access your settings at runtime from anywhere in your program in `getSetting`.

For example:

```d
import potcake.web;

class MySettings : WebAppSettings
{
    string mySetting = "my setting";
}

int main()
{
    auto webApp = new WebApp(new MySettings);
    webApp
    .addRoute("/", delegate void(HTTPServerRequest req, HTTPServerResponse res) {
        auto setting = (() @trusted => getSetting("mySetting").get!string)();
    });

    return webApp.run();
}
```

## FAQ
Q - Why the name Potcake?

A - I am from The Bahamas where Potcakes are a breed of dog. They are easy to live with, sensible in their decision-making,
and dependable. All great aspirational qualities for a web framework.


## Roadmap
- Middleware
    - [x] Middleware system
    - Convenience middleware
        - [x] Static files
        - [ ] CORS
    - [x] Post-routing middleware
    - [ ] Health-check endpoint middleware
- Matching the API for vibe.d's `URLRouter`
    - [ ] Set of valid handler signatures
    - [ ] Handler registration functions e.g. `post`
    - [ ] Per-router path prefixes