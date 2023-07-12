@safe:

import potcake.web;

int main()
{
    auto settings = new WebAppSettings;
    settings.rootStaticDirectory = "static";
    settings.staticRoutePath = "/static/";

    auto webApp = new WebApp(settings);
    webApp
    .addRoute("/", &handler)
    .serveStaticFiles();

    return webApp.run();
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
