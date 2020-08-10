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

extern(C) ubyte* bridge_malloc(size_t sz) {
	return malloc(sz).ptr;
}

// then the entry point just for convenience so main works.
extern(C) int _Dmain(string[] args);
extern(C) void _start() { _Dmain(null); }

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

extern(C) void _d_arraybounds(string file, size_t line) {
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
class TypeInfo {}
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
}

class TypeInfo_Array : TypeInfo {
	TypeInfo value;
}

extern(C) void[] _d_newarrayT(const TypeInfo ti, size_t length) {
	return malloc(length * 4); // FIXME size depends on ti
}

class TypeInfo_Ai : TypeInfo_Array {}

class TypeInfo_Const : TypeInfo {
	size_t getHash(in void*) nothrow { return 0; }
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
}

// }
