module potcake.web.middleware;
@safe:

import potcake.web.app : WebApp;
import std.typecons : Tuple;
import vibe.http.server : HTTPServerRequest, HTTPServerRequestDelegate, HTTPServerResponse;

/**
   Harden the browser environment your web app is rendered in.

   Instruct browsers to:
    - Protect users against malicious user-generated content hosted by your app.
    - Only submit referrer information when following links in your app's domain
    - Isolate your app's context from those of 3rd party sites.

   Required WebAppSettings:
    - contentTypeNoSniff - true when "X-Content-Type-Options" = "nosniff" should be added to response headers
    - referrerPolicy - value for the "Referrer-Policy" header.
    - crossOriginOpenerPolicy - value for the "Cross-Origin-Opener-Policy" header.
 */
WebApp useBrowserHardeningMiddleware(WebApp webApp)
{
    import potcake.web.app : getSetting;

    auto contentTypeNoSniff = (() @trusted => getSetting("contentTypeNoSniff").get!bool)();
    auto referrerPolicy = (() @trusted => getSetting("referrerPolicy").get!string)();
    auto crossOriginOpenerPolicy = (() @trusted => getSetting("crossOriginOpenerPolicy").get!string)();

    HTTPServerRequestDelegate browserHardeningMiddleware(HTTPServerRequestDelegate next)
    {
        void middlewareDelegate(HTTPServerRequest req, HTTPServerResponse res)
        {
            // Instruct browsers to protect users against malicious user-generated content hosted by your app.
            // Not needed for some modern browsers.
            // https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/X-Content-Type-Options
            if (contentTypeNoSniff)
                res.headers["X-Content-Type-Options"] = "nosniff";

            // Instruct browswers only to submit referrer information for when following links in your app's domain.
            // https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Referrer-Policy
            if (0 < referrerPolicy.length)
                res.headers["Referrer-Policy"] = referrerPolicy;

            // Instruct browsers to isolate your app's context from those of 3rd party sites.
            // https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Cross-Origin-Opener-Policy
            if (0 < crossOriginOpenerPolicy.length)
                res.headers["Cross-Origin-Opener-Policy"] = crossOriginOpenerPolicy;

            next(req, res);
        }

        return &middlewareDelegate;
    }

    webApp.addMiddleware(&browserHardeningMiddleware);

    return webApp;
}

package const(string[]) getAllowedHosts()
{
    import potcake.web.app : getSetting;

    auto environment = (() @trusted => getSetting("environment").get!(string))();
    auto allowedHosts = (() @trusted => getSetting("allowedHosts").get!(string[][string]))();

    return allowedHosts[environment];
}

package bool isAllowed(string host)
{
    import std.algorithm.searching : any;

    return getAllowedHosts.any!(a => a == "*" || a == host);
}

package alias HostComponents = Tuple!(string, "host", string, "port");

/**
   Parse the host and port components from a request's Host header.

   For reference:
    - https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/host
    - Django's HttpRequest.get_host and http.request.split_domain_port
 */
package HostComponents splitHost(HTTPServerRequest req)
{
    import std.algorithm.searching : endsWith;
    import std.regex : ctRegex, matchFirst;
    import std.uni : toLower;

    string rawHost = req.host.toLower;

    auto hostValidator = ctRegex!(r"^([a-z0-9.-]+|\[[a-f0-9]*:[a-f0-9\.:]+\])(:[0-9]+)?$");

    if (rawHost.matchFirst(hostValidator).empty)
        return HostComponents("", "");

    // IPv6
    if (rawHost.endsWith("]"))
        return HostComponents(rawHost, "");

    // Guaranteed host with port here.
    ulong delimiterIndex = -1;

    // Python's rsplit would be great here.
    foreach_reverse(i, c; rawHost)
    {
        if (c == ':')
        {
            delimiterIndex = i;
            break;
        }
    }

    string host;
    string port;

    if (delimiterIndex == -1)
        host = rawHost;
    else
    {
        host = rawHost[0..delimiterIndex];
        port = rawHost[delimiterIndex+1..$];
    }

    if (host.endsWith("."))
        host = host[0..$-1];

    return HostComponents(host, port);
}

