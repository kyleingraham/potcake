import std.stdio : writeln;
import std.typecons : Tuple;


class Converter
{
	abstract void sayHello(){}
}


class StringConverter : Converter
{
	override void sayHello()
	{
		writeln("Hello from " ~ typeof(this).stringof ~ "!");
	}
}

// Error: variable <variable name> : Unable to initialize enum with class or pointer to struct. Use static const variable instead.
// Conflicts with:
// 	https://dlang.org/spec/expression.html#associative_array_literals
// 	An AssocArrayLiteral cannot be used to statically initialize anything.

struct PathConverterDetails
{
	string moduleName;
	string converterName;
	string typeName;
}

template PathConverter(alias converter, string typeName)
{
	import std.traits : moduleName;
	import std.typecons : tuple;
	
	enum PathConverter =  PathConverterDetails(moduleName!converter, __traits(identifier, converter), typeName);
}

enum frameworkConverters = [
	PathConverter!(StringConverter, "slug")
];

enum myConverters = [
	PathConverter!(StringConverter, "string"),
	PathConverter!(StringConverter, "int")
];

// The framework should be the only one to call this.
template registerConverters(PathConverters...)
{
	import std.algorithm.iteration : joiner;
	import std.array : array;
	import std.range : only;
	
	enum registerConverters = PathConverters.only.joiner.array;
}

enum allConverters = registerConverters!(myConverters, frameworkConverters);

class ConverterNotFoundException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

PathConverterDetails getConverter(string typeName)()
{
	foreach(pathConverterDetails; allConverters)
	{
		if (pathConverterDetails.typeName == typeName)
			return pathConverterDetails;
	}
	
	throw new ConverterNotFoundException("No converter found for type name '" ~ typeName ~ "'");
}

template callDummy()
{
	void callDummy()
	{
		// Django converts 'foo/<int:pk>' to '^foo\\/(?P<pk>[0-9]+)' and {'pk': <django.urls.converters.IntConverter>}
		
		mixin("import " ~ getConverter!"slug".moduleName ~ " : " ~ getConverter!"slug".converterName ~ ";");
		mixin("auto " ~ getConverter!"slug".typeName ~ getConverter!"slug".converterName ~ " = new " ~ getConverter!"slug".converterName ~ "();");
		mixin(getConverter!"slug".typeName ~ getConverter!"slug".converterName ~ ".sayHello;");
	}
}

void main()
{
	writeln(allConverters);
	callDummy;
}
