// Minimal druntime for webassembly. Assumes your program has a main function.
module object;

static import arsd.webassembly;

alias string = immutable(char)[];
alias wstring = immutable(wchar)[];
alias size_t = uint;

// ldc defines this, used to find where wasm memory begins
private extern extern(C) ubyte __heap_base;
//                                           ---unused--- -- stack grows down -- -- heap here --
// this is less than __heap_base. memory map 0 ... __data_end ... __heap_base ... end of memory
private extern extern(C) ubyte __data_end;

// llvm intrinsics {
	/+
		mem must be 0 (it is index of memory thing)
		delta is in 64 KB pages
		return OLD size in 64 KB pages, or size_t.max if it failed.
	+/
	pragma(LDC_intrinsic, "llvm.wasm.memory.grow.i32")
	private int llvm_wasm_memory_grow(int mem, int delta);


	// in 64 KB pages
	pragma(LDC_intrinsic, "llvm.wasm.memory.size.i32")
	private int llvm_wasm_memory_size(int mem);
// }



private __gshared ubyte* nextFree;
private __gshared size_t memorySize; // in units of 64 KB pages

align(16)
private struct AllocatedBlock {
	enum Magic = 0x731a_9bec;
	enum Flags {
		inUse = 1,
		unique = 2,
	}

	size_t blockSize;
	size_t flags;
	size_t magic;
	size_t checksum;

	size_t used; // the amount actually requested out of the block; used for assumeSafeAppend

	/* debug */
	string file;
	size_t line;

	// note this struct MUST align each alloc on an 8 byte boundary or JS is gonna throw bullshit

	void populateChecksum() {
		checksum = blockSize ^ magic;
	}

	bool checkChecksum() const {
		return magic == Magic && checksum == (blockSize ^ magic);
	}

	ubyte[] dataSlice() return {
		return ((cast(ubyte*) &this) + typeof(this).sizeof)[0 .. blockSize];
	}

	static int opApply(scope int delegate(AllocatedBlock*) dg) {
		if(nextFree is null)
			return 0;
		ubyte* next = &__heap_base;
		AllocatedBlock* block = cast(AllocatedBlock*) next;
		while(block.checkChecksum()) {
			if(auto result = dg(block))
				return result;
			next += AllocatedBlock.sizeof;
			next += block.blockSize;
			block = cast(AllocatedBlock*) next;
		}

		return 0;
	}
}

static assert(AllocatedBlock.sizeof % 16 == 0);

void free(ubyte* ptr) {
	auto block = (cast(AllocatedBlock*) ptr) - 1;
	if(!block.checkChecksum())
		arsd.webassembly.abort();

	block.used = 0;
	block.flags = 0;

	// last one
	if(ptr + block.blockSize == nextFree) {
		nextFree = cast(ubyte*) block;
		assert(cast(size_t)nextFree % 16 == 0);
	}
}

ubyte[] realloc(ubyte* ptr, size_t newSize) {
	if(ptr is null)
		return malloc(newSize);

	auto block = (cast(AllocatedBlock*) ptr) - 1;
	if(!block.checkChecksum())
		arsd.webassembly.abort();

	// block.populateChecksum();
	if(newSize <= block.blockSize) {
		block.used = newSize;
		return ptr[0 .. newSize];
	} else {
		// FIXME: see if we can extend teh block into following free space before resorting to malloc

		if(ptr + block.blockSize == nextFree) {
			while(growMemoryIfNeeded(newSize)) {}

			block.blockSize = newSize + newSize % 16;
			block.used = newSize;
			block.populateChecksum();
			nextFree = ptr + block.blockSize;
			assert(cast(size_t)nextFree % 16 == 0);
			return ptr[0 .. newSize];
		}

		auto newThing = malloc(newSize);
		newThing[0 .. block.used] = ptr[0 .. block.used];

		if(block.flags & AllocatedBlock.Flags.unique) {
			// if we do malloc, this means we are allowed to free the existing block
			free(ptr);
		}

		assert(cast(size_t) newThing.ptr % 16 == 0);

		return newThing;
	}
}

