@safe:

import potcake.web;

int main()
{
    auto webApp = new WebApp;
    webApp
    .addRoute("/", &handler)
    .serveStaticFiles("/static/", "static/");

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
        <link rel="stylesheet" href="/static/css/styles.css" />
    </head>
    <body>
        <h1>This text should be red.</h1>
    </body>
</html>`, HTTPStatus.ok, "text/html; charset=utf-8");
}
