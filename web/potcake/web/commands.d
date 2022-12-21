module potcake.web.commands;
@safe:

int collectStaticFilesCommand()
{
    import potcake.web.app : getSetting;
    import std.array : join;
    import std.file : exists, mkdir;
    import std.path : absolutePath, buildPath, isAbsolute;
    import std.process : execute, executeShell;
    import std.string : strip;
    import vibe.core.log : logDebug, logInfo, logFatal;

    auto rootStaticDirectory = (() @trusted => getSetting("rootStaticDirectory").get!string)();
    auto staticDirectories = (() @trusted => getSetting("staticDirectories").get!(string[]))();

    if (rootStaticDirectory.length == 0)
    {
        logFatal("Fatal: The 'rootStaticDirectory' setting must be set to collect static files.");
        return 1;
    }

    if (staticDirectories.length == 0)
    {
        logFatal("Fatal: The 'staticDirectories' setting must be set to collect static files.");
        return 1;
    }

    logInfo("Collecting static files...");

    auto rootStaticDirectoryPath = rootStaticDirectory.isAbsolute ? rootStaticDirectory : rootStaticDirectory.absolutePath;

    if (!rootStaticDirectoryPath.exists)
        rootStaticDirectoryPath.mkdir;

    version(Windows)
    {
        auto pathTerminator = "*";
        auto pathSeparator = ",";
    }
    else
    {
        auto pathTerminator = " "; // Gets us a trailing '/ '. rsync needs a '/' so we remove the ' ' downstream.
        auto pathSeparator = " ";
    }

    string[] paths = [];

    foreach (staticDirectory; staticDirectories)
    {
        auto staticDirectoryPath = staticDirectory.isAbsolute ? staticDirectory : staticDirectory.absolutePath;
        staticDirectoryPath = "'" ~ staticDirectoryPath.buildPath(pathTerminator).strip ~ "'";
        paths ~= staticDirectoryPath;
    }

    auto joinedPaths = paths.join(pathSeparator);

    // TODO: Do these commands prioritize newer files?
    version(Windows)
    {
        auto command = [
            "powershell",
            "Copy-Item",
            "-Path",
            joinedPaths,
            "-Destination",
            "'" ~ rootStaticDirectoryPath ~ "'",
            "-Recurse",
            "-Force"
        ];
        logDebug("Copy command: %s", command);
        auto copyExecution = execute(command);
    }
    else
    {
        auto command = "rsync -a " ~ joinedPaths ~ " '" ~ rootStaticDirectoryPath ~ "'";
        logDebug("Copy command: %s", command);
        auto copyExecution = executeShell(command);
    }

    if (copyExecution.status != 0)
    {
        logFatal("Fatal: Static file collecting failed:\n%s", copyExecution.output);
        return 1;
    }

    logInfo("Collected static files.");
    return 0;
}
