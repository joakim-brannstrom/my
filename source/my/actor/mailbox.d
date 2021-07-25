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

    Queue!Msg incoming;

    Queue!SystemMsg sysMsg;

    // Delayed messages for this actor that will be triggered in the future.
    Queue!DelayedMsg delayed;

    // Incoming replies on requests.
    Queue!Reply replies;

    private this(Mutex mtx) {
        // lazy way of generating an ID. a mutex is a class thus allocated on
        // the heap at a unique location. just... use the pointer as the ID.
        id_ = cast(ulong) mtx;
        incoming = typeof(incoming)(mtx);
        sysMsg = typeof(sysMsg)(mtx);
        delayed = typeof(delayed)(mtx);
        replies = typeof(replies)(mtx);
    }

    ulong id() @safe pure nothrow const @nogc {
        return id_;
    }

    bool hasMessage() @safe pure nothrow const @nogc {
        return !(incoming.empty && sysMsg.empty && delayed.empty && replies.empty);
    }

    bool isOpen() @safe pure nothrow const @nogc scope {
        return open_;
    }

    void setOpen() @safe pure nothrow @nogc {
        open_ = true;
    }

    void setClosed() @safe pure nothrow @nogc {
        open_ = false;
    }
}

/// Keep track of the pointer to allow detecting when it is only the actor itself that is referesing it.
struct RcAddress {
    RefCounted!(Address*) addr;

    alias safeGet this;

    private this(Address* addr) {
        this.addr = refCounted(addr);
    }

    package Address* unsafeGet() @system pure nothrow const @nogc scope return  {
        return addr.get;
    }

    ref Address safeGet() @safe pure nothrow const @nogc scope return  {
        return *addr.get;
    }

    void opAssign(RcAddress rhs) @safe nothrow @nogc {
        this.addr = rhs.addr;
    }
}

/// Convenient type for wrapping a pointer and then used in APIs
struct AddressPtr {
    private RcAddress ptr_;

    this(RcAddress a) @safe pure nothrow @nogc {
        this.ptr_ = a;
    }

    void opAssign(AddressPtr rhs) @safe nothrow @nogc {
        this.ptr_ = rhs.ptr_;
    }

    RcAddress ptr() @safe pure nothrow @nogc {
        return ptr_;
    }

    ref Address opCall() @safe pure nothrow @nogc scope return  {
        return ptr_.get;
    }
}

RcAddress makeAddress() {
    return RcAddress(new Address(new Mutex));
}
