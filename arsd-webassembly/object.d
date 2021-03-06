// Minimal druntime for webassembly. Assumes your program has a main function.
module object;

static import arsd.webassembly;

alias string = immutable(char)[];
alias size_t = uint;

// ldc defines this, used to find where wasm memory begins
private extern extern(C) ubyte __heap_base;
//                                           ---unused--- -- stack grows down -- -- heap here --
// this is less than __heap_base. memory map 0 ... __data_end ... __heap_base ... end of memory
private extern extern(C) ubyte __data_end;

private ubyte* nextFree;
private size_t memorySize;

ubyte[] malloc(size_t sz) {
	// lol bumping that pointer
	if(nextFree is null) {
		nextFree = &__heap_base;
		memorySize = arsd.webassembly.memorySize();
	}

	auto ret = nextFree;

	nextFree += sz;

	return ret[0 .. sz];
}

export extern(C) ubyte* bridge_malloc(size_t sz) {
	return malloc(sz).ptr;
}

// then the entry point just for convenience so main works.
extern(C) int _Dmain(string[] args);
export extern(C) void _start() { _Dmain(null); }

extern(C) bool _xopEquals(in void*, in void*) { return false; } // assert(0);

// basic array support {

extern(C) void _d_array_slice_copy(void* dst, size_t dstlen, void* src, size_t srclen, size_t elemsz) {
	auto d = cast(ubyte*) dst;
	auto s = cast(ubyte*) src;
	auto len = dstlen * elemsz;

	while(len) {
		*d = *s;
		d++;
		s++;
		len--;
	}

}

extern(C) void _d_arraybounds(string file, size_t line) { //, size_t lwr, size_t upr, size_t length) {
	arsd.webassembly.eval(q{ console.error("Range error: " + $0 + ":" + $1); /*, "[" + $2 + ".." + $3 + "] <> " + $4);*/ }, file, line);//, lwr, upr, length);
	arsd.webassembly.abort();
}

extern(C) void* memset(void* s, int c, size_t n) {
	auto d = cast(ubyte*) s;
	while(n) {
		*d = cast(ubyte) c;
		n--;
	}
	return s;
}
// }

void __switch_error(string file, size_t line) {}

// bare basics class support {

extern(C) Object _d_allocclass(TypeInfo_Class ti) {
	auto ptr = malloc(ti.m_init.length);
	ptr[] = ti.m_init[];
	return cast(Object) ptr.ptr;
}

// for closures
extern(C) void* _d_allocmemory(size_t sz) {
	return malloc(sz).ptr;
}

class Object {}
class TypeInfo {
	const(TypeInfo) next() const { return this; }
	size_t size() const { return 1; }
}
class TypeInfo_Class : TypeInfo {
	ubyte[] m_init;
	string name;
	void*[] vtbl;
	void*[] interfaces;
	TypeInfo_Class base;
	void* dtor;
	void function(Object) ci;
	uint flags;
	void* deallocator;
	void*[] offti;
	void function(Object) dctor;
	immutable(void)* rtInfo;

	override size_t size() const { return size_t.sizeof; }
}

class TypeInfo_Array : TypeInfo {
	TypeInfo value;
	override size_t size() const { return 2*size_t.sizeof; }
	override const(TypeInfo) next() const { return value; }
}

extern(C) void[] _d_newarrayT(const TypeInfo ti, size_t length) {
	return malloc(length * ti.size); // FIXME size actually depends on ti
}

template _d_arraysetlengthTImpl(Tarr : T[], T) {
	size_t _d_arraysetlengthT(return scope ref Tarr arr, size_t newlength) {
		auto ptr = cast(T*) malloc(newlength * T.sizeof);
		arr = ptr[0 .. newlength];
		return newlength;
	}
}

// FIXME so broken. and idk all why.
extern (C) byte[] _d_arrayappendcTX(const TypeInfo ti, ref byte[] px, size_t n) @trusted {
	auto elemSize = ti.next.size;
	auto newLength = n + px.length;
	auto newSize = newLength * elemSize;
	//import std.stdio; writeln(newSize, " ", newLength);
	auto ptr = cast(byte*) malloc(newSize);
	auto ns = ptr[0 .. newSize];
	auto op = px.ptr;
	auto ol = px.length * elemSize;

	foreach(i, b; op[0 .. ol])
		ns[i] = b;

	(cast(size_t *)(&px))[0] = newLength;
	(cast(void **)(&px))[1] = ns.ptr;
	return px;
}


alias AliasSeq(T...) = T;
static foreach(type; AliasSeq!(byte, char, dchar, double, float, int, long, short, ubyte, uint, ulong, ushort, void, wchar)) {
	mixin(q{
		class TypeInfo_}~type.mangleof~q{ : TypeInfo {
			override size_t size() const { return type.sizeof; }
		}
		class TypeInfo_A}~type.mangleof~q{ : TypeInfo_Array {
			override const(TypeInfo) next() const { return typeid(type); }
		}
	});
}

class TypeInfo_Aya : TypeInfo_Aa {

}

class TypeInfo_Delegate : TypeInfo {
	TypeInfo next;
	string deco;
	override size_t size() const { return size_t.sizeof * 2; }
}

class TypeInfo_Const : TypeInfo {
	size_t getHash(in void*) nothrow { return 0; }
	TypeInfo base;
	override size_t size() const { return base.size; }
	override const(TypeInfo) next() const { return base; }
}
/+
class TypeInfo_Immutable : TypeInfo {
	size_t getHash(in void*) nothrow { return 0; }
	TypeInfo base;
}
+/
class TypeInfo_Invariant : TypeInfo {
	size_t getHash(in void*) nothrow { return 0; }
	TypeInfo base;
	override size_t size() const { return base.size; }
	override const(TypeInfo) next() const { return base; }
}
class TypeInfo_Shared : TypeInfo {
	size_t getHash(in void*) nothrow { return 0; }
	TypeInfo base;
	override size_t size() const { return base.size; }
	override const(TypeInfo) next() const { return base; }
}
class TypeInfo_Inout : TypeInfo {
	size_t getHash(in void*) nothrow { return 0; }
	TypeInfo base;
	override size_t size() const { return base.size; }
	override const(TypeInfo) next() const { return base; }
}

class TypeInfo_Struct : TypeInfo {
	string name;
	void[] m_init;
	void* xtohash;
	void* xopequals;
	void* xopcmp;
	void* xtostring;
	uint flags;
	union {
		void function(void*) dtor;
		void function(void*, const TypeInfo_Struct) xdtor;
	}
	void function(void*) postblit;
	uint align_;
	immutable(void)* rtinfo;
	override size_t size() const { return m_init.length; }
}

// }
