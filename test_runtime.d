// ldc2 -i=. -i=std --d-version=CarelessAllocation -Iarsd-webassembly/ -L-allow-undefined -ofserver/omg.wasm -mtriple=wasm32-unknown-unknown-wasm runtime_test arsd-webassembly/object.d

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

}

