// Minimal druntime for webassembly. Assumes your program has a main function.
module object;

static import arsd.webassembly;

version(CarelessAlocation)
{
	version = inline_concat;
}

alias noreturn = typeof(*null);
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

	bool checkChecksum() const @nogc {
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

void free(ubyte* ptr) @nogc {
	auto block = (cast(AllocatedBlock*) ptr) - 1;
	if(!block.checkChecksum())
        assert(false, "Could not check block on free");

	block.used = 0;
	block.flags = 0;

	// last one
	if(ptr + block.blockSize == nextFree) {
		nextFree = cast(ubyte*) block;
		assert(cast(size_t)nextFree % 16 == 0);
	}
}

ubyte[] realloc(ubyte* ptr, size_t newSize, string file = __FILE__, size_t line = __LINE__) {
	if(ptr is null)
		return malloc(newSize, file, line);

	auto block = (cast(AllocatedBlock*) ptr) - 1;
	if(!block.checkChecksum())
		assert(false, "Could not check block while realloc");

	// block.populateChecksum();
	if(newSize <= block.blockSize) {
		block.used = newSize;
		return ptr[0 .. newSize];
	} else {
		// FIXME: see if we can extend teh block into following free space before resorting to malloc

		if(ptr + block.blockSize == nextFree) {
			while(growMemoryIfNeeded(newSize)) {}

            size_t blockSize = newSize;
            if(const over = blockSize % 16)
                blockSize+= 16 - over;

			block.blockSize = blockSize;
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

/**
*  If the ptr isn't owned by the runtime, it will completely malloc the data (instead of realloc)
*   and copy its old content.
*/
ubyte[] realloc(ubyte[] ptr, size_t newSize, string file = __FILE__, size_t line = __LINE__)
{
    if(ptr is null)
        return malloc(newSize, file, line);
    auto block = (cast(AllocatedBlock*) ptr) - 1;
	if(!block.checkChecksum())
    {
        auto ret = malloc(newSize, file, line);
        ret[0..ptr.length] = ptr[]; //Don't clear ptr memory as it can't be clear.
        return ret;
    }
    else return realloc(ptr.ptr, newSize, file, line);

}

private bool growMemoryIfNeeded(size_t sz) {
	if(cast(size_t) nextFree + AllocatedBlock.sizeof + sz >= memorySize * 64*1024) {
		if(llvm_wasm_memory_grow(0, 4) == size_t.max)
			assert(0, "Out of memory"); // out of memory

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


ubyte[] calloc(size_t count, size_t size, string file = __FILE__, size_t line = __LINE__) 
{
	auto ret = malloc(count*size,file,line);
	ret[0..$] = 0;
	return ret;
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

template _arrayOp(Args...)
{
    import core.internal.array.operations;
    alias _arrayOp = arrayOp!Args;
}

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
	arsd.webassembly.eval(
        q{ console.error("Range error: " + $0 + ":" + $1 )}, 
        file, line);
	arsd.webassembly.abort();
}


/// Called when an out of range slice of an array is created
extern(C) void _d_arraybounds_slice(string file, uint line, size_t lwr, size_t upr, size_t length)
{
    arsd.webassembly.eval(
        q{ console.error("Range error: " + $0 + ":" + $1 + " [" + $2 + ".." + $3 + "] <> " + $4)}, 
        file, line, lwr, upr, length);
	arsd.webassembly.abort();
}

/// Called when an out of range array index is accessed
extern(C) void _d_arraybounds_index(string file, uint line, size_t index, size_t length)
{
    arsd.webassembly.eval(
        q{ console.error("Array index " + $0  + " out of bounds '[0.."+$1+"]' " + $2 + ":" + $3)},
        index, length, file, line);
	arsd.webassembly.abort();
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

extern(C) void *memcpy(void* dest, const(void)* src, size_t n) pure @nogc nothrow
{
	ubyte *d = cast(ubyte*) dest;
	const (ubyte) *s = cast(const(ubyte)*)src;
	for (; n; n--) *d++ = *s++;
	return dest;
}

extern(C) int memcmp(const(void)* s1, const(void*) s2, size_t n) pure @nogc nothrow @trusted {
	auto b = cast(ubyte*) s1;
	auto b2 = cast(ubyte*) s2;

	foreach(i; 0 .. n) {
		if(auto diff = *b -  *b2)
			return diff;
		b++;
		b2++;
	}
	return 0;
}

public import core.arsd.utf_decoding;

// }

extern(C) void _d_assert(string file, uint line)  @trusted @nogc pure
{
	arsd.webassembly.eval(q{ console.error("Assert failure: " + $0 + ":" + $1); /*, "[" + $2 + ".." + $3 + "] <> " + $4);*/ }, file, line);//, lwr, upr, length);
	arsd.webassembly.abort();
}
void _d_assertp(immutable(char)* file, uint line)
{
    // import core.stdc.string : strlen;
    size_t sz = 0;
    while(file[sz] != '\0') sz++;
    arsd.webassembly.eval(q{ console.error("Assert failure: " + $0 + ":" + $1 + "(" + $2 + ")"); /*, "[" + $2 + ".." + $3 + "] <> " + $4);*/ }, file[0 .. sz], line);//, lwr, upr, length);
	arsd.webassembly.abort();
}


extern(C) void _d_assert_msg(string msg, string file, uint line) @trusted @nogc pure
{
	arsd.webassembly.eval(q{ console.error("Assert failure: " + $0 + ":" + $1 + "(" + $2 + ")"); /*, "[" + $2 + ".." + $3 + "] <> " + $4);*/ }, file, line, msg);//, lwr, upr, length);
	arsd.webassembly.abort();
}

void __switch_error(string file, size_t line) @trusted @nogc pure
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

//TODO: Support someday?
    extern(C) void _d_throw_exception(Throwable o)
    {
        assert(false, "Exception throw");
    }


// for closures
extern(C) void* _d_allocmemory(size_t sz) {
	return malloc(sz).ptr;
}

///For POD structures
extern (C) void* _d_allocmemoryT(TypeInfo ti)
{
    return malloc(ti.size).ptr;
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

class TypeInfo 
{
	override string toString() const @safe nothrow
    {
        return typeid(this).name;
    }

	const(TypeInfo) next()nothrow pure inout @nogc  { return null; }
	size_t size() nothrow pure const @safe @nogc { return 0; }

	bool equals(in void* p1, in void* p2) const { return p1 == p2; }

	override size_t toHash() @trusted const nothrow
    {
        return hashOf(this.toString());
    }


	size_t getHash(scope const void* p) @trusted nothrow const
	{
		return hashOf(p);
	}

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

	@property uint flags() nothrow pure const @safe @nogc { return 0; }
	/// Run the destructor on the object and all its sub-objects
    void destroy(void* p) const {}
    /// Run the postblit on the object and all its sub-objects
    void postblit(void* p) const {}

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

    override size_t getHash(scope const void* p) @trusted const
    {
        auto o = *cast(Object*)p;
        return o ? o.toHash() : 0;
    }

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

void destroy(bool initialize = true, T)(ref T obj) if (is(T == struct))
{
    import core.internal.destruction : destructRecurse;

    destructRecurse(obj);

    static if (initialize)
    {
        import core.internal.lifetime : emplaceInitializer;
        emplaceInitializer(obj); // emplace T.init
    }
}

private extern (D) nothrow alias void function (Object) fp_t;
private extern (C) void rt_finalize2(void* p, bool det = true, bool resetMemory = true) nothrow
{
    auto ppv = cast(void**) p;
    if (!p || !*ppv)
        return;

    auto pc = cast(TypeInfo_Class*) *ppv;
    if (det)
    {
        auto c = *pc;
        do
        {
            if (c.destructor)
                (cast(fp_t) c.destructor)(cast(Object) p); // call destructor
        }
        while ((c = c.base) !is null);
    }

    if (resetMemory)
    {
        auto w = (*pc).initializer;
        p[0 .. w.length] = w[];
    }
    *ppv = null; // zero vptr even if `resetMemory` is false
}
extern(C) void _d_callfinalizer(void* p)
{
    rt_finalize2(p);
}

void destroy(bool initialize = true, T)(T obj) if (is(T == class))
{
    static if (__traits(getLinkage, T) == "C++")
    {
        static if (__traits(hasMember, T, "__xdtor"))
            obj.__xdtor();

        static if (initialize)
        {
            const initializer = __traits(initSymbol, T);
            (cast(void*)obj)[0 .. initializer.length] = initializer[];
        }
    }
    else
    {
        // Bypass overloaded opCast
        auto ptr = (() @trusted => *cast(void**) &obj)();
        rt_finalize2(ptr, true, initialize);
    }
}
void destroy(bool initialize = true, T)(T obj) if (is(T == interface))
{
    static assert(__traits(getLinkage, T) == "D", "Invalid call to destroy() on extern(" ~ __traits(getLinkage, T) ~ ") interface");

    destroy!initialize(cast(Object)obj);
}
void destroy(bool initialize = true, T)(ref T obj)
    if (!is(T == struct) && !is(T == interface) && !is(T == class) && !__traits(isStaticArray, T))
{
    static if (initialize)
        obj = T.init;
}


class TypeInfo_Pointer : TypeInfo
{
    TypeInfo m_next;

    override bool equals(in void* p1, in void* p2) const { return *cast(void**)p1 == *cast(void**)p2; }
    override size_t getHash(scope const void* p) @trusted const
    {
        size_t addr = cast(size_t) *cast(const void**)p;
        return addr ^ (addr >> 4);
    }
    override @property size_t size() nothrow pure const { return (void*).sizeof; }

	override const(void)[] initializer() const @trusted { return (cast(void *)null)[0 .. (void*).sizeof]; }

    override const (TypeInfo) next() const { return m_next; }
}

class TypeInfo_Array : TypeInfo {
	TypeInfo value;
	override size_t size() const { return (void[]).sizeof; }
	override const(TypeInfo) next() const { return value; }

	override bool equals(in void* p1, in void* p2) const
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

	override bool equals(in void* p1, in void* p2) const {
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

import core.arsd.aa;
alias AARange = core.arsd.aa.Range;
extern (C)
{
    // from druntime/src/rt/aaA.d
	/* The real type is (non-importable) `rt.aaA.Impl*`;
		* the compiler uses `void*` for its prototypes.
		*/
	private alias AA = void*;

    // size_t _aaLen(in AA aa) pure nothrow @nogc;
    private void* _aaGetY(scope AA* paa, const TypeInfo_AssociativeArray ti, const size_t valsz, const scope void* pkey) pure nothrow;
    private void* _aaGetX(scope AA* paa, const TypeInfo_AssociativeArray ti, const size_t valsz, const scope void* pkey, out bool found) ;
    // inout(void)* _aaGetRvalueX(inout AA aa, in TypeInfo keyti, in size_t valsz, in void* pkey);
    inout(void[]) _aaValues(inout AA aa, const size_t keysz, const size_t valsz, const TypeInfo tiValueArray) ;
    inout(void[]) _aaKeys(inout AA aa, const size_t keysz, const TypeInfo tiKeyArray) ;
    void* _aaRehash(AA* paa, const scope TypeInfo keyti) ;
    void _aaClear(AA aa) ;

    // alias _dg_t = extern(D) int delegate(void*);
    // int _aaApply(AA aa, size_t keysize, _dg_t dg);

    // alias _dg2_t = extern(D) int delegate(void*, void*);
    // int _aaApply2(AA aa, size_t keysize, _dg2_t dg);

    AARange _aaRange(AA aa) pure nothrow @nogc @safe;
    bool _aaRangeEmpty(AARange r) pure @safe @nogc nothrow;
    void* _aaRangeFrontKey(AARange r);
    void* _aaRangeFrontValue(AARange r) pure @nogc nothrow;
    void _aaRangePopFront(ref AARange r) pure @nogc nothrow @safe;

    int _aaEqual(scope const TypeInfo tiRaw, scope const AA aa1, scope const AA aa2);
    size_t _aaGetHash(scope const AA* aa, scope const TypeInfo tiRaw) nothrow;

    /*
        _d_assocarrayliteralTX marked as pure, because aaLiteral can be called from pure code.
        This is a typesystem hole, however this is existing hole.
        Early compiler didn't check purity of toHash or postblit functions, if key is a UDT thus
        copiler allowed to create AA literal with keys, which have impure unsafe toHash methods.
    */
    void* _d_assocarrayliteralTX(const TypeInfo_AssociativeArray ti, void[] keys, void[] values);
}

private AARange _aaToRange(T: V[K], K, V)(ref T aa) pure nothrow @nogc @safe
{
    // ensure we are dealing with a genuine AA.
    static if (is(const(V[K]) == const(T)))
        alias realAA = aa;
    else
        const(V[K]) realAA = aa;
    return _aaRange(() @trusted { return *cast(AA*)&realAA; } ());
}

auto byKey(T : V[K], K, V)(T aa) pure nothrow @nogc @safe
{
    import core.internal.traits : substInout;

    static struct Result
    {
        AARange r;

    pure nothrow @nogc:
        @property bool empty()  @safe { return _aaRangeEmpty(r); }
        @property ref front() @trusted
        {
            return *cast(substInout!K*) _aaRangeFrontKey(r);
        }
        void popFront() @safe { _aaRangePopFront(r); }
        @property Result save() { return this; }
    }

    return Result(_aaToRange(aa));
}

/** ditto */
auto byKey(T : V[K], K, V)(T* aa) pure nothrow @nogc
{
    return (*aa).byKey();
}



auto byValue(T : V[K], K, V)(T aa) pure nothrow @nogc @safe
{
    import core.internal.traits : substInout;

    static struct Result
    {
        AARange r;

    pure nothrow @nogc:
        @property bool empty() @safe { return _aaRangeEmpty(r); }
        @property ref front() @trusted
        {
            return *cast(substInout!V*) _aaRangeFrontValue(r);
        }
        void popFront() @safe { _aaRangePopFront(r); }
        @property Result save() { return this; }
    }

    return Result(_aaToRange(aa));
}

/** ditto */
auto byValue(T : V[K], K, V)(T* aa) pure nothrow @nogc
{
    return (*aa).byValue();
}

Key[] keys(T : Value[Key], Value, Key)(T aa) @property
{
    // ensure we are dealing with a genuine AA.
    static if (is(const(Value[Key]) == const(T)))
        alias realAA = aa;
    else
        const(Value[Key]) realAA = aa;
    auto res = () @trusted {
        auto a = cast(void[])_aaKeys(*cast(inout(AA)*)&realAA, Key.sizeof, typeid(Key[]));
        return *cast(Key[]*)&a;
    }();
    static if (__traits(hasPostblit, Key))
        _doPostblit(res);
    return res;
}

/** ditto */
Key[] keys(T : Value[Key], Value, Key)(T *aa) @property
{
    return (*aa).keys;
}

/***********************************
 * Returns a newly allocated dynamic array containing a copy of the values from
 * the associative array.
 * Params:
 *      aa =     The associative array.
 * Returns:
 *      A dynamic array containing a copy of the values.
 */
Value[] values(T : Value[Key], Value, Key)(T aa) @property
{
    // ensure we are dealing with a genuine AA.
    static if (is(const(Value[Key]) == const(T)))
        alias realAA = aa;
    else
        const(Value[Key]) realAA = aa;
    auto res = () @trusted {
        auto a = cast(void[])_aaValues(*cast(inout(AA)*)&realAA, Key.sizeof, Value.sizeof, typeid(Value[]));
        return *cast(Value[]*)&a;
    }();
    static if (__traits(hasPostblit, Value))
        _doPostblit(res);
    return res;
}

/** ditto */
Value[] values(T : Value[Key], Value, Key)(T *aa) @property
{
    return (*aa).values;
}
inout(V) get(K, V)(inout(V[K]) aa, K key, lazy inout(V) defaultValue)
{
    auto p = key in aa;
    return p ? *p : defaultValue;
}

/** ditto */
inout(V) get(K, V)(inout(V[K])* aa, K key, lazy inout(V) defaultValue)
{
    return (*aa).get(key, defaultValue);
}
// Tests whether T can be @safe-ly copied. Use a union to exclude destructor from the test.
private enum bool isSafeCopyable(T) = is(typeof(() @safe { union U { T x; } T *x; auto u = U(*x); }));

/***********************************
 * Looks up key; if it exists applies the update callable else evaluates the
 * create callable and adds it to the associative array
 * Params:
 *      aa =     The associative array.
 *      key =    The key.
 *      create = The callable to apply on create.
 *      update = The callable to apply on update.
 */
void update(K, V, C, U)(ref V[K] aa, K key, scope C create, scope U update)
if (is(typeof(create()) : V) && (is(typeof(update(aa[K.init])) : V) || is(typeof(update(aa[K.init])) == void)))
{
    bool found;
    // if key is @safe-ly copyable, `update` may infer @safe
    static if (isSafeCopyable!K)
    {
        auto p = () @trusted
        {
            return cast(V*) _aaGetX(cast(AA*) &aa, typeid(V[K]), V.sizeof, &key, found);
        } ();
    }
    else
    {
        auto p = cast(V*) _aaGetX(cast(AA*) &aa, typeid(V[K]), V.sizeof, &key, found);
    }
    if (!found)
        *p = create();
    else
    {
        static if (is(typeof(update(*p)) == void))
            update(*p);
        else
            *p = update(*p);
    }
}

ref V require(K, V)(ref V[K] aa, K key, lazy V value = V.init)
{
    bool found;
    // if key is @safe-ly copyable, `require` can infer @safe
    static if (isSafeCopyable!K)
    {
        auto p = () @trusted
        {
            return cast(V*) _aaGetX(cast(AA*) &aa, typeid(V[K]), V.sizeof, &key, found);
        } ();
    }
    else
    {
        auto p = cast(V*) _aaGetX(cast(AA*) &aa, typeid(V[K]), V.sizeof, &key, found);
    }
    if (found)
        return *p;
    else
    {
        *p = value; // Not `return (*p = value)` since if `=` is overloaded
        return *p;  // this might not return a ref to the left-hand side.
    }
}



/***********************************
 * Removes all remaining keys and values from an associative array.
 * Params:
 *      aa =     The associative array.
 */
void clear(Value, Key)(Value[Key] aa)
{
    _aaClear(*cast(AA *) &aa);
}

/** ditto */
void clear(Value, Key)(Value[Key]* aa)
{
    _aaClear(*cast(AA *) aa);
}
void* aaLiteral(Key, Value)(Key[] keys, Value[] values) @trusted pure
{
    return _d_assocarrayliteralTX(typeid(Value[Key]), *cast(void[]*)&keys, *cast(void[]*)&values);
}

alias AssociativeArray(Key, Value) = Value[Key];

class TypeInfo_AssociativeArray : TypeInfo
{
    override string toString() const
    {
        return value.toString() ~ "[" ~ key.toString() ~ "]";
    }

    override bool opEquals(Object o)
    {
        if (this is o)
            return true;
        auto c = cast(const TypeInfo_AssociativeArray)o;
        return c && this.key == c.key &&
                    this.value == c.value;
    }

    override bool equals(in void* p1, in void* p2) @trusted const
    {
        return !!_aaEqual(this, *cast(const AA*) p1, *cast(const AA*) p2);
    }

    override size_t getHash(scope const void* p) nothrow @trusted const
    {
        return _aaGetHash(cast(AA*)p, this);
    }

    // BUG: need to add the rest of the functions

    override @property size_t size() nothrow pure const
    {
        return (char[int]).sizeof;
    }

    override const(void)[] initializer() const @trusted
    {
        return (cast(void *)null)[0 .. (char[int]).sizeof];
    }

    override @property inout(TypeInfo) next() nothrow pure inout { return value; }
    override @property uint flags() nothrow pure const { return 1; }


    TypeInfo value;
    TypeInfo key;

    override @property size_t talign() nothrow pure const
    {
        return (char[int]).alignof;
    }

    version (WithArgTypes) override int argTypes(out TypeInfo arg1, out TypeInfo arg2)
    {
        arg1 = typeid(void*);
        return 0;
    }
}



class TypeInfo_Enum : TypeInfo {
    TypeInfo base;
    string name;
    void[] m_init;

    override size_t size() const { return base.size; }
    override const(TypeInfo) next() const { return base.next; }
    override bool equals(in void* p1, in void* p2) const { return base.equals(p1, p2); }
	override @property size_t talign() const { return base.talign; }
    override void destroy(void* p) const { return base.destroy(p); }
    override void postblit(void* p) const { return base.postblit(p); }

    override const(void)[] initializer() const
    {
        return m_init.length ? m_init : base.initializer();
    }
}

extern (C) void[] _d_newarrayU(const scope TypeInfo ti, size_t length)
{
	return malloc(length * ti.next.size);
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
}

extern (C) void* _d_newitemU(scope const TypeInfo _ti)
{
	import core.arsd.objectutils;
    auto ti =  cast()_ti;
    immutable tiSize = structTypeInfoSize(ti);
    immutable itemSize = ti.size;
    immutable size = itemSize + tiSize;
    auto p = malloc(size);

    return p.ptr;
}

/// ditto
extern (C) void* _d_newitemT(in TypeInfo _ti)
{
    auto p = _d_newitemU(_ti);
    memset(p, 0, _ti.size);
    return p;
}

/// Same as above, for item with non-zero initializer.
extern (C) void* _d_newitemiT(in TypeInfo _ti)
{
    auto p = _d_newitemU(_ti);
    auto init = _ti.initializer();
    assert(init.length <= _ti.size);
    memcpy(p, init.ptr, init.length);
    return p;
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
			auto ptr = cast(T*) realloc(cast(ubyte[])arr, newlength * T.sizeof);
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
		ptr = realloc(cast(ubyte[])px, newSize).ptr;
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

version(inline_concat)
extern (C) byte[] _d_arraycatT(const TypeInfo ti, byte[] x, byte[] y)
{
    import core.arsd.objectutils;
    auto sizeelem = ti.next.size;              // array element size
    size_t xlen = x.length * sizeelem;
    size_t ylen = y.length * sizeelem;
    size_t len  = xlen + ylen;

    if (!len)
        return null;

    byte[] p = cast(byte[])malloc(len);
    memcpy(p.ptr, x.ptr, xlen);
    memcpy(p.ptr + xlen, y.ptr, ylen);
    // do postblit processing
    __doPostblit(p.ptr, xlen + ylen, ti.next);
    return p[0 .. x.length + y.length];
}

extern (C) void[] _d_arrayappendcd(ref byte[] x, dchar c)
{
    // c could encode into from 1 to 4 characters
    char[4] buf = void;
    byte[] appendthis; // passed to appendT
    if (c <= 0x7F)
    {
        buf.ptr[0] = cast(char)c;
        appendthis = (cast(byte *)buf.ptr)[0..1];
    }
    else if (c <= 0x7FF)
    {
        buf.ptr[0] = cast(char)(0xC0 | (c >> 6));
        buf.ptr[1] = cast(char)(0x80 | (c & 0x3F));
        appendthis = (cast(byte *)buf.ptr)[0..2];
    }
    else if (c <= 0xFFFF)
    {
        buf.ptr[0] = cast(char)(0xE0 | (c >> 12));
        buf.ptr[1] = cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf.ptr[2] = cast(char)(0x80 | (c & 0x3F));
        appendthis = (cast(byte *)buf.ptr)[0..3];
    }
    else if (c <= 0x10FFFF)
    {
        buf.ptr[0] = cast(char)(0xF0 | (c >> 18));
        buf.ptr[1] = cast(char)(0x80 | ((c >> 12) & 0x3F));
        buf.ptr[2] = cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf.ptr[3] = cast(char)(0x80 | (c & 0x3F));
        appendthis = (cast(byte *)buf.ptr)[0..4];
    }
    else
        assert(false, "Could not append dchar");      // invalid utf character - should we throw an exception instead?

    //
    // TODO: This always assumes the array type is shared, because we do not
    // get a typeinfo from the compiler.  Assuming shared is the safest option.
    // Once the compiler is fixed, the proper typeinfo should be forwarded.
    //
    return _d_arrayappendT(typeid(shared char[]), x, appendthis);
}




alias AliasSeq(T...) = T;
static foreach(type; AliasSeq!(byte, char, dchar, double, float, int, long, short, ubyte, uint, ulong, ushort, void, wchar)) {
	mixin(q{
		class TypeInfo_}~type.mangleof~q{ : TypeInfo {
            override string toString() const pure nothrow @safe { return type.stringof; }
			override size_t size() const { return type.sizeof; }
            override @property size_t talign() const pure nothrow
            {
                return type.alignof;
            }

			override bool equals(in void* a, in void* b) const {
				static if(is(type == void))
					return false;
				else
				return (*(cast(type*) a) == (*(cast(type*) b)));
			}
            static if(!is(type == void))
            override size_t getHash(scope const void* p) @trusted const nothrow
            {
                return hashOf(*cast(const type *)p);
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
            override string toString() const { return (type[]).stringof; }
			override const(TypeInfo) next() const { return cast(inout)typeid(type); }
            override size_t getHash(scope const void* p) @trusted const nothrow
            {
                return hashOf(*cast(const type[]*) p);
            }

			override bool equals(in void* av, in void* bv) const {
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
// typeof(null)
class TypeInfo_n : TypeInfo
{
    const: pure: @nogc: nothrow: @safe:
    override string toString() { return "typeof(null)"; }
    override size_t getHash(scope const void*) { return 0; }
    override bool equals(in void*, in void*) { return true; }
    override @property size_t size() { return typeof(null).sizeof; }
    override const(void)[] initializer() @trusted { return (cast(void *)null)[0 .. size_t.sizeof]; }
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

class TypeInfo_Axa : TypeInfo_Aa {
    
}
class TypeInfo_Aya : TypeInfo_Aa {

}

class TypeInfo_Function : TypeInfo
{
    override string toString() const pure @trusted{return deco;}
    override bool opEquals(Object o)
    {
        if (this is o)
            return true;
        auto c = cast(const TypeInfo_Function)o;
        return c && this.deco == c.deco;
    }

    // BUG: need to add the rest of the functions

    override @property size_t size() nothrow pure const
    {
        return 0;       // no size for functions
    }
    override const(void)[] initializer() const @safe{return null;}
    TypeInfo _next;
    override const(TypeInfo) next()nothrow pure inout @nogc  { return _next; }

    /**
    * Mangled function type string
    */
    string deco;
}


class TypeInfo_Delegate : TypeInfo {
	TypeInfo next;
	string deco;
	override @property size_t size() nothrow pure const
    {
        alias dg = int delegate();
        return dg.sizeof;
    }
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
    override size_t getHash(scope const void* p) @trusted const
    {
        return hashOf(*cast(const void delegate() *)p);
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
    override size_t getHash(scope const void* p) @trusted const
    {
        if (!*cast(void**)p)
        {
            return 0;
        }
        Interface* pi = **cast(Interface ***)*cast(void**)p;
        Object o = cast(Object)(*cast(void**)p - pi.offset);
        assert(o);
        return o.toHash();
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
	override size_t getHash(scope const(void*) p) @trusted const nothrow { return base.getHash(p); }
	TypeInfo base;
	override size_t size() const { return base.size; }
	override const(TypeInfo) next() const { return base.next; }
	override const(void)[] initializer() nothrow pure const{return base.initializer();}
    override @property size_t talign() nothrow pure const { return base.talign; }
	override bool equals(in void* p1, in void* p2) const { return base.equals(p1, p2); 	}
}


///For some reason, getHash for interfaces wanted that
pragma(mangle, "_D9invariant12_d_invariantFC6ObjectZv")
extern(D) void _d_invariant(Object o)
{
    TypeInfo_Class c;

    //printf("__d_invariant(%p)\n", o);

    // BUG: needs to be filename/line of caller, not library routine
    assert(o !is null); // just do null check, not invariant check

    c = typeid(o);
    do
    {
        if (c.classInvariant)
        {
            (*c.classInvariant)(o);
        }
        c = c.base;
    } while (c);
}

/+
class TypeInfo_Immutable : TypeInfo {
	size_t getHash(in void*) nothrow { return 0; }
	TypeInfo base;
}
+/
class TypeInfo_Invariant : TypeInfo {
	TypeInfo base;
	override size_t getHash(scope const (void*) p) @trusted const nothrow { return base.getHash(p); }
	override size_t size() const { return base.size; }
	override const(TypeInfo) next() const { return base; }
}
class TypeInfo_Shared : TypeInfo {
	override size_t getHash(scope const (void*) p) @trusted const nothrow { return base.getHash(p); }
	TypeInfo base;
	override size_t size() const { return base.size; }
	override const(TypeInfo) next() const { return base; }
}
class TypeInfo_Inout : TypeInfo {
	override size_t getHash(scope const (void*) p) @trusted const nothrow { return base.getHash(p); }
	TypeInfo base;
	override size_t size() const { return base.size; }
	override const(TypeInfo) next() const { return base; }
}

class TypeInfo_Struct : TypeInfo {
	string name;
	void[] m_init;
    @safe pure nothrow
    {
    size_t   function(in void*)           xtoHash;
	bool     function(in void*, in void*) xopEquals;
	int      function(in void*, in void*) xopCmp;
    string   function(in void*)           xtoString;
    }
	uint m_flags;
	union {
		void function(void*) xdtor;
		void function(void*, const TypeInfo_Struct) xdtorti;
	}
	void function(void*) xpostblit;
	uint align_;
	immutable(void)* rtinfo;
    // private struct _memberFunc //? Is it necessary
    // {
    //     union
    //     {
    //         struct // delegate
    //         {
    //             const void* ptr;
    //             const void* funcptr;
    //         }
    //         @safe pure nothrow
    //         {
    //             bool delegate(in void*) xopEquals;
    //             int delegate(in void*) xopCmp;
    //         }
    //     }
    // }

	enum StructFlags : uint
	{
		hasPointers = 0x1,
		isDynamicType = 0x2, // built at runtime, needs type info in xdtor
	}
	override size_t size() const { return m_init.length; }
	override @property uint flags() nothrow pure const @safe @nogc { return m_flags; }

    override size_t toHash() const
    {
        return hashOf(this.name);
    }
    override bool opEquals(Object o)
    {
        if (this is o)
            return true;
        auto s = cast(const TypeInfo_Struct)o;
        return s && this.name == s.name;
    }
    override size_t getHash(scope const void* p) @trusted pure nothrow const
    {
        assert(p);
        if (xtoHash)
        {
            return (*xtoHash)(p);
        }
        else
        {
            return hashOf(p[0 .. initializer().length]);
        }
    }


    override bool equals(in void* p1, in void* p2) @trusted const
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
	final override void destroy(void* p) const
    {
        if (xdtor)
        {
            if (m_flags & StructFlags.isDynamicType)
                (*xdtorti)(p, this);
            else
                (*xdtor)(p);
        }
    }

    override void postblit(void* p) const
    {
        if (xpostblit)
            (*xpostblit)(p);
    }

	override const(void)[] initializer() nothrow pure const @safe
	{
		return m_init;
	}

}

extern(C) bool _xopCmp(in void*, in void*) { return false; }

// }

void __ArrayDtor(T)(scope T[] a)
{
    foreach_reverse (ref T e; a)
        e.__xdtor();
}

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

V[K] dup(T : V[K], K, V)(T aa)
{
    //pragma(msg, "K = ", K, ", V = ", V);

    // Bug10720 - check whether V is copyable
    static assert(is(typeof({ V v = aa[K.init]; })),
        "cannot call " ~ T.stringof ~ ".dup because " ~ V.stringof ~ " is not copyable");

    V[K] result;

    //foreach (k, ref v; aa)
    //    result[k] = v;  // Bug13701 - won't work if V is not mutable

    ref V duplicateElem(ref K k, ref const V v) @trusted pure nothrow
    {
        void* pv = _aaGetY(cast(AA*)&result, typeid(V[K]), V.sizeof, &k);
        memcpy(pv, &v, V.sizeof);
        return *cast(V*)pv;
    }

    foreach (k, ref v; aa)
    {
        static if (!__traits(hasPostblit, V))
            duplicateElem(k, v);
        else static if (__traits(isStaticArray, V))
            _doPostblit(duplicateElem(k, v)[]);
        else static if (!is(typeof(v.__xpostblit())) && is(immutable V == immutable UV, UV))
            (() @trusted => *cast(UV*) &duplicateElem(k, v))().__xpostblit();
        else
            duplicateElem(k, v).__xpostblit();
    }

    return result;
}

/** ditto */
V[K] dup(T : V[K], K, V)(T* aa)
{
    return (*aa).dup;
}

T[] dup(T)(scope T[] array) pure nothrow @trusted if (__traits(isPOD, T) && !is(const(T) : T))
{
	T[] result;
	foreach(ref e; array) {
		result ~= e;
	}
	return result;
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

class Error { this(string msg) {} }
class Throwable : Object
{
    interface TraceInfo
    {
        int opApply(scope int delegate(ref const(char[]))) const;
        int opApply(scope int delegate(ref size_t, ref const(char[]))) const;
        string toString() const;
    }

    string      msg;    /// A message describing the error.

    /**
     * The _file name of the D source code corresponding with
     * where the error was thrown from.
     */
    string      file;
    /**
     * The _line number of the D source code corresponding with
     * where the error was thrown from.
     */
    size_t      line;

    /**
     * The stack trace of where the error happened. This is an opaque object
     * that can either be converted to $(D string), or iterated over with $(D
     * foreach) to extract the items in the stack trace (as strings).
     */
    TraceInfo   info;

    /**
     * A reference to the _next error in the list. This is used when a new
     * $(D Throwable) is thrown from inside a $(D catch) block. The originally
     * caught $(D Exception) will be chained to the new $(D Throwable) via this
     * field.
     */
    private Throwable   nextInChain;

    private uint _refcount;     // 0 : allocated by GC
                                // 1 : allocated by _d_newThrowable()
                                // 2.. : reference count + 1

    /**
     * Returns:
     * A reference to the _next error in the list. This is used when a new
     * $(D Throwable) is thrown from inside a $(D catch) block. The originally
     * caught $(D Exception) will be chained to the new $(D Throwable) via this
     * field.
     */
    @property inout(Throwable) next() @safe inout return scope pure nothrow @nogc { return nextInChain; }

    /**
     * Replace next in chain with `tail`.
     * Use `chainTogether` instead if at all possible.
     */
    @property void next(Throwable tail) @safe scope pure nothrow @nogc{}

    /**
     * Returns:
     *  mutable reference to the reference count, which is
     *  0 - allocated by the GC, 1 - allocated by _d_newThrowable(),
     *  and >=2 which is the reference count + 1
     * Note:
     *  Marked as `@system` to discourage casual use of it.
     */
    @system @nogc final pure nothrow ref uint refcount() return { return _refcount; }

    /**
     * Loop over the chain of Throwables.
     */
    int opApply(scope int delegate(Throwable) dg)
    {
        int result = 0;
        for (Throwable t = this; t; t = t.nextInChain)
        {
            result = dg(t);
            if (result)
                break;
        }
        return result;
    }

    /**
     * Append `e2` to chain of exceptions that starts with `e1`.
     * Params:
     *  e1 = start of chain (can be null)
     *  e2 = second part of chain (can be null)
     * Returns:
     *  Throwable that is at the start of the chain; null if both `e1` and `e2` are null
     */
    static @system @nogc pure nothrow Throwable chainTogether(return scope Throwable e1, return scope Throwable e2)
    {
        if (!e1)
            return e2;
        if (!e2)
            return e1;
        if (e2.refcount())
            ++e2.refcount();

        for (auto e = e1; 1; e = e.nextInChain)
        {
            if (!e.nextInChain)
            {
                e.nextInChain = e2;
                break;
            }
        }
        return e1;
    }

    @nogc @safe pure nothrow this(string msg, Throwable nextInChain = null)
    {
        this.msg = msg;
        this.nextInChain = nextInChain;
        if (nextInChain && nextInChain._refcount)
            ++nextInChain._refcount;
        //this.info = _d_traceContext();
    }

    @nogc @safe pure nothrow this(string msg, string file, size_t line, Throwable nextInChain = null)
    {
        this(msg, nextInChain);
        this.file = file;
        this.line = line;
        //this.info = _d_traceContext();
    }

    @trusted nothrow ~this(){}

    /**
     * Overrides $(D Object.toString) and returns the error message.
     * Internally this forwards to the $(D toString) overload that
     * takes a $(D_PARAM sink) delegate.
     */
    override string toString()
    {
        string s;
        toString((in buf) { s ~= buf; });
        return s;
    }

    /**
     * The Throwable hierarchy uses a toString overload that takes a
     * $(D_PARAM _sink) delegate to avoid GC allocations, which cannot be
     * performed in certain error situations.  Override this $(D
     * toString) method to customize the error message.
     */
    void toString(scope void delegate(in char[]) sink) const{}

    /**
     * Get the message describing the error.
     * Base behavior is to return the `Throwable.msg` field.
     * Override to return some other error message.
     *
     * Returns:
     *  Error message
     */
    const(char)[] message() const
    {
        return this.msg;
    }
}
class Exception : Throwable
{

    /**
     * Creates a new instance of Exception. The nextInChain parameter is used
     * internally and should always be $(D null) when passed by user code.
     * This constructor does not automatically throw the newly-created
     * Exception; the $(D throw) statement should be used for that purpose.
     */
    @nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null)
    {
        super(msg, file, line, nextInChain);
    }

    @nogc @safe pure nothrow this(string msg, Throwable nextInChain, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, nextInChain);
    }
}


import core.internal.hash;
