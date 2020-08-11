// ldc2 -i=. -i=std -Iarsd-webassembly/ -L-allow-undefined -ofserver/omg.wasm -mtriple=wasm32-unknown-unknown-wasm  omg arsd-webassembly/object.d

import arsd.webassembly;

class A {
	int a() { return 123; }
}

class B : A {
	int val;
	override int a() { return 455 + val; }
}

import std.stdio;

void main() {
	B b = new B;
	b.val = 5;
	A a = b;

	int num = eval!int(q{ console.log("hi " + $1 + ", " + $0); this.omg = "yay"; return 52; }, a.a(), "hello world");
	eval(q{ console.log("asdasd " + this.omg + " " + $0); }, num);


	NativeHandle body = eval!NativeHandle("return document.body");
	body.methods.insertAdjacentHTML!void("beforeend", "<span>hello world</span>");
	eval(`console.log($0)`, body.properties.innerHTML!string);

	writeln("writeln!!!");
}

