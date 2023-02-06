/**
 * Implementation of associative arrays.
 *
 * Copyright: Copyright Digital Mars 2000 - 2015.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Martin Nowak
 * Source: $(DRUNTIMESRC rt/_aaA.d)
 */
module core.arsd.aa;

/// AA version for debuggers, bump whenever changing the layout
extern (C) immutable int _aaVersion = 1;

import core.internal.hash;
import core.arsd.memory_allocation;

uint min(uint a, uint b) { return a < b ? a : b; }
uint max(uint a, uint b) { return a > b ? a : b; }

// grow threshold
private enum GROW_NUM = 4;
private enum GROW_DEN = 5;
// shrink threshold
private enum SHRINK_NUM = 1;
private enum SHRINK_DEN = 8;
// grow factor
private enum GROW_FAC = 4;
// growing the AA doubles it's size, so the shrink threshold must be
// smaller than half the grow threshold to have a hysteresis
static assert(GROW_FAC * SHRINK_NUM * GROW_DEN < GROW_NUM * SHRINK_DEN);
// initial load factor (for literals), mean of both thresholds
private enum INIT_NUM = (GROW_DEN * SHRINK_NUM + GROW_NUM * SHRINK_DEN) / 2;
private enum INIT_DEN = SHRINK_DEN * GROW_DEN;

private enum INIT_NUM_BUCKETS = 8;
// magic hash constants to distinguish empty, deleted, and filled buckets
private enum HASH_EMPTY = 0;
private enum HASH_DELETED = 0x1;
private enum HASH_FILLED_MARK = size_t(1) << 8 * size_t.sizeof - 1;

// The compiler uses `void*` for its prototypes.
// Don't wrap in a struct to maintain ABI compatibility.
alias AA = Impl*;

private bool empty(scope const AA impl) pure nothrow @nogc
{
    return impl is null || !impl.length;
}

private struct Impl
{
private:
    this(scope const TypeInfo_AssociativeArray ti, size_t sz = INIT_NUM_BUCKETS) 
    {
        keysz = cast(uint) ti.key.size;
        valsz = cast(uint) ti.value.size;
        buckets = allocBuckets(sz);
        firstUsed = cast(uint) buckets.length;
        valoff = cast(uint) talign(keysz, ti.value.talign);

        import core.arsd.objectutils : hasPostblit;

        if (hasPostblit(cast()ti.key))
            flags |= Flags.keyHasPostblit;
        if ((ti.key.flags | ti.value.flags) & 1)
            flags |= Flags.hasPointers;

        entryTI = fakeEntryTI(this, ti.key, ti.value);
    }

    Bucket[] buckets;
    uint used;
    uint deleted;
    TypeInfo_Struct entryTI;
    uint firstUsed;
    immutable uint keysz;
    immutable uint valsz;
    immutable uint valoff;
    Flags flags;

    enum Flags : ubyte
    {
        none = 0x0,
        keyHasPostblit = 0x1,
        hasPointers = 0x2,
    }

    @property size_t length() const pure nothrow @nogc
    {
        assert(used >= deleted);
        return used - deleted;
    }

    @property size_t dim() const pure nothrow @nogc @safe
    {
        return buckets.length;
    }

    @property size_t mask() const pure nothrow @nogc
    {
        return dim - 1;
    }

    // find the first slot to insert a value with hash
    inout(Bucket)* findSlotInsert(size_t hash) inout pure nothrow @nogc
    {
        for (size_t i = hash & mask, j = 1;; ++j)
        {
            if (!buckets[i].filled)
                return &buckets[i];
            i = (i + j) & mask;
        }
    }

    // lookup a key
    inout(Bucket)* findSlotLookup(size_t hash, scope const void* pkey, scope const TypeInfo keyti) inout
    {
        for (size_t i = hash & mask, j = 1;; ++j)
        {
            if (buckets[i].hash == hash && keyti.equals(pkey, buckets[i].entry))
                return &buckets[i];
            else if (buckets[i].empty)
                return null;
            i = (i + j) & mask;
        }
    }

