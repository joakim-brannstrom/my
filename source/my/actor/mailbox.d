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

@safe:

struct Msg {
    MsgType type;
    ulong signature;
    Variant data;
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
}

struct DelayedMsg {
    Msg msg;
    SysTime triggerAt;
}

struct Address {
    private {
        // If the actor that use the address is active and processing messages.
        bool open_;
        ulong id_;
    }

    package {
        Queue!Msg incoming;

        Queue!SystemMsg sysMsg;

        // Delayed messages for this actor that will be triggered in the future.
        Queue!DelayedMsg delayed;

        // Incoming replies on requests.
        Queue!Reply replies;
    }

    private this(Mutex mtx)
    in (mtx !is null) {
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
            incoming.teardown;
            sysMsg.teardown;
            delayed.teardown;
            replies.teardown;
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

    package bool hasMessage() @safe pure nothrow const @nogc {
        return !(incoming.empty && sysMsg.empty && delayed.empty && replies.empty);
    }

    package void setOpen() @safe pure nothrow @nogc {
        open_ = true;
    }

    package void setClosed() @safe pure nothrow @nogc {
        open_ = false;
    }
}

/// Keep track of the pointer to allow detecting when it is only the actor itself that is referesing it.
struct RcAddress {
    package {
        RefCounted!(Address*) addr;
    }

    alias safeGet this;

    private this(Address* addr) {
        this.addr = refCounted(addr);
        import core.stdc.stdio : printf;

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
            import core.stdc.stdio : printf;

            () @trusted {
                printf("b %lx %d %d\n", cast(ulong) addr.get, addr.refCount, GC.inFinalizer);
            }();
            //assert(!GC.inFinalizer, "Error: clean-up of RcAddress incorrectly" ~
            //       " depends on destructors called by the GC.");
        }
    }

    package void release() @safe nothrow @nogc {
        addr.release;

        import core.stdc.stdio : printf;

        () @trusted {
            if (!empty)
                printf("c %lx %d\n", cast(ulong) addr, this.addr.refCount);
        }();
    }

    ulong id() @safe pure nothrow const @nogc {
        return cast(ulong) addr.get;
    }

    size_t toHash() @safe pure nothrow const @nogc scope {
        return cast(size_t) addr.get;
    }

    void opAssign(RcAddress rhs) @safe nothrow @nogc {
        import core.stdc.stdio : printf;

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

    ref inout(Address) safeGet() inout @safe pure nothrow @nogc scope return  {
        return *addr.get;
    }

    ref inout(Address) opCall() inout @safe pure nothrow @nogc scope return  {
        return safeGet;
    }
}

RcAddress makeAddress() {
    return RcAddress(new Address(new Mutex));
}
