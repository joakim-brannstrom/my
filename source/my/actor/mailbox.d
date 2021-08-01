/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.mailbox;

import core.sync.mutex : Mutex;
import std.datetime : SysTime;
import std.variant : Variant;

import sumtype;

import my.actor.common;
import my.gc.refc;
public import my.actor.system_msg;

struct Msg {
    MsgType type;
    ulong signature;
    Variant data;

    /// Copy constructor
    this(ref return typeof(this) rhs) {
        type = rhs.type;
        signature = rhs.signature;
        data = rhs.data;
    }

    @disable this(this);
}

enum MsgType {
    oneShot,
    request,
}

alias SystemMsg = SumType!(ErrorMsg, DownMsg, ExitMsg, SystemExitMsg,
        MonitorRequest, DemonitorRequest, LinkRequest, UnlinkRequest);

struct Reply {
    ulong id;
    Variant data;

    this(ref return Reply a) {
        id = a.id;
        data = a.data;
    }

    @disable this(this);
}

struct DelayedMsg {
    Msg msg;
    SysTime triggerAt;

    this(const ref return DelayedMsg a) {
        msg = cast(Msg) a.msg;
        triggerAt = a.triggerAt;
    }

    @disable this(this);
}

struct Address {
    private {
        // If the actor that use the address is active and processing messages.
        bool open_;
        ulong id_;
        Mutex mtx;
    }

    package {
        Queue!Msg incoming;

        Queue!SystemMsg sysMsg;

        // Delayed messages for this actor that will be triggered in the future.
        Queue!DelayedMsg delayed;

        // Incoming replies on requests.
        Queue!Reply replies;
    }

    private this(Mutex mtx) @safe
    in (mtx !is null) {
        this.mtx = mtx;

        // lazy way of generating an ID. a mutex is a class thus allocated on
        // the heap at a unique location. just... use the pointer as the ID.
        () @trusted { id_ = cast(ulong) cast(void*) mtx; }();
        incoming = typeof(incoming)(mtx);
        sysMsg = typeof(sysMsg)(mtx);
        delayed = typeof(delayed)(mtx);
        replies = typeof(replies)(mtx);
    }

    @disable this(this);

    size_t toHash() @safe pure nothrow const @nogc scope {
        return id_.hashOf();
    }

    void shutdown() @safe nothrow {
        try {
            synchronized (mtx) {
                incoming.teardown((ref Msg a) { a.data = a.data.type.init; });
                sysMsg.teardown((ref SystemMsg a) { a = SystemMsg.init; });
                delayed.teardown((ref DelayedMsg a) {
                    a.msg.data = a.msg.data.type.init;
                });
                replies.teardown((ref Reply a) { a.data = a.data.type.init; });
                open_ = false;
            }
        } catch (Exception e) {
            assert(0, "this should never happen");
        }
    }

    /// Globally unique ID for the address.
    ulong id() @safe pure nothrow const @nogc {
        return id_;
    }

    bool isOpen() @safe pure nothrow const @nogc scope {
        return open_;
    }

    package void put(T)(T msg) {
        static if (is(T : Msg))
            incoming.put(msg);
        else static if (is(T : SystemMsg))
            sysMsg.put(msg);
        else static if (is(T : DelayedMsg))
            delayed.put(msg);
        else static if (is(T : Reply))
            replies.put(msg);
        else
            static assert(0, "msg type not supported " ~ T.stringof);
    }

    package auto pop(T)() @safe {
        static if (is(T : Msg))
            return incoming.pop;
        else static if (is(T : SystemMsg))
            return sysMsg.pop;
        else static if (is(T : DelayedMsg))
            return delayed.pop;
        else static if (is(T : Reply))
            return replies.pop;
        else
            static assert(0, "msg type not supported " ~ T.stringof);
    }

    package bool empty(T)() @safe {
        static if (is(T : Msg))
            return incoming.empty;
        else static if (is(T : SystemMsg))
            return sysMsg.empty;
        else static if (is(T : DelayedMsg))
            return delayed.empty;
        else static if (is(T : Reply))
            return replies.empty;
        else
            static assert(0, "msg type not supported " ~ T.stringof);
    }

    package bool hasMessage() @safe pure nothrow const @nogc {
        try {
            return !(incoming.empty && sysMsg.empty && delayed.empty && replies.empty);
        } catch (Exception e) {
        }
        return false;
    }

    package void setOpen() @safe pure nothrow @nogc {
        open_ = true;
    }

    package void setClosed() @safe pure nothrow @nogc {
        open_ = false;
    }
}

alias WeakAddress = WeakRef!(Address*);

/** Messages can be sent to a strong address.
 */
struct StrongAddress {
    import core.stdc.stdio : printf;

@safe:

    package {
        RefCounted!(Address*) addr;
    }

    alias safeGet this;

    private this(Address* addr) {
        this.addr = refCounted(addr);

        //() @trusted { printf("a %lx %d\n", cast(ulong) addr, this.addr.refCount); }();
    }

    package this(RefCounted!(Address*) addr) {
        this.addr = addr;

        () @trusted { printf("a %lx %d\n", cast(ulong) addr, this.addr.refCount); }();
    }

    ~this() @safe nothrow @nogc {
        import core.memory : GC;

        // this lead to hard to track down errors because a breakpoint has to
        // be set for _d_throwdwarf. But the alternative is worse because it
        // could lead to "dangling" addresses and in the longer run dangling
        // actors. Actors that are never shutdown because they are not detected
        // as "unreachable".
        if (!empty) {
            //() @trusted {
            //    printf("b %lx %d %d\n", cast(ulong) addr, addr.refCount, GC.inFinalizer);
            //}();
            assert(!GC.inFinalizer,
                    "Error: clean-up of StrongAddress incorrectly"
                    ~ " depends on destructors called by the GC.");
        }
    }

    package void release() @safe nothrow @nogc {
        () @trusted {
            if (!empty)
                printf("c %lx %d\n", cast(ulong) addr, this.addr.refCount);
        }();

        addr.release;
    }

    ulong id() @safe pure nothrow const @nogc {
        return cast(ulong) addr.unsafePtr;
    }

    size_t toHash() @safe pure nothrow const @nogc scope {
        return cast(size_t) addr.unsafePtr;
    }

    void opAssign(StrongAddress rhs) @safe nothrow @nogc {
        () @trusted {
            if (!empty)
                printf("d %lx %d\n", cast(ulong) addr, this.addr.refCount);
        }();
        this.addr = rhs.addr;
    }

    bool empty() @safe pure nothrow const @nogc {
        return addr.empty;
    }

    package Address* unsafeGet() @system pure nothrow @nogc scope return  {
        return addr.get;
    }

    package ref inout(Address) safeGet() inout @safe pure nothrow @nogc scope return  {
        return *addr.get;
    }

    package ref inout(Address) opCall() inout @safe pure nothrow @nogc scope return  {
        return safeGet;
    }

    WeakAddress weakRef() @safe nothrow {
        return addr.weakRef;
    }
}

StrongAddress makeAddress2() @safe {
    return StrongAddress(new Address(new Mutex));
}