private bool growMemoryIfNeeded(size_t sz) {
	if(cast(size_t) nextFree + AllocatedBlock.sizeof + sz >= memorySize * 64*1024) {
		if(llvm_wasm_memory_grow(0, 4) == size_t.max)
			assert(0); // out of memory

		memorySize = llvm_wasm_memory_size(0);

		return true;
	}

	return false;
}

ubyte[] malloc(size_t sz, string file = __FILE__, size_t line = __LINE__) {
	// lol bumping that pointer
	if(nextFree is null) {
		nextFree = &__heap_base; // seems to be 75312
		assert(cast(size_t)nextFree % 16 == 0);
		memorySize = llvm_wasm_memory_size(0);
	}

	while(growMemoryIfNeeded(sz)) {}

	auto base = cast(AllocatedBlock*) nextFree;

	auto blockSize = sz;
	if(auto val = blockSize % 16)
	blockSize += 16 - val; // does NOT include this metadata section!

	// debug list allocations
	//import std.stdio; writeln(file, ":", line, " / ", sz, " +", blockSize);

	base.blockSize = blockSize;
	base.flags = AllocatedBlock.Flags.inUse;
	// these are just to make it more reliable to detect this header by backtracking through the pointer from a random array.
	// otherwise it'd prolly follow the linked list from the beginning every time or make a free list or something. idk tbh.
	base.magic = AllocatedBlock.Magic;
	base.populateChecksum();

	base.used = sz;

	// debug
	base.file = file;
	base.line = line;

	nextFree += AllocatedBlock.sizeof;

	auto ret = nextFree;

	nextFree += blockSize;

	//writeln(cast(size_t) nextFree);
	//import std.stdio; writeln(cast(size_t) ret, " of ", sz, " rounded to ", blockSize);
	//writeln(file, ":", line);
	assert(cast(size_t) ret % 8 == 0);

	return ret[0 .. sz];
}

void reserve(T)(ref T[] arr, size_t length) {
	arr = (cast(T*) (malloc(length * T.sizeof).ptr))[0 .. 0];
}

// debug
export extern(C) void printBlockDebugInfo(void* ptr) {
	if(ptr is null) {
		foreach(block; AllocatedBlock) {
			printBlockDebugInfo(block);
		}
		return;
	}

	// otherwise assume it is a pointer returned from malloc

	auto block = (cast(AllocatedBlock*) ptr) - 1;
	if(ptr is null)
		block = cast(AllocatedBlock*) &__heap_base;

	printBlockDebugInfo(block);
}

