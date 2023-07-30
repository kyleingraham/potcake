module potcake.web.utils;
@safe:

/**
 * Get an environment variable and optionally convert it a given type.

   When given [bool] as the conversion type the following applies:
     - True values are "y", "yes", "t", "true", "on", and "1"
     - False values are "n", "no", "f", "false", "off", and "0"
     - Environment variable comparison is case-insensitive
     - ConvException is thrown when conversion fails
 */
T getEnvironmentVariable(T = string)(scope const(char)[] name, string defaultValue = null)
{
    import std.conv : ConvException;
    import std.process : environment;

    string value = environment.get(name, defaultValue);

    static if (is(T : bool))
    {
        import std.algorithm.comparison : equal;
        import std.algorithm.searching : any;
        import std.uni : toLower;

        string lowerValue = value.toLower;

        auto predicate = (string a) => lowerValue.equal(a);

        if (any!(predicate)(["y", "yes", "t", "true", "on", "1"]))
            return true;
        else if (any!(predicate)(["n", "no", "f", "false", "off", "0"]))
            return false;
        else
            throw new ConvException("'" ~ value ~ "' could not be converted to a bool");

    } else
    {
        import std.conv : to;

        return to!T(value);
    }
}

///
unittest
{
    import std.conv : ConvException;
    import std.process : environment;
    import unit_threaded.assertions : shouldEqual, shouldThrowWithMessage;

    string potcakeTestVariable = "POTCAKE_TEST_VARIABLE";

    scope(exit) environment[potcakeTestVariable] = null;

    environment[potcakeTestVariable] = "42";
    auto testInt = getEnvironmentVariable!int(potcakeTestVariable);
    testInt.shouldEqual(42);

    environment[potcakeTestVariable] = "production";
    auto testString = getEnvironmentVariable(potcakeTestVariable);
    testString.shouldEqual("production");

    bool testBool;

    foreach (truthyValue; ["y", "yes", "t", "true", "on", "1", "True"])
    {
        environment[potcakeTestVariable] = truthyValue;
        testBool = getEnvironmentVariable!bool(potcakeTestVariable);
        testBool.shouldEqual(true);
    }

    foreach (falseyValue; ["n", "no", "f", "false", "off", "0", "False"])
    {
        environment[potcakeTestVariable] = falseyValue;
        testBool = getEnvironmentVariable!bool(potcakeTestVariable);
        testBool.shouldEqual(false);
    }

    environment[potcakeTestVariable] = "Potcake";
    getEnvironmentVariable!bool(
        potcakeTestVariable
    ).shouldThrowWithMessage!ConvException(
        "'Potcake' could not be converted to a bool"
    );
}