package void validateHost(HTTPServerRequest req)
{
    import potcake.core.exceptions : DisallowedHost;

    auto hostComponents = req.splitHost;

    if (hostComponents.host.isAllowed)
    {
            (() @trusted => req.context["hostComponents"] = hostComponents)();
        return;
    }

    throw new DisallowedHost("Invalid Host header. Add '" ~ hostComponents.host ~ "' to WebAppSettings.allowedHosts.");
}

/**
   Record on request whether it was delivered via a secure channel.

   A request's channel is considered secure when:
    - vibe.d directly facilitated the HTTPS channel for the request.
    - The request was delivered to a trusted proxy via HTTPS (WebAppSettings.behindSecureProxy = true).
        - Request's host must exist in WebAppSettings.allowedHosts.
        - Requests must have a header/value combo in WebAppSettings.secureSchemeHeaders.
            - Where there are multiple secure header/value combos all must be in WebAppSettings.secureSchemeHeaders.
 */
WebApp useIsSecureRequestMiddleware(WebApp webApp)
{
    import potcake.web.app : getSetting;
    import std.array : byPair;
    import vibe.core.log : logDebug;

    auto behindSecureProxy = (() @trusted => getSetting("behindSecureProxy").get!(bool))();
    auto secureSchemeHeaders = (() @trusted => getSetting("secureSchemeHeaders").get!(string[string]))();

    bool isSecure(HTTPServerRequest req)
    {
        // Called before checking `req.tls = true` so that proxied and directly delivered requests are both checked.
        req.validateHost;

        if (req.tls)
        // Directly serving requests with vibe.d with TLS.
            return true;

        if (!behindSecureProxy)
            return false;

        bool requestSecure = false;

        foreach (schemeHeader; secureSchemeHeaders.byPair())
        {
            if ((schemeHeader.key in req.headers) is null)
                continue;

            logDebug(
                "useIsSecureRequestMiddleware schemeHeader: %s: %s",
                schemeHeader.key,
                req.headers.get(schemeHeader.key)
            );

            if (req.headers.get(schemeHeader.key) != schemeHeader.value)
            {
                requestSecure = false;
                break;
            }

            requestSecure = true;
        }

        logDebug("useIsSecureRequestMiddleware requestSecure: %s", requestSecure);

        return requestSecure;
    }

    HTTPServerRequestDelegate isSecureRequestMiddleware(HTTPServerRequestDelegate next)
    {
        void middlewareDelegate(HTTPServerRequest req, HTTPServerResponse res)
        {
                (() @trusted => req.context["isSecure"] = isSecure(req))();
            next(req, res);
        }

        return &middlewareDelegate;
    }

    webApp.addMiddleware(&isSecureRequestMiddleware);

    return webApp;
}

/**
   Inform browsers that your app should only be visited via HTTPS.

   https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Strict-Transport-Security

   Required WebAppSettings:
    - hstsMaxAgeDays
    - hstsIncludeSubdomains
    - hstsPreload
    - hstsExcludedHosts
 */
