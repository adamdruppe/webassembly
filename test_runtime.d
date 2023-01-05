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
}

