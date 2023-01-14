// ldc2 -i=. --d-version=CarelessAlocation -i=std -Iarsd-webassembly/ -L-allow-undefined -ofserver/omg.wasm -mtriple=wasm32-unknown-unknown-wasm arsd-webassembly/core/arsd/aa arsd-webassembly/core/arsd/objectutils arsd-webassembly/core/internal/utf arsd-webassembly/core/arsd/utf_decoding hello arsd-webassembly/object.d

import arsd.webassembly;
import std.stdio;

class A {
	int _b = 200;
	int a() { return 123; }
}

interface C {
	void test();
}
interface D {
	void check();
}

class B : A, C 
{
	int val;
	override int a() { return 455 + val; }

	void test()
	{
		rawlog(a());
		int[] a;
		a~= 1;
	}
}

void rawlog(Args...)(Args a, string file = __FILE__, size_t line = __LINE__)
{
	writeln(a, " at "~ file~ ":", line);
}


struct Tester
{
	int b = 50;
	string a = "hello";
}
void main() 
{
	float[] f = new float[4];
	assert(f[0] is float.init);
	f~= 5.5; //Append
	f~= [3, 4];
	int[] inlineConcatTest = [1, 2] ~ [3, 4];

	auto dg = delegate()
	{
		writeln(inlineConcatTest[0], f[1]);
	};
	dg();
	B b = new B;
	b.val = 5;
	A a = b;
	a.a();
	C c = b;
	c.test();
	assert(cast(D)c is null);
	Tester[] t = new Tester[10];
	assert(t[0] == Tester.init);
	assert(t.length == 10);

	switch("hello")
	{
		case "test":
			writeln("broken");
			break;
		case "hello":
			writeln("Working switch string");
			break;
		default: writeln("What happenned here?");
	}
	string strTest = "test"[0..$];
	assert(strTest == "test");

	
	Tester* structObj = new Tester(50_000, "Inline Allocation");
	writeln(structObj is null, structObj.a, structObj.b);

	int[string] hello = ["hello": 500];
	assert(("hello" in hello) !is null, "No key hello yet...");
	assert(hello["hello"] == 500, "Not 500");
	hello["hello"] = 1200;
	assert(hello["hello"] == 1200, "Reassign didn't work");
	hello["h2o"] = 250;
	assert(hello["h2o"] == 250, "New member");


	int[] appendTest;
	appendTest~= 50;
	appendTest~= 500;
	appendTest~= 5000;
	foreach(v; appendTest)
		writeln(v);
	string strConcatTest;
	strConcatTest~= "Hello";
	strConcatTest~= "World";
	writeln(strConcatTest);
	int[] intConcatTest = cast(int[2])[1, 2];
	intConcatTest~= 50;
	string decInput = "a";
	decInput~= "こんいちは";
	foreach(dchar ch; "こんいちは")
	{
		decInput~= ch;
		writeln(ch);
	}
	writeln(decInput);
	int[] arrCastTest = [int.max];

	foreach(v; cast(ubyte[])arrCastTest)
		writeln(v);



	enum Type
	{
		int_,
		string_,
	}
	struct TestWithPtr
	{
		int* a;
		Type t = Type.string_;
	}

	TestWithPtr[] _;
	_~= TestWithPtr(new int(50), Type.int_);
	_ = _[0..$-1];
	_~= TestWithPtr(new int(100), Type.string_);
	_~= TestWithPtr(new int(150), Type.string_);
	_~= TestWithPtr(new int(200), Type.int_);

	foreach(v; _)
		writeln(*v.a);


	char[] sup;
	string rev;

	// string test = null;
	for(int i = 'a'; i <= 'z'; i++)
	{
		sup~= cast(char)i;
		rev~= ('z' - cast(char)i) + 'a';
	}


	writeln((typeid(sup)).toString);

	assert(false, sup~sup~sup);
}