    void grow(scope const TypeInfo keyti)
    {
        // If there are so many deleted entries, that growing would push us
        // below the shrink threshold, we just purge deleted entries instead.
        if (length * SHRINK_DEN < GROW_FAC * dim * SHRINK_NUM)
            resize(dim);
        else
            resize(GROW_FAC * dim);
    }

    void shrink(scope const TypeInfo keyti)
    {
        if (dim > INIT_NUM_BUCKETS)
            resize(dim / GROW_FAC);
    }

    void resize(size_t ndim)
    {
        auto obuckets = buckets;
        buckets = allocBuckets(ndim);

        foreach (ref b; obuckets[firstUsed .. $])
            if (b.filled)
                *findSlotInsert(b.hash) = b;

        firstUsed = 0;
        used -= deleted;
        deleted = 0;
        free(cast(ubyte*)(obuckets.ptr)); // safe to free b/c impossible to reference
    }

    void clear() pure nothrow
    {
        import core.stdc.string : memset;
        // clear all data, but don't change bucket array length
        memset(&buckets[firstUsed], 0, (buckets.length - firstUsed) * Bucket.sizeof);
        deleted = used = 0;
        firstUsed = cast(uint) dim;
    }
}

//==============================================================================
// Bucket
//------------------------------------------------------------------------------

private struct Bucket
{
private pure nothrow @nogc:
    size_t hash;
    void* entry;

    @property bool empty() const
    {
        return hash == HASH_EMPTY;
    }

    @property bool deleted() const
    {
        return hash == HASH_DELETED;
    }

    @property bool filled() const @safe
    {
        return cast(ptrdiff_t) hash < 0;
    }
}

Bucket[] allocBuckets(size_t dim) @trusted
{
    enum attr = 0b0001_0000; //enum attr = GC.BlkAttr.NO_INTERIOR;
    immutable sz = dim * Bucket.sizeof;
    return (cast(Bucket*) calloc(sz, attr))[0 .. dim];
}

//==============================================================================
// Entry
//------------------------------------------------------------------------------

private void* allocEntry(scope const Impl* aa, scope const void* pkey)
{
    immutable akeysz = aa.valoff;
    void* res = void;
    if(aa.entryTI)
        res = _d_newitemU(aa.entryTI);
    else
        res = malloc(akeysz + aa.valsz).ptr;

    memcpy(res, pkey, aa.keysz); // copy key
    memset(res + akeysz, 0, aa.valsz); // zero value

    return res;
}

package void entryDtor(void* p, const TypeInfo_Struct sti)
{
    // key and value type info stored after the TypeInfo_Struct by tiEntry()
    auto sizeti = __traits(classInstanceSize, TypeInfo_Struct);
    auto extra = cast(const(TypeInfo)*)(cast(void*) sti + sizeti);
    extra[0].destroy(p);
    extra[1].destroy(p + talign(extra[0].size, extra[1].talign));
}

private bool hasDtor(const TypeInfo ti) pure nothrow
{

    if (typeid(ti) is typeid(TypeInfo_Struct))
        if ((cast(TypeInfo_Struct) cast(void*) ti).xdtor)
            return true;
    if (typeid(ti) is typeid(TypeInfo_StaticArray))
        return hasDtor(cast()ti.next);

    return false;
}

