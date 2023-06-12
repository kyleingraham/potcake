@safe:

import potcake.web;

int main(string[] args)
{
    auto settings = new WebAppSettings;
    settings.staticDirectories = ["static_a", "static_b"];
    settings.rootStaticDirectory = "staticroot";
    settings.staticRoutePath = "/static";

    auto webApp = new WebApp(settings);
    webApp
    .addRoute("/", &handler)
    .addRoute("/diet/<int:num>", &dietHandler)
    .serveStaticFiles();

    return webApp.run(args);
}

void handler(HTTPServerRequest req, HTTPServerResponse res)
{
    import vibe.http.status : HTTPStatus;

    res.writeBody(`
<!DOCTYPE html>
<html lang="en">
    <head>
        <meta charset="utf-8" />
        <title>Collect Static Files Example</title>
        <link rel="stylesheet" href="` ~ staticPath("css/styles_a.css") ~ `" />
        <link rel="stylesheet" href="` ~ staticPath("css/styles_b.css") ~ `" />
    </head>
    <body>
        <h1>This text should be red...</h1>
        <h2>...and this text should be green.</h2>
    </body>
</html>`, HTTPStatus.ok, "text/html; charset=utf-8");
}

void dietHandler(HTTPServerRequest req, HTTPServerResponse res, int num)
{
    res.render!("templates/test.dt", num);
}