WebApp useHstsMiddleware(WebApp webApp)
{
    import core.time : days, seconds;
    import potcake.core.exceptions : ImproperlyConfigured;
    import potcake.web.app : getSetting;
    import std.algorithm.searching : any;
    import std.conv : to;
    import std.exception : enforce;
    import vibe.core.log : logTrace;

    auto hstsMaxAgeDays = (() @trusted => getSetting("hstsMaxAgeDays").get!uint)();
    auto hstsIncludeSubdomains = (() @trusted => getSetting("hstsIncludeSubdomains").get!bool)();
    auto hstsPreload = (() @trusted => getSetting("hstsPreload").get!bool)();
    auto hstsExcludedHosts = (() @trusted => getSetting("hstsExcludedHosts").get!(string[]))();

    enforce!ImproperlyConfigured(
        0 < hstsMaxAgeDays,
        "'hstsMaxAgeDays' must be greater than zero."
    );

    string strictTransportSecurityValue = "max-age=" ~ hstsMaxAgeDays.days.total!"seconds".to!string;

    if (hstsIncludeSubdomains)
        strictTransportSecurityValue ~= "; includeSubDomains";

    if (hstsPreload)
        strictTransportSecurityValue ~= "; preload";

    bool validForHsts(string host)
    {
        return !hstsExcludedHosts.any!(a => a == host);
    }

    HTTPServerRequestDelegate hstsMiddleware(HTTPServerRequestDelegate next)
    {
        void middlewareDelegate(HTTPServerRequest req, HTTPServerResponse res)
        {
            auto requestIsSecure = (() @trusted => req.context["isSecure"].get!(const(bool)))();
            auto host = (() @trusted => req.context["hostComponents"].get!(const(HostComponents)))().host;

            if (requestIsSecure && validForHsts(host))
            {
                res.headers["Strict-Transport-Security"] = strictTransportSecurityValue;
                logTrace("Set HSTS header on response");
            }

            next(req, res);
        }

        return &middlewareDelegate;
    }

    webApp.addMiddleware(&hstsMiddleware);

    return webApp;
}

/**
   Adds the ability to route a request to a handler. Must be used with and called before useHandlerMiddleware.

   This middleware selects a handler based on the URL path requested but does not call the handler.
   useHandlerMiddleware covers that responsibility. Routing and handling are split to allow adding
   pre-routing and pre-handling middleware.
 */
WebApp useRoutingMiddleware(WebApp webApp)
{
    webApp.useRoutingMiddleware();
    return webApp;
}

/**
   Calls a selected handler after routing. Must be used with and called after useRoutingMiddleware.

   This middleware calls the handler selected for a given handler by useRoutingMiddleware.
   Routing and handling are split to allow adding pre-routing and pre-handling middleware.
 */
WebApp useHandlerMiddleware(WebApp webApp)
{
    webApp.useHandlerMiddleware();
    return webApp;
}

/**
   Serves static files.

   Serves files from WebAppSettings.rootStaticDirectory at the path prefix WebAppSettings.staticRoutePath.
   Shortcuts later middleware if a static file is served.
 */
WebApp useStaticFilesMiddleware(WebApp webApp)
{
    import potcake.core.exceptions : ImproperlyConfigured;
    import potcake.web.app : getSetting;
    import std.exception : enforce;
    import std.regex : matchAll;
    import std.string : stripRight;
    import vibe.http.fileserver : HTTPFileServerSettings, serveStaticFiles;
    import vibe.http.common : HTTPMethod;
    import vibe.core.log : logDebug;

    auto staticRoutePath = (() @trusted => getSetting("staticRoutePath").get!string)();
    auto rootStaticDirectory = (() @trusted => getSetting("rootStaticDirectory").get!string)();

    enforce!ImproperlyConfigured(
        0 < rootStaticDirectory.length &&
        0 < staticRoutePath.length,
        "The 'rootStaticDirectory', 'staticRoutePath' settings must be set to serve static files."
    );

    auto routePathPrefix = staticRoutePath.stripRight("/");
    auto settings = new HTTPFileServerSettings(routePathPrefix);
    auto staticHandler = serveStaticFiles(rootStaticDirectory, settings);
    auto routePath = routePathPrefix ~ "<path:static_file_path>";
    auto routeRegexPath = webApp.getRegexPath(routePath, true);

    HTTPServerRequestDelegate staticFilesMiddleware(HTTPServerRequestDelegate next)
    {
        logDebug("staticFilesMiddleware added");

        void middlewareDelegate(HTTPServerRequest req, HTTPServerResponse res)
        {
            logDebug("staticFilesMiddleware started, req.requestURI: %s", req.requestURI);

            if (req.method == HTTPMethod.GET && !(req.requestURI.matchAll(routeRegexPath).empty()))
            {
                staticHandler(req, res);
                logDebug("staticFilesMiddleware ended, files served");
                return;
            }

            next(req, res);
            logDebug("staticFilesMiddleware ended, no files served");
        }

        return &middlewareDelegate;
    }

    webApp.addMiddleware(&staticFilesMiddleware);

    return webApp;
}