// debug
void printBlockDebugInfo(AllocatedBlock* block) {
	import std.stdio;
	writeln(block.blockSize, " ", block.flags, " ", block.checkChecksum() ? "OK" : "X", " ");
	if(block.checkChecksum())
		writeln(cast(size_t)((cast(ubyte*) (block + 2)) + block.blockSize), " ", block.file, " : ", block.line);
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


/// Called when an out of range slice of an array is created
extern(C) void _d_arraybounds_slice(string file, uint line, size_t, size_t, size_t)
{
    // Ignore additional information for now
    _d_arraybounds(file, line);
}

/// Called when an out of range array index is accessed
extern(C) void _d_arraybounds_index(string file, uint line, size_t, size_t)
{
    // Ignore additional information for now
    _d_arraybounds(file, line);
}


extern(C) void* memset(void* s, int c, size_t n) {
	auto d = cast(ubyte*) s;
	while(n) {
		*d = cast(ubyte) c;
		d++;
		n--;
	}
	return s;
}

pragma(LDC_intrinsic, "llvm.memcpy.p0i8.p0i8.i#")
    void llvm_memcpy(T)(void* dst, const(void)* src, T len, bool volatile_ = false);

extern(C) void *memcpy(void* dest, const(void)* src, size_t n)
{
	ubyte *d = cast(ubyte*) dest;
	const (ubyte) *s = cast(const(ubyte)*)src;
	for (; n; n--) *d++ = *s++;
	return dest;
}

int memcmp(const(void)* s1, const(void*) s2, size_t n) {
	auto b = cast(ubyte*) s1;
	auto b2 = cast(ubyte*) s2;

	foreach(i; 0 .. n) {
		if(auto diff = b -  b2)
			return diff;
	}
	return 0;
}


// }

extern(C) void _d_assert(string file, uint line) {
	arsd.webassembly.eval(q{ console.error("Assert failure: " + $0 + ":" + $1); /*, "[" + $2 + ".." + $3 + "] <> " + $4);*/ }, file, line);//, lwr, upr, length);
	arsd.webassembly.abort();
}

extern(C) void _d_assert_msg(string msg, string f, uint l) 
{
	_d_assert(f, l);
	// arsd.webassembly.eval(q{ console.error("Assert failure: " + $0 + ":" + $1); /*, "[" + $2 + ".." + $3 + "] <> " + $4);*/ }, file, line);//, lwr, upr, length);
	arsd.webassembly.abort();
}

void __switch_error(string file, size_t line) {}

// bare basics class support {

extern(C) Object _d_allocclass(TypeInfo_Class ti) {
	auto ptr = malloc(ti.m_init.length);
	ptr[] = ti.m_init[];
	return cast(Object) ptr.ptr;
}

extern(C) void* _d_dynamic_cast(Object o, TypeInfo_Class c) {
	void* res = null;
	size_t offset = 0;
	if (o && _d_isbaseof2(typeid(o), c, offset))
	{
		res = cast(void*) o + offset;
	}
	return res;
}

extern(C)
int _d_isbaseof2(scope TypeInfo_Class oc, scope const TypeInfo_Class c, scope ref size_t offset) @safe

{
    if (oc is c)
        return true;

    do
    {
        if (oc.base is c)
            return true;

        // Bugzilla 2013: Use depth-first search to calculate offset
        // from the derived (oc) to the base (c).
        foreach (iface; oc.interfaces)
        {
            if (iface.classinfo is c || _d_isbaseof2(iface.classinfo, c, offset))
            {
                offset += iface.offset;
                return true;
            }
        }

        oc = oc.base;
    } while (oc);

    return false;
}

// for floats
extern(C) double fmod(double f, double w) {
	auto i = cast(int) f;
	return i % cast(int) w;
}

// for closures
extern(C) void* _d_allocmemory(size_t sz) {
	return malloc(sz).ptr;
}

class Object
{
	/// Convert Object to human readable string
	string toString() { return "Object"; }
	/// Compute hash function for Object
	size_t toHash() @trusted nothrow
	{
		auto addr = cast(size_t)cast(void*)this;
		return addr ^ (addr >>> 4);
	}
	
    /// Compare against another object. NOT IMPLEMENTED!
	int opCmp(Object o) { assert(false, "not implemented"); }
    /// Check equivalence againt another object
	bool opEquals(Object o) { return this is o; }
}

/// Compare to objects
bool opEquals(Object lhs, Object rhs)
{
    // If aliased to the same object or both null => equal
    if (lhs is rhs) return true;

    // If either is null => non-equal
    if (lhs is null || rhs is null) return false;

    if (!lhs.opEquals(rhs)) return false;

    // If same exact type => one call to method opEquals
    if (typeid(lhs) is typeid(rhs) ||
        !__ctfe && typeid(lhs).opEquals(typeid(rhs)))
            /* CTFE doesn't like typeid much. 'is' works, but opEquals doesn't
            (issue 7147). But CTFE also guarantees that equal TypeInfos are
            always identical. So, no opEquals needed during CTFE. */
    {
        return true;
    }

    // General case => symmetric calls to method opEquals
    return rhs.opEquals(lhs);
}
/************************
* Returns true if lhs and rhs are equal.
*/
bool opEquals(const Object lhs, const Object rhs)
{
    // A hack for the moment.
    return opEquals(cast()lhs, cast()rhs);
}

class TypeInfo {
	const(TypeInfo) next() const { return null; }
	size_t size() const { return 1; }

	bool equals(void* p1, void* p2) { return p1 == p2; }

	/**
	* Return default initializer.  If the type should be initialized to all
	* zeros, an array with a null ptr and a length equal to the type size will
	* be returned. For static arrays, this returns the default initializer for
	* a single element of the array, use `tsize` to get the correct size.
	*/
    abstract const(void)[] initializer() nothrow pure const @safe @nogc;
}

class TypeInfo_Class : TypeInfo 
{
	ubyte[] m_init; /// class static initializer (length gives class size)
	string name; /// name of class
	void*[] vtbl; // virtual function pointer table
	Interface[] interfaces;
	TypeInfo_Class base;
	void* destructor;
	void function(Object) classInvariant;
	uint m_flags;
	void* deallocator;
	void*[] m_offTi;
	void function(Object) defaultConstructor;
	immutable(void)* rtInfo;

	override @property size_t size() nothrow pure const
    { return Object.sizeof; }

	override bool equals(in void* p1, in void* p2) const
    {
        Object o1 = *cast(Object*)p1;
        Object o2 = *cast(Object*)p2;

        return (o1 is o2) || (o1 && o1.opEquals(o2));
    }

	override const(void)[] initializer() nothrow pure const @safe
    {
        return m_init;
    }
}
class TypeInfo_Pointer : TypeInfo 
{ 
    TypeInfo m_next; 

    override bool equals(void* p1, void* p2) { return *cast(void**)p1 == *cast(void**)p2; }
    override @property size_t size() nothrow pure const { return (void*).sizeof; }

	override const(void)[] initializer() const @trusted { return (cast(void *)null)[0 .. (void*).sizeof]; }

    override const (TypeInfo) next() const { return m_next; }
}

class TypeInfo_Array : TypeInfo {
	TypeInfo value;
	override size_t size() const { return 2*size_t.sizeof; }
	override const(TypeInfo) next() const { return value; }
}

class TypeInfo_StaticArray : TypeInfo {
	TypeInfo value;
	size_t len;
	override size_t size() const { return value.size * len; }
	override const(TypeInfo) next() const { return value; }

	override bool equals(void* p1, void* p2) {
		size_t sz = value.size;

		for (size_t u = 0; u < len; u++)
		{
		    if (!value.equals(p1 + u * sz, p2 + u * sz))
		    {
			return false;
		}
		}
		return true;
	}

}


extern(C) void[] _d_newarrayT(const TypeInfo ti, size_t length) {
	return malloc(length * ti.size); // FIXME size actually depends on ti
}


AllocatedBlock* getAllocatedBlock(void* ptr) {
	auto block = (cast(AllocatedBlock*) ptr) - 1;
	if(!block.checkChecksum())
		return null;
	return block;
}

/++
	Marks the memory block as OK to append in-place if possible.
+/
void assumeSafeAppend(T)(T[] arr) {
	auto block = getAllocatedBlock(arr.ptr);
	if(block is null) assert(0);

	block.used = arr.length;
}

/++
	Marks the memory block associated with this array as unique, meaning
	the runtime is allowed to free the old block immediately instead of
	keeping it around for other lingering slices.

	In real D, the GC would take care of this but here I have to hack it.

	arsd.webasm extension
+/
void assumeUniqueReference(T)(T[] arr) {
	auto block = getAllocatedBlock(arr.ptr);
	if(block is null) assert(0);

	block.flags |= AllocatedBlock.Flags.unique;
}

template _d_arraysetlengthTImpl(Tarr : T[], T) {
	size_t _d_arraysetlengthT(return scope ref Tarr arr, size_t newlength) {
		auto orig = arr;

		if(newlength <= arr.length) {
			arr = arr[0 ..newlength];
		} else {
			auto ptr = cast(T*) realloc(cast(ubyte*) arr.ptr, newlength * T.sizeof);
			arr = ptr[0 .. newlength];
			if(orig !is null) {
				arr[0 .. orig.length] = orig[];
			}
		}

		return newlength;
	}
}

extern (C) byte[] _d_arrayappendcTX(const TypeInfo ti, ref byte[] px, size_t n) @trusted {
	auto elemSize = ti.next.size;
	auto newLength = n + px.length;
	auto newSize = newLength * elemSize;
	//import std.stdio; writeln(newSize, " ", newLength);
	ubyte* ptr;
	if(px.ptr is null)
		ptr = malloc(newSize).ptr;
	else // FIXME: anti-stomping by checking length == used
		ptr = realloc(cast(ubyte*) px.ptr, newSize).ptr;
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
			override bool equals(void* a, void* b) {
				static if(is(type == void))
					return false;
				else
				return (*(cast(type*) a) == (*(cast(type*) b)));
			}
		}
		class TypeInfo_A}~type.mangleof~q{ : TypeInfo_Array {
			override const(TypeInfo) next() const { return typeid(type); }
			override bool equals(void* av, void* bv) {
				type[] a = *(cast(type[]*) av);
				type[] b = *(cast(type[]*) bv);

				static if(is(type == void))
					return false;
				else {
					foreach(idx, item; a)
						if(item != b[idx])
							return false;
					return true;
				}
			}
		}
	});
}