// build type info for Entry with additional key and value fields
TypeInfo_Struct fakeEntryTI(ref Impl aa, const TypeInfo keyti, const TypeInfo valti)
{
    import core.arsd.objectutils;
    //Same as unqualify
    auto kti = unqualify(keyti);
    auto vti = unqualify(valti);

    
    bool entryHasDtor = hasDtor(kti) || hasDtor(vti);
    if (!entryHasDtor)
        return null;

    // save kti and vti after type info for struct
    enum sizeti = __traits(classInstanceSize, TypeInfo_Struct);
    void* p = malloc(sizeti + (2) * (void*).sizeof).ptr;

    memcpy(p, __traits(initSymbol, TypeInfo_Struct).ptr, sizeti);

    auto ti = cast(TypeInfo_Struct) p;
    auto extra = cast(TypeInfo*)(p + sizeti);
    extra[0] = cast() kti;
    extra[1] = cast() vti;

    static immutable tiMangledName = "S2rt3aaA__T5EntryZ";
    ti.name = tiMangledName;


    // we don't expect the Entry objects to be used outside of this module, so we have control
    // over the non-usage of the callback methods and other entries and can keep these null
    // xtoHash, xopEquals, xopCmp, xtoString and xpostblit
    immutable entrySize = aa.valoff + aa.valsz;
    ti.m_init = (cast(ubyte*) null)[0 .. entrySize]; // init length, but not ptr

    if (entryHasDtor)
    {
        // xdtor needs to be built from the dtors of key and value for the GC
        ti.xdtorti = &entryDtor;
        ti.m_flags |= TypeInfo_Struct.StructFlags.isDynamicType;
    }

    ti.align_ = cast(uint) max(kti.talign, vti.talign);

    return ti;
}


//==============================================================================
// Helper functions
//------------------------------------------------------------------------------

private size_t talign(size_t tsize, size_t algn) @safe pure nothrow @nogc
{
    immutable mask = algn - 1;
    assert(!(mask & algn));
    return (tsize + mask) & ~mask;
}

// mix hash to "fix" bad hash functions
private size_t mix(size_t h) @safe pure nothrow @nogc
{
    // final mix function of MurmurHash2
    enum m = 0x5bd1e995;
    h ^= h >> 13;
    h *= m;
    h ^= h >> 15;
    return h;
}

private size_t calcHash(scope const void* pkey, scope const TypeInfo keyti) nothrow
{
    immutable hash = keyti.getHash(pkey);
    // highest bit is set to distinguish empty/deleted from filled buckets
    return mix(hash) | HASH_FILLED_MARK;
}

private size_t nextpow2(const size_t n) pure nothrow @nogc
{
    import core.bitop : bsr;

    if (!n)
        return 1;

    const isPowerOf2 = !((n - 1) & n);
    return 1 << (bsr(n) + !isPowerOf2);
}


//==============================================================================
// API Implementation
//------------------------------------------------------------------------------

/** Allocate associative array data.
 * Called for `new SomeAA` expression.
 * Params:
 *      ti = TypeInfo for the associative array
 * Returns:
 *      A new associative array.
 */
extern (C) Impl* _aaNew(const TypeInfo_AssociativeArray ti)
{
    return new Impl(ti);
}

/// Determine number of entries in associative array.
extern (C) size_t _aaLen(scope const AA aa) pure nothrow @nogc
{
    return aa ? aa.length : 0;
}

/******************************
 * Lookup *pkey in aa.
 * Called only from implementation of (aa[key]) expressions when value is mutable.
 * Params:
 *      paa = associative array opaque pointer
 *      ti = TypeInfo for the associative array
 *      valsz = ignored
 *      pkey = pointer to the key value
 * Returns:
 *      if key was in the aa, a mutable pointer to the existing value.
 *      If key was not in the aa, a mutable pointer to newly inserted value which
 *      is set to all zeros
 */
extern (C) void* _aaGetY(scope ubyte** paa, const TypeInfo_AssociativeArray ti,
    const size_t valsz, scope const void* pkey)
{
    bool found;
    return _aaGetX(paa, ti, valsz, pkey, found);
}

/******************************
 * Lookup *pkey in aa.
 * Called only from implementation of require
 * Params:
 *      paa = associative array opaque pointer
 *      ti = TypeInfo for the associative array
 *      valsz = ignored
 *      pkey = pointer to the key value
 *      found = true if the value was found
 * Returns:
 *      if key was in the aa, a mutable pointer to the existing value.
 *      If key was not in the aa, a mutable pointer to newly inserted value which
 *      is set to all zeros
 */
