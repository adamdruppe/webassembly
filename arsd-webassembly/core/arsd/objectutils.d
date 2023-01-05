module core.arsd.objectutils;

///Provides only __doPostblit and hasPostblit for making the code simpler.

bool hasPostblit(in TypeInfo ti) nothrow pure
{
    return (&ti.postblit).funcptr !is &TypeInfo.postblit;
}

void __doPostblit(void *ptr, size_t len, const TypeInfo ti)
{
    if (!hasPostblit(ti))
        return;

    if (auto tis = cast(TypeInfo_Struct)ti)
    {
        // this is a struct, check the xpostblit member
        auto pblit = tis.xpostblit;
        if (!pblit)
            // postblit not specified, no point in looping.
            return;

        // optimized for struct, call xpostblit directly for each element
        immutable size = ti.size;
        const eptr = ptr + len;
        for (;ptr < eptr;ptr += size)
            pblit(ptr);
    }
    else
    {
        // generic case, call the typeinfo's postblit function
        immutable size = ti.size;
        const eptr = ptr + len;
        for (;ptr < eptr;ptr += size)
            ti.postblit(ptr);
    }
}
