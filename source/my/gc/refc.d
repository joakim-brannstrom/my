/**
 * [Source](https://raw.githubusercontent.com/schveiguy/iopipe/makesafe/source/iopipe/refc.d).
 *
 * Reference counting using the GC.
 *
 * The RefCounted struct simply stores the item in a GC block, and also adds a
 * root to that block. Once all known references to the block are removed
 * (tracked by a reference count in the block), then the block is removed, and
 * the destructor run. Since it's a root, it can run the full destructor of the
 * data underneath, without worrying about GC data being collected underneath
 * it.
 *
 * This depends on the block not being involved in a cycle, which should be
 * fine for iopipes.
 *
 * Note that atomics are used for the reference count because the GC can
 * destroy things in other threads.
 */
module my.gc.refc;

struct RefCounted(T) {
    this(Args...)(auto ref Args args) {
        import core.memory : GC;

        // need to use untyped memory, so we don't get a dtor call by the GC.
        import std.traits : hasIndirections;
        import std.conv : emplace;

        static if (hasIndirections!T)
            auto rawMem = new void[Impl.sizeof];
        else
            auto rawMem = new ubyte[Impl.sizeof];
        _impl = (() @trusted => cast(Impl*) rawMem.ptr)();
        emplace(_impl, args);
        () @trusted { GC.addRoot(_impl); }();
    }

    private struct Impl {
        this(ref T _item) {
            import std.algorithm : move;

            item = move(_item);
        }

        this(Args...)(auto ref Args args) {
            item = T(args);
        }

        T item;
        shared int _count = 1;
    }

    this(this) {
        if (_impl) {
            import core.atomic;

            _impl._count.atomicOp!"+="(1);
        }
    }

    ~this() {
        release;
    }

    ref inout(T) get() inout {
        assert(_impl, "Invalid refcounted access");
        return _impl.item;
    }

    void opAssign(RefCounted other) {
        import std.algorithm : swap;

        swap(_impl, other._impl);
    }

    void opAssign(T other) {
        import std.algorithm : move;

        move(other, _impl.item);
    }

    /// Release the reference.
    void release() {
        if (_impl) {
            assert(_impl._count >= 0, "Invalid count detected");
            import core.atomic;

            if (_impl._count.atomicOp!"-="(1) == 0) {
                destroy(_impl.item);
                import core.memory : GC;

                () @trusted { GC.removeRoot(_impl); }();
            }
            _impl = null;
        }
    }

    /// The number of references.
    int refCount() @safe pure nothrow const @nogc {
        import core.atomic : atomicLoad;

        if (_impl) {
            return atomicLoad(_impl._count);
        }
        return 0;
    }

    alias get this;

private:
    private Impl* _impl;
}

RefCounted!T refCounted(T)(auto ref T item) {
    return RefCounted!T(item);
}

@safe unittest {
    size_t dtorcalled = 0;
    struct S {
        int x;
        @safe ~this() {
            if (x)
                dtorcalled++;
        }

        @disable this(this);
    }

    {
        auto destroyme = S(1).refCounted;
        auto dm2 = destroyme;
        auto dm3 = destroyme;
        assert(destroyme.refCount == 3);
        assert(dm2.refCount == 3);
        assert(dm3.refCount == 3);
    }

    assert(dtorcalled == 1);
}