extern (C) void* _aaGetX(scope ubyte** paa, const TypeInfo_AssociativeArray ti,
    const size_t valsz, scope const void* pkey, out bool found)
{
    
    // lazily alloc implementation
    AA aa = *cast(AA*)paa;
    if (aa is null)
    {
        aa = new Impl(ti);
        *cast(AA*)paa = aa;
    }

    // get hash and bucket for key
    immutable hash = calcHash(pkey, ti.key);

    // found a value => return it
    if (auto p = aa.findSlotLookup(hash, pkey, ti.key))
    {
        found = true;
        return p.entry + aa.valoff;
    }

    auto p = aa.findSlotInsert(hash);
    if (p.deleted)
        --aa.deleted;
    // check load factor and possibly grow
    else if (++aa.used * GROW_DEN > aa.dim * GROW_NUM)
    {
        aa.grow(ti.key);
        p = aa.findSlotInsert(hash);
        assert(p.empty);
    }

    // update search cache and allocate entry
    aa.firstUsed = min(aa.firstUsed, cast(uint)(p - aa.buckets.ptr));
    p.hash = hash;
    p.entry = allocEntry(aa, pkey);
    // postblit for key
    if (aa.flags & Impl.Flags.keyHasPostblit)
    {
        import core.arsd.objectutils;
        __doPostblit(p.entry, aa.keysz, unqualify(ti.key));
    }
    // return pointer to value
    return p.entry + aa.valoff;
}

/******************************
 * Lookup *pkey in aa.
 * Called only from implementation of (aa[key]) expressions when value is not mutable.
 * Params:
 *      aa = associative array opaque pointer
 *      keyti = TypeInfo for the key
 *      valsz = ignored
 *      pkey = pointer to the key value
 * Returns:
 *      pointer to value if present, null otherwise
 */
extern (C) inout(void)* _aaGetRvalueX(inout ubyte** aa, scope const TypeInfo keyti, const size_t valsz,
    scope const void* pkey)
{
    return _aaInX(aa, keyti, pkey);
}

/******************************
 * Lookup *pkey in aa.
 * Called only from implementation of (key in aa) expressions.
 * Params:
 *      aa = associative array opaque pointer
 *      keyti = TypeInfo for the key
 *      pkey = pointer to the key value
 * Returns:
 *      pointer to value if present, null otherwise
 */
extern (C) inout(void)* _aaInX(inout ubyte** _aa, scope const TypeInfo keyti, scope const void* pkey)
{
    import std.stdio;
    AA aa = cast(AA)_aa;
    if (aa.empty)
        return null;

    immutable hash = calcHash(pkey, keyti);
    if (auto p = aa.findSlotLookup(hash, pkey, keyti))
        return cast(inout)(p.entry + aa.valoff);
    return null;
}

/// Delete entry scope const AA, return true if it was present
extern (C) bool _aaDelX(ubyte* _aa, scope const TypeInfo keyti, scope const void* pkey)
{
    AA aa = cast(AA)_aa;
    if (aa.empty)
        return false;
    immutable hash = calcHash(pkey, keyti);
    if (auto p = aa.findSlotLookup(hash, pkey, keyti))
    {
        // clear entry
        p.hash = HASH_DELETED;
        p.entry = null;

        ++aa.deleted;
        // `shrink` reallocates, and allocating from a finalizer leads to
        // InvalidMemoryError: https://issues.dlang.org/show_bug.cgi?id=21442
        if (aa.length * SHRINK_DEN < aa.dim * SHRINK_NUM) // && !GC.inFinalizer() no GC so never in finalizer
            aa.shrink(keyti);

        return true;
    }
    return false;
}

/// Remove all elements from AA.
extern (C) void _aaClear(ubyte* _aa) pure nothrow
{
    AA aa = cast(AA)_aa;
    if (!aa.empty)
    {
        aa.clear();
    }
}