struct Interface {
	TypeInfo_Class classinfo;
	void*[] vtbl;
	size_t offset;
}

/**
 * Array of pairs giving the offset and type information for each
 * member in an aggregate.
 */
struct OffsetTypeInfo
{
    size_t   offset;    /// Offset of member from start of object
    TypeInfo ti;        /// TypeInfo for this member
}

class TypeInfo_Aya : TypeInfo_Aa {

}

class TypeInfo_Delegate : TypeInfo {
	TypeInfo next;
	string deco;
	override size_t size() const { return size_t.sizeof * 2; }
}


//Directly copied from LWDR source.
class TypeInfo_Interface : TypeInfo 
{
	TypeInfo_Class info;
	
	override bool equals(in void* p1, in void* p2) const
    {
        Interface* pi = **cast(Interface ***)*cast(void**)p1;
        Object o1 = cast(Object)(*cast(void**)p1 - pi.offset);
        pi = **cast(Interface ***)*cast(void**)p2;
        Object o2 = cast(Object)(*cast(void**)p2 - pi.offset);

        return o1 == o2 || (o1 && o1.opCmp(o2) == 0);
    }

	override const(void)[] initializer() const @trusted
    {
        return (cast(void *)null)[0 .. Object.sizeof];
    }

    override @property size_t size() nothrow pure const
    {
        return Object.sizeof;
    }
}

