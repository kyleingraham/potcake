@safe:

import potcake.web;

int main()
{
    auto settings = new WebAppSettings;
    // Static files will by default be served from a local directory named 'static' at the route prefix '/static/'.
    // These settings are controlled by WebAppSettings.rootStaticDirectory and WebAppSettings.staticRoutePath
    // respectively. Uncomment the following lines to make adjustments to these settings:
    //
    // settings.rootStaticDirectory = "static";
    // settings.staticRoutePath = "/static/"; // Use `staticPath` in templates to seamlessly update links to match this.

    return new WebApp(settings)
    .addRoute("/", &handler)
    .run();
}

void handler(HTTPServerRequest req, HTTPServerResponse res)
{
    import vibe.http.status : HTTPStatus;

    res.writeBody(`
<!DOCTYPE html>
<html lang="en">
    <head>
        <meta charset="utf-8" />
        <title>Static Files Example</title>
        <link rel="stylesheet" href="` ~ staticPath("css/styles.css") ~ `" />
    </head>
    <body>
        <h1>This text should be red.</h1>
    </body>
</html>`, HTTPStatus.ok, "text/html; charset=utf-8");
}