/// Rehash AA
extern (C) void* _aaRehash(ubyte** _paa, scope const TypeInfo keyti)
{
    AA* paa = cast(AA*)_paa;
    AA aa = *paa;
    if (!aa.empty)
        aa.resize(nextpow2(INIT_DEN * aa.length / INIT_NUM));
    return aa;
}

/// Return a GC allocated array of all values
extern (C) inout(void[]) _aaValues(inout ubyte* _aa, const size_t keysz, const size_t valsz,
    const TypeInfo tiValueArray)
{
    AA aa = cast(AA)_aa;
    if (aa.empty)
        return null;

    auto res = _d_newarrayU(tiValueArray, aa.length).ptr;
    auto pval = res;

    immutable off = aa.valoff;
    foreach (b; aa.buckets[aa.firstUsed .. $])
    {
        if (!b.filled)
            continue;
        pval[0 .. valsz] = b.entry[off .. valsz + off];
        pval += valsz;
    }
    // postblit is done in object.values
    return (cast(inout(void)*) res)[0 .. aa.length]; // fake length, return number of elements
}

/// Return a GC allocated array of all keys
extern (C) inout(void[]) _aaKeys(inout ubyte* _aa, const size_t keysz, const TypeInfo tiKeyArray)
{
    AA aa = cast(AA)_aa;
    if (aa.empty)
        return null;

    auto res = _d_newarrayU(tiKeyArray, aa.length).ptr;
    auto pkey = res;

    foreach (b; aa.buckets[aa.firstUsed .. $])
    {
        if (!b.filled)
            continue;
        pkey[0 .. keysz] = b.entry[0 .. keysz];
        pkey += keysz;
    }
    // postblit is done in object.keys
    return (cast(inout(void)*) res)[0 .. aa.length]; // fake length, return number of elements
}

// opApply callbacks are extern(D)
extern (D) alias dg_t = int delegate(void*);
extern (D) alias dg2_t = int delegate(void*, void*);

/// foreach opApply over all values
extern (C) int _aaApply(ubyte* _aa, const size_t keysz, dg_t dg)
{
    AA aa = cast(AA)_aa;
    if (aa.empty)
        return 0;

    immutable off = aa.valoff;
    foreach (b; aa.buckets)
    {
        if (!b.filled)
            continue;
        if (auto res = dg(b.entry + off))
            return res;
    }
    return 0;
}

/// foreach opApply over all key/value pairs
extern (C) int _aaApply2(ubyte* _aa, const size_t keysz, dg2_t dg)
{
    AA aa = cast(AA)_aa;
    if (aa.empty)
        return 0;

    immutable off = aa.valoff;
    foreach (b; aa.buckets)
    {
        if (!b.filled)
            continue;
        if (auto res = dg(b.entry, b.entry + off))
            return res;
    }
    return 0;
}

/** Construct an associative array of type ti from corresponding keys and values.
 * Called for an AA literal `[k1:v1, k2:v2]`.
 * Params:
 *      ti = TypeInfo for the associative array
 *      keys = array of keys
 *      vals = array of values
 * Returns:
 *      A new associative array opaque pointer, or null if `keys` is empty.
 */
extern (C) ubyte* _d_assocarrayliteralTX(const TypeInfo_AssociativeArray ti, void[] keys,
    void[] vals)
{
    assert(keys.length == vals.length);

    immutable keysz = ti.key.size;
    immutable valsz = ti.value.size;
    immutable length = keys.length;

    if (!length)
        return null;

    auto aa = new Impl(ti, nextpow2(INIT_DEN * length / INIT_NUM));

    void* pkey = keys.ptr;
    void* pval = vals.ptr;
    immutable off = aa.valoff;
    uint actualLength = 0;
    foreach (_; 0 .. length)
    {
        immutable hash = calcHash(pkey, ti.key);
        auto p = aa.findSlotLookup(hash, pkey, ti.key);
        if (p is null)
        {
            p = aa.findSlotInsert(hash);
            p.hash = hash;
            p.entry = allocEntry(aa, pkey); // move key, no postblit
            aa.firstUsed = min(aa.firstUsed, cast(uint)(p - aa.buckets.ptr));
            actualLength++;
        }
        else if (aa.entryTI && hasDtor(ti.value))
        {
            // destroy existing value before overwriting it
            ti.value.destroy(p.entry + off);
        }
        // set hash and blit value
        auto pdst = p.entry + off;
        pdst[0 .. valsz] = pval[0 .. valsz]; // move value, no postblit

        pkey += keysz;
        pval += valsz;
    }
    aa.used = actualLength;
    return cast(ubyte*)aa;
}

