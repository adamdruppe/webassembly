module core.arsd.memory_allocation;



private __gshared ubyte* nextFree;
private __gshared size_t memorySize; // in units of 64 KB pages

align(16)
struct AllocatedBlock {
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



private bool growMemoryIfNeeded(size_t sz) @trusted {
	if(cast(size_t) nextFree + AllocatedBlock.sizeof + sz >= memorySize * 64*1024) {
		if(llvm_wasm_memory_grow(0, 4) == size_t.max)
			assert(0, "Out of memory"); // out of memory

		memorySize = llvm_wasm_memory_size(0);

		return true;
	}

	return false;
}

void free(ubyte* ptr) @nogc @trusted {
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


ubyte[] malloc(size_t sz, string file = __FILE__, size_t line = __LINE__) @trusted {
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


ubyte[] calloc(size_t count, size_t size, string file = __FILE__, size_t line = __LINE__) @trusted
{
	auto ret = malloc(count*size,file,line);
	ret[0..$] = 0;
	return ret;
}


ubyte[] realloc(ubyte* ptr, size_t newSize, string file = __FILE__, size_t line = __LINE__) @trusted {
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
ubyte[] realloc(ubyte[] ptr, size_t newSize, string file = __FILE__, size_t line = __LINE__) @trusted
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