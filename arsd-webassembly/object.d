// Minimal druntime for webassembly. Assumes your program has a main function.
module object;

static import arsd.webassembly;

version(CarelessAlocation)
{
	version = inline_concat;
}

alias string = immutable(char)[];
alias wstring = immutable(wchar)[];
alias dstring = immutable(dchar)[];
alias size_t = uint;
alias ptrdiff_t = int;

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

int memcmp(const(void)* s1, const(void*) s2, size_t n) pure @nogc nothrow @trusted {
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

extern(C) void _d_assert_msg(string msg, string file, uint line)
{
	arsd.webassembly.eval(q{ console.error("Assert failure: " + $0 + ":" + $1 + "(" + $2 + ")"); /*, "[" + $2 + ".." + $3 + "] <> " + $4);*/ }, file, line, msg);//, lwr, upr, length);
	arsd.webassembly.abort();
}

void __switch_error(string file, size_t line)
{
	_d_assert_msg("final switch error",file, line);
}

bool __equals(T1, T2)(scope const T1[] lhs, scope const T2[] rhs) {
	if (lhs.length != rhs.length) {
		return false;
	}
	foreach(i; 0..lhs.length) {
		if (lhs[i] != rhs[i]) {
			return false;
		}
	}
	return true;
}

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

/*************************************
 * Attempts to cast Object o to class c.
 * Returns o if successful, null if not.
 */
extern(C) void* _d_interface_cast(void* p, TypeInfo_Class c)
{
    if (!p)
        return null;

    Interface* pi = **cast(Interface***) p;
    return _d_dynamic_cast(cast(Object)(p - pi.offset), c);
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

int __cmp(T)(scope const T[] lhs, scope const T[] rhs) @trusted pure @nogc nothrow
    if (__traits(isScalar, T))
{
    // Compute U as the implementation type for T
    static if (is(T == ubyte) || is(T == void) || is(T == bool))
        alias U = char;
    else static if (is(T == wchar))
        alias U = ushort;
    else static if (is(T == dchar))
        alias U = uint;
    else static if (is(T == ifloat))
        alias U = float;
    else static if (is(T == idouble))
        alias U = double;
    else static if (is(T == ireal))
        alias U = real;
    else
        alias U = T;

    static if (is(U == char))
    {
        int dstrcmp(scope const char[] s1, scope const char[] s2 ) @trusted pure @nogc nothrow
		{
			immutable len = s1.length <= s2.length ? s1.length : s2.length;
			if (__ctfe)
			{
				foreach (const u; 0 .. len)
				{
					if (s1[u] != s2[u])
						return s1[u] > s2[u] ? 1 : -1;
				}
			}
			else
			{
				const ret = memcmp( s1.ptr, s2.ptr, len );
				if ( ret )
					return ret;
			}
			return (s1.length > s2.length) - (s1.length < s2.length);
		}
        return dstrcmp(cast(char[]) lhs, cast(char[]) rhs);
    }
    else static if (!is(U == T))
    {
        // Reuse another implementation
        return __cmp(cast(U[]) lhs, cast(U[]) rhs);
    }
    else
    {
        version (BigEndian)
        static if (__traits(isUnsigned, T) ? !is(T == __vector) : is(T : P*, P))
        {
            if (!__ctfe)
            {
                import core.stdc.string : memcmp;
                int c = memcmp(lhs.ptr, rhs.ptr, (lhs.length <= rhs.length ? lhs.length : rhs.length) * T.sizeof);
                if (c)
                    return c;
                static if (size_t.sizeof <= uint.sizeof && T.sizeof >= 2)
                    return cast(int) lhs.length - cast(int) rhs.length;
                else
                    return int(lhs.length > rhs.length) - int(lhs.length < rhs.length);
            }
        }

        immutable len = lhs.length <= rhs.length ? lhs.length : rhs.length;
        foreach (const u; 0 .. len)
        {
            auto a = lhs.ptr[u], b = rhs.ptr[u];
            static if (is(T : creal))
            {
                // Use rt.cmath2._Ccmp instead ?
                // Also: if NaN is present, numbers will appear equal.
                auto r = (a.re > b.re) - (a.re < b.re);
                if (!r) r = (a.im > b.im) - (a.im < b.im);
            }
            else
            {
                // This pattern for three-way comparison is better than conditional operators
                // See e.g. https://godbolt.org/z/3j4vh1
                const r = (a > b) - (a < b);
            }
            if (r) return r;
        }
        return (lhs.length > rhs.length) - (lhs.length < rhs.length);
    }
}

// This function is called by the compiler when dealing with array
// comparisons in the semantic analysis phase of CmpExp. The ordering
// comparison is lowered to a call to this template.
int __cmp(T1, T2)(T1[] s1, T2[] s2)
if (!__traits(isScalar, T1) && !__traits(isScalar, T2))
{
    import core.internal.traits : Unqual;
    alias U1 = Unqual!T1;
    alias U2 = Unqual!T2;

    static if (is(U1 == void) && is(U2 == void))
        static @trusted ref inout(ubyte) at(inout(void)[] r, size_t i) { return (cast(inout(ubyte)*) r.ptr)[i]; }
    else
        static @trusted ref R at(R)(R[] r, size_t i) { return r.ptr[i]; }

    // All unsigned byte-wide types = > dstrcmp
    immutable len = s1.length <= s2.length ? s1.length : s2.length;

    foreach (const u; 0 .. len)
    {
        static if (__traits(compiles, __cmp(at(s1, u), at(s2, u))))
        {
            auto c = __cmp(at(s1, u), at(s2, u));
            if (c != 0)
                return c;
        }
        else static if (__traits(compiles, at(s1, u).opCmp(at(s2, u))))
        {
            auto c = at(s1, u).opCmp(at(s2, u));
            if (c != 0)
                return c;
        }
        else static if (__traits(compiles, at(s1, u) < at(s2, u)))
        {
            if (int result = (at(s1, u) > at(s2, u)) - (at(s1, u) < at(s2, u)))
                return result;
        }
        else
        {
            // TODO: fix this legacy bad behavior, see
            // https://issues.dlang.org/show_bug.cgi?id=17244
            static assert(is(U1 == U2), "Internal error.");
            import core.stdc.string : memcmp;
            auto c = (() @trusted => memcmp(&at(s1, u), &at(s2, u), U1.sizeof))();
            if (c != 0)
                return c;
        }
    }
    return (s1.length > s2.length) - (s1.length < s2.length);
}



/**
Support for switch statements switching on strings.
Params:
    caseLabels = sorted array of strings generated by compiler. Note the
        strings are sorted by length first, and then lexicographically.
    condition = string to look up in table
Returns:
    index of match in caseLabels, a negative integer if not found
*/
int __switch(T, caseLabels...)(/*in*/ const scope T[] condition) pure nothrow @safe @nogc
{
    // This closes recursion for other cases.
    static if (caseLabels.length == 0)
    {
        return int.min;
    }
    else static if (caseLabels.length == 1)
    {
        return __cmp(condition, caseLabels[0]) == 0 ? 0 : int.min;
    }
    // To be adjusted after measurements
    // Compile-time inlined binary search.
    else static if (caseLabels.length < 7)
    {
        int r = void;
        enum mid = cast(int)caseLabels.length / 2;
        if (condition.length == caseLabels[mid].length)
        {
            r = __cmp(condition, caseLabels[mid]);
            if (r == 0) return mid;
        }
        else
        {
            // Equivalent to (but faster than) condition.length > caseLabels[$ / 2].length ? 1 : -1
            r = ((condition.length > caseLabels[mid].length) << 1) - 1;
        }

        if (r < 0)
        {
            // Search the left side
            return __switch!(T, caseLabels[0 .. mid])(condition);
        }
        else
        {
            // Search the right side
            return __switch!(T, caseLabels[mid + 1 .. $])(condition) + mid + 1;
        }
    }
    else
    {
        // Need immutable array to be accessible in pure code, but case labels are
        // currently coerced to the switch condition type (e.g. const(char)[]).
        pure @trusted nothrow @nogc asImmutable(scope const(T[])[] items)
        {
            assert(__ctfe); // only @safe for CTFE
            immutable T[][caseLabels.length] result = cast(immutable)(items[]);
            return result;
        }
        static immutable T[][caseLabels.length] cases = asImmutable([caseLabels]);

        // Run-time binary search in a static array of labels.
        return __switchSearch!T(cases[], condition);
    }
}

// binary search in sorted string cases, also see `__switch`.
private int __switchSearch(T)(/*in*/ const scope T[][] cases, /*in*/ const scope T[] condition) pure nothrow @safe @nogc
{
    size_t low = 0;
    size_t high = cases.length;

    do
    {
        auto mid = (low + high) / 2;
        int r = void;
        if (condition.length == cases[mid].length)
        {
            r = __cmp(condition, cases[mid]);
            if (r == 0) return cast(int) mid;
        }
        else
        {
            // Generates better code than "expr ? 1 : -1" on dmd and gdc, same with ldc
            r = ((condition.length > cases[mid].length) << 1) - 1;
        }

        if (r > 0) low = mid + 1;
        else high = mid;
    }
    while (low < high);

    // Not found
    return -1;
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
	const(TypeInfo) next()nothrow pure inout @nogc  { return null; }
	size_t size() nothrow pure const @safe @nogc { return 0; }

	bool equals(void* p1, void* p2) { return p1 == p2; }

	/**
	* Return default initializer.  If the type should be initialized to all
	* zeros, an array with a null ptr and a length equal to the type size will
	* be returned. For static arrays, this returns the default initializer for
	* a single element of the array, use `tsize` to get the correct size.
	*/
    const(void)[] initializer() const @trusted nothrow pure
	{
		return (cast(const(void)*) null)[0 .. typeof(null).sizeof];
	}
	@property size_t talign() nothrow pure const { return size; }
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
	uint flags;
	void* deallocator;
	void*[] offTi;
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
	override size_t size() const { return (void[]).sizeof; }
	override const(TypeInfo) next() const { return value; }

	override bool equals(void* p1, void* p2)
    {
        void[] a1 = *cast(void[]*)p1;
        void[] a2 = *cast(void[]*)p2;
        if (a1.length != a2.length)
            return false;
        size_t sz = value.size;
        for (size_t i = 0; i < a1.length; i++)
        {
            if (!value.equals(a1.ptr + i * sz, a2.ptr + i * sz))
                return false;
        }
        return true;
    }
	override @property size_t talign() nothrow pure const
    {
        return (void[]).alignof;
    }
	override const(void)[] initializer() const @trusted { return (cast(void *)null)[0 ..  (void[]).sizeof]; }
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
	override @property size_t talign() nothrow pure const
    {
        return value.talign;
    }

}

class TypeInfo_Enum : TypeInfo {
    TypeInfo base;
    string name;
    void[] m_init;

    override size_t size() const { return base.size; }
    override const(TypeInfo) next() const { return base.next; }
    override bool equals(void* p1, void* p2) { return base.equals(p1, p2); }
	override @property size_t talign() const { return base.talign; }
}

extern (C) void[] _d_newarrayU(const scope TypeInfo ti, size_t length)
{
	return malloc(length * ti.size); // FIXME size actually depends on ti
}

extern(C) void[] _d_newarrayT(const TypeInfo ti, size_t length)
{
	auto arr = _d_newarrayU(ti, length);
	
	(cast(byte[])arr)[] = 0;
	return arr;
}

extern(C) void[] _d_newarrayiT(const TypeInfo ti, size_t length)
{
	auto result = _d_newarrayU(ti, length);
	auto tinext = ti.next;
	auto size = tinext.size;
	auto init = tinext.initializer();
	switch (init.length)
	{
		foreach (T; AliasSeq!(ubyte, ushort, uint, ulong))
		{
		case T.sizeof:
			if (tinext.talign % T.alignof == 0)
			{
				(cast(T*)result.ptr)[0 .. size * length / T.sizeof] = *cast(T*)init.ptr;
				return result;
			}
			goto default;
		}

		default:
		{
			immutable sz = init.length;
			for (size_t u = 0; u < size * length; u += sz)
			{
				memcpy(result.ptr + u, init.ptr, sz);
			}
			return result;
		}
	}
	return result;
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
	size_t _d_arraysetlengthT(return scope ref Tarr arr, size_t newlength) @trusted {
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


version(inline_concat)
extern(C) void[] _d_arraycatnTX(const TypeInfo ti, scope byte[][] arrs) @trusted
{
	auto elemSize = ti.next.size;
	size_t length;
	foreach (b; arrs)
        length += b.length;
	if(!length)
		return null;
	ubyte* ptr = cast(ubyte*)malloc(length * elemSize);

	//Copy data
	{
		ubyte* nPtr = ptr;
		foreach(b; arrs)
		{
			byte* bPtr = b.ptr;
			size_t copySize = b.length*elemSize;
			nPtr[0..copySize] = cast(ubyte[])bPtr[0..copySize];
			nPtr+= copySize;
		}
	}
	return cast(void[])ptr[0..length];
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
			override const(void)[] initializer() pure nothrow @trusted const
			{
				static if(__traits(isZeroInit, type))
					return (cast(void*)null)[0 .. type.sizeof];
				else
				{
					static immutable type[1] c;
					return c;
				}
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
	override bool equals(in void* p1, in void* p2) const
    {
        auto dg1 = *cast(void delegate()*)p1;
        auto dg2 = *cast(void delegate()*)p2;
        return dg1 == dg2;
    }
	override const(void)[] initializer() const @trusted
    {
        return (cast(void *)null)[0 .. (int delegate()).sizeof];
    }
	override @property size_t talign() nothrow pure const
    {
        alias dg = int delegate();
        return dg.alignof;
    }
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
	override const(void)[] initializer() nothrow pure const{return base.initializer();}
    override @property size_t talign() nothrow pure const { return base.talign; }
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
	override @property size_t talign() nothrow pure const { return align_; }

	override const(void)[] initializer() nothrow pure const @safe
	{
		return m_init;
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

T[] dup(T)(scope const(T)[] array) pure nothrow @trusted if (__traits(isPOD, T))
{
	T[] result;
	foreach(ref e; array) {
		result ~= e;
	}
	return result;
}

immutable(T)[] idup(T)(scope const(T)[] array) pure nothrow @trusted
{
	immutable(T)[] result;
	foreach(ref e; array) {
		result ~= e;
	}
	return result;
}