/// compares 2 AAs for equality
extern (C) int _aaEqual(scope const TypeInfo tiRaw, scope const ubyte* _aa1, scope const ubyte* _aa2)
{
    AA aa1 = cast(AA)_aa1;
    AA aa2 = cast(AA)_aa2;
    if (aa1 is aa2)
        return true;

    immutable len = _aaLen(aa1);
    if (len != _aaLen(aa2))
        return false;

    if (!len) // both empty
        return true;
    
    import core.arsd.objectutils;

    auto uti = unqualify(tiRaw); //unqualify
    auto ti = *cast(TypeInfo_AssociativeArray*)&uti;
    // compare the entries
    immutable off = aa1.valoff;
    foreach (b1; aa1.buckets)
    {
        if (!b1.filled)
            continue;
        auto pb2 = aa2.findSlotLookup(b1.hash, b1.entry, ti.key);
        if (pb2 is null || !ti.value.equals(b1.entry + off, pb2.entry + off))
            return false;
    }
    return true;
}

/// compute a hash
extern (C) size_t _aaGetHash(scope const ubyte** _paa, scope const TypeInfo tiRaw) nothrow
{
    AA* paa = cast(AA*)_paa;
    const AA aa = *paa;

    if (aa.empty)
        return 0;


    import core.arsd.objectutils;
    auto uti = unqualify(tiRaw);
    auto ti = *cast(TypeInfo_AssociativeArray*)&uti;
    immutable off = aa.valoff;
    auto keyHash = &ti.key.getHash;
    auto valHash = &ti.value.getHash;

    size_t h;
    foreach (b; aa.buckets)
    {
        // use addition here, so that hash is independent of element order
        if (b.filled)
            h += hashOf(valHash(b.entry + off), keyHash(b.entry));
    }

    return h;
}

/**
 * _aaRange implements a ForwardRange
 */
struct Range
{
    ubyte* impl;
    size_t idx;
    alias impl this;
}

extern (C) pure nothrow @nogc @trusted
{
    Range _aaRange(return scope ubyte* _aa)
    {
        AA aa = cast(AA)_aa;
        if (!aa)
            return Range();

        foreach (i; aa.firstUsed .. aa.dim)
        {
            if (aa.buckets[i].filled)
                return Range(cast(ubyte*)aa, i);
        }
        return Range(cast(ubyte*)aa, aa.dim);
    }

    bool _aaRangeEmpty(Range r)
    {
        return r.impl is null || r.idx >= (cast(Impl*)r.impl).dim;
    }

    void* _aaRangeFrontKey(Range r)
    {
        assert(!_aaRangeEmpty(r));
        if (r.idx >= (cast(Impl*)r.impl).dim)
            return null;
        return (cast(Impl*)r.impl).buckets[r.idx].entry;
    }

    void* _aaRangeFrontValue(Range r)
    {
        Impl* ri = cast(Impl*)r.impl;
        assert(!_aaRangeEmpty(r));
        if (r.idx >= ri.dim)
            return null;

        auto entry = ri.buckets[r.idx].entry;
        return entry is null ?
            null :
            (() @trusted { return entry + ri.valoff; } ());
    }

    void _aaRangePopFront(ref Range r)
    {
        Impl* ri = (cast(Impl*)r.impl);
        if (r.idx >= ri.dim) return;
        for (++r.idx; r.idx < ri.dim; ++r.idx)
        {
            if (ri.buckets[r.idx].filled)
                break;
        }
    }
}
