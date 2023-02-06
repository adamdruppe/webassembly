/+
	This is the D interface to my webassembly javascript bridge.
+/
module arsd.webassembly;

struct AcquireArgument {
	int type;
	const(void)* ptr;
	int length;
}

// the basic bridge functions defined in webassembly-core.js {

@trusted @nogc pure nothrow
{
	extern(C) void retain(int);
	extern(C) void release(int);
	extern(C) int acquire(int returnType, string callingModuleName, string code, AcquireArgument[] arguments);
	extern(C) void abort();
	extern(C) int monotimeNow();
}


// }

export extern(C) int invoke_d_array_delegate(size_t ptr, size_t funcptr, ubyte[] arg) {
	void delegate(in ubyte[] arr) dg;

	dg.ptr = cast(void*) ptr;
	dg.funcptr = cast(typeof(dg.funcptr)) funcptr;

	dg(arg);
	return 0;
	
};

/++
	Evaluates the given code in Javascript. The arguments are available in JS as $0, $1, $2, ....
	The `this` object in the evaluated code is set to an object representing the D module that
	you can store some stuff in across calls without having to hit the global namespace.

	Note that if you want to return a value from javascript, you MUST use the return keyword
	in the script string.

	Wrong: `eval!NativeHandle("document");`

	Right: `eval!NativeHandle("return document");`
+/
template eval(T = void) {
	T eval(Args...)(string code, Args args, string callingModuleName = __MODULE__) @trusted @nogc pure {
		AcquireArgument[Args.length] aa;
		foreach(idx, ref arg; args) {
			// FIXME: some other type for unsigned....
			static if(is(typeof(arg) : const int)) {
				aa[idx].type = 0;
				aa[idx].ptr = cast(void*) arg;
				aa[idx].length = arg.sizeof;
			} else static if(is(immutable typeof(arg) == immutable string)) {
				aa[idx].type = 1;
				aa[idx].ptr = arg.ptr;
				aa[idx].length = arg.length;
			} else static if(is(immutable typeof(arg) == immutable NativeHandle)) {
				aa[idx].type = 2;
				aa[idx].ptr = cast(void*) arg.handle;
				aa[idx].length = NativeHandle.sizeof;
			} else static if(is(typeof(arg) : const float)) {
				aa[idx].type = 3;
				aa[idx].ptr = cast(void*) &arg;
				aa[idx].length = arg.sizeof;
			} else static if(is(immutable typeof(arg) == immutable ubyte[])) {
				aa[idx].type = 4;
				aa[idx].ptr = arg.ptr;
				aa[idx].length = arg.length;
			/*
			} else static if(is(typeof(arg) == delegate)) {
				aa[idx].type = 5;
				aa[idx].ptr = cast(void*) &arg;
				aa[idx].length = arg.sizeof;
			*/
			} else {
				static assert(0);
			}
		}
		static if(is(T == void))
			acquire(0, callingModuleName, code, aa[]);
		else static if(is(T == int))
			return acquire(1, callingModuleName, code, aa[]);
		else static if(is(T == float))
			return *cast(float*) cast(void*) acquire(2, callingModuleName, code, aa[]);
		else static if(is(T == NativeHandle))
			return NativeHandle(acquire(3, callingModuleName, code, aa[]));
		else static if(is(T == string)) {
			auto ptr = cast(int*) acquire(7, callingModuleName, code, aa[]);
			auto len = *ptr;
			ptr++;
			return (cast(immutable(char)*) ptr)[0 .. len];
		}
		else static assert(0);
	}
}

// and do some opDispatch on the native things to call their methods and it should look p cool

struct NativeHandle {
	@trusted @nogc pure:

	int handle;
	bool arc;
	this(int handle, bool arc = true) {
		this.handle = handle;
		this.arc = arc;
	}

	this(this) {
		if(arc) retain(handle);
	}

	~this() {
		if(arc) release(handle);
	}

	// never store these, they don't affect the refcount
	PropertiesHelper properties() {
		return PropertiesHelper(handle);
	}

	// never store these, they don't affect the refcount
	MethodsHelper methods() {
		return MethodsHelper(handle);

	}
}

struct MethodsHelper {
	@trusted @nogc pure:
	@disable this();
	@disable this(this);

	int handle;
	private this(int handle) { this.handle = handle; }

	template opDispatch(string name) {
		template opDispatch(T = NativeHandle) 
		{
			T opDispatch(Args...)(Args args, string callingModuleName = __MODULE__) @trusted @nogc pure 
			{
				return eval!T(q{
					return $0[$1].apply($0, Array.prototype.slice.call(arguments, 2));
				}, NativeHandle(this.handle, false), name, args, callingModuleName);
			}
		}
	}

}
struct PropertiesHelper {
	@trusted @nogc pure:
	@disable this();
	@disable this(this);

	int handle;
	private this(int handle) { this.handle = handle; }

	template opDispatch(string name) {
		template opDispatch(T = NativeHandle) {
			T opDispatch() {
				return eval!T(q{
					return $0[$1];
				}, NativeHandle(this.handle, false), name);
			}

			void opDispatch(T value) {
				return eval!void(q{
					return $0[$1] = $2;
				}, NativeHandle(this.handle, false), name, value);
			}
		}
	}
}