class TypeInfo_Const : TypeInfo {
	size_t getHash(in void*) nothrow { return 0; }
	TypeInfo base;
	override size_t size() const { return base.size; }
	override const(TypeInfo) next() const { return base.next; }
	
	override bool equals(void* p1, void* p2) { return base.equals(p1, p2); 	}
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
	 bool     function(in void*, in void*) xopEquals;
	int      function(in void*, in void*) xopCmp;
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

    override bool equals(in void* p1, in void* p2) @trusted
    {
        if (!p1 || !p2)
            return false;
        else if (xopEquals)
            return (*xopEquals)(p1, p2);
        else if (p1 == p2)
            return true;
        else
            // BUG: relies on the GC not moving objects
            return memcmp(p1, p2, m_init.length) == 0;
    }

}

extern(C) bool _xopCmp(in void*, in void*) { return false; }

// }

TTo[] __ArrayCast(TFrom, TTo)(return scope TFrom[] from)
{
    const fromSize = from.length * TFrom.sizeof;
    const toLength = fromSize / TTo.sizeof;

    if ((fromSize % TTo.sizeof) != 0)
    {
        //onArrayCastError(TFrom.stringof, fromSize, TTo.stringof, toLength * TTo.sizeof);
	import arsd.webassembly;
	abort();
    }

    struct Array
    {
        size_t length;
        void* ptr;
    }
    auto a = cast(Array*)&from;
    a.length = toLength; // jam new length
    return *cast(TTo[]*)a;
}

extern (C) void[] _d_arrayappendT(const TypeInfo ti, ref byte[] x, byte[] y)
{
    auto length = x.length;
    auto tinext = ti.next;
    auto sizeelem = tinext./*t*/size;              // array element size
    _d_arrayappendcTX(ti, x, y.length);
    memcpy(x.ptr + length * sizeelem, y.ptr, y.length * sizeelem);

    // do postblit
    //__doPostblit(x.ptr + length * sizeelem, y.length * sizeelem, tinext);
    return x;
}

extern (C) int _adEq2(void[] a1, void[] a2, TypeInfo ti)
{
    debug(adi) printf("_adEq2(a1.length = %d, a2.length = %d)\n", a1.length, a2.    length);
    if (a1.length != a2.length)
        return 0;               // not equal
    if (!ti.equals(&a1, &a2))
        return 0;
    return 1;
}

