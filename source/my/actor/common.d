/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.common;

import core.sync.mutex : Mutex;

/** Multiple producer, "single" consumer thread safe queue.
 *
 * The value may be `T.init` if multiple consumers try to pop a value at the same time.
 */
struct Queue(T) {
    import std.container.dlist : DList;

    private {
        Mutex mtx;
        DList!(T*) data;
        bool open;
    }

    @disable this(this);

    this(Mutex mtx) {
        this.mtx = mtx;
        this.open = true;
    }

    void put(T a) @trusted {
        synchronized (mtx) {
            if (open)
                data.insertBack(new T(a));
        }
    }

    T pop() @trusted scope {
        import std.algorithm : move;

        T rval;
        synchronized (mtx) {
            if (!empty) {
                move(*data.front, rval);
                assert(*data.front == T.init);
                .destroy(data.front);
                data.removeFront;
                //data = data[1 .. $];
            }
        }
        return rval;
    }

    bool empty() @safe pure const @nogc {
        synchronized (mtx) {
            return data.empty;
        }
    }

    /// clear the queue and permanently shut it down by rejecting put messages.
    void teardown(void delegate(ref T) deinit) @trusted {
        synchronized (mtx) {
            foreach (ref a; data)
                deinit(*a);
            open = false;
            data.clear;
        }
    }
}

/** Errors that occur in the actor system.
 *
 * Attribution: C++ Actor Framework.
 * The framework is well developed and has gathered a lot of experience
 * throughout the years. The error enum is one of many indications of this
 * fact.  The enum `Error` here is a copy of those suitable for a local actor
 * system.
 */
enum SystemError : ubyte {
    // no error
    none,
    /// Indicates that an actor dropped an unexpected message.
    unexpectedMessage,
    /// Indicates that a response message did not match the provided handler.
    unexpectedResponse,
    /// Indicates that the receiver of a request is no longer alive.
    requestReceiverDown,
    /// Indicates that a request message timed out.
    requestTimeout,
    /// An exception was thrown during message handling.
    runtimeError,
}

/** A special kind of error codes are exit reasons of actors. These errors are
 * usually fail states set by the actor system itself. The two exceptions are
 * exit_reason::user_shutdown and exit_reason::kill. The former is used to
 * signalize orderly, user-requested shutdown and can be used by programmers in
 * the same way. The latter terminates an actor unconditionally when used in
 * send_exit, even for actors that override the default handler (see Exit
 * Handler).
 */

/// This error category represents fail conditions for actors.
enum ExitReason : ubyte {
    /// Indicates that an actor finished execution without error.
    normal,
    /// Indicates that an actor died because of an unhandled exception.
    unhandledException,
    /// Indicates that the exit reason for this actor is unknown, i.e.,
    /// the actor has been terminated and no longer exists.
    unknown,
    /// Indicates that an actor was forced to shutdown by a user-generated event.
    userShutdown,
    /// Indicates that an actor was killed unconditionally.
    kill,
}

ulong makeSignature(Types...)() @safe {
    import std.traits : Unqual;

    ulong rval;
    static foreach (T; Types) {
        rval += typeid(Unqual!T).toHash;
    }
    return rval;
}
