/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.actor;

import std.stdio;
import core.stdc.stdio : printf;

import core.thread : Thread;
import logger = std.experimental.logger;
import std.algorithm : schwartzSort, max, min, among;
import std.array : empty;
import std.datetime : SysTime, Clock, dur;
import std.functional : toDelegate;
import std.meta : staticMap;
import std.traits : Parameters, Unqual, ReturnType, isFunctionPointer, isFunction, isDelegate;
import std.typecons : Tuple, tuple;
import std.variant : Variant;

import my.actor.common : ExitReason, SystemError, makeSignature;
import my.actor.mailbox;
import my.actor.msg;
import my.actor.system : System;
import my.actor.typed : isTypedAddress, isTypedActorImpl;
import my.gc.refc;
import sumtype;

private struct PromiseData {
    RcAddress replyTo;
    ulong replyId;
}

// deliver can only be called one time.
struct Promise(T) {
    package {
        RefCounted!PromiseData data;
    }

    void deliver(T reply) {
        auto tmp = reply;
        deliver(reply);
    }

    /** Deliver the message `reply`.
     *
     * A promise can only be delivered once.
     */
    void deliver(ref T reply) @trusted
    in (!data.empty, "promise must be initialized") {
        scope (exit)
            () { data = PromiseData.init; data.release; }();

        // TODO: should probably call delivering actor with an ErrorMsg if replyTo is closed.
        if (!data.empty && data.replyTo().isOpen) {
            enum wrapInTuple = !is(T : Tuple!U, U);
            static if (wrapInTuple)
                data.replyTo().replies.put(Reply(data.replyId, Variant(tuple(reply))));
            else
                data.replyTo().replies.put(Reply(data.replyId, Variant(reply)));
        }
    }

    void opAssign(Promise!T rhs) {
        data = rhs.data;
    }

    /// True if the promise is not initialized.
    bool empty() {
        return data.empty || data.replyId == 0;
    }

    /// Clear the promise.
    void clear() {
        data.release;
    }
}

auto makePromise(T)() {
    return Promise!T(refCounted(PromiseData.init));
}

struct RequestResult(T) {
    this(T v) {
        value = typeof(value)(v);
    }

    this(ErrorMsg v) {
        value = typeof(value)(v);
    }

    this(Promise!T v) {
        value = typeof(value)(v);
    }

    SumType!(T, ErrorMsg, Promise!T) value;
}

private alias MsgHandler = void delegate(void* ctx, ref Variant msg) @safe;
private alias RequestHandler = void delegate(void* ctx, ref Variant msg,
        ulong replyId, scope RcAddress replyTo) @safe;
private alias ReplyHandler = void delegate(void* ctx, ref Variant msg) @safe;

alias DefaultHandler = void delegate(ref Actor self, ref Variant msg) @safe nothrow;

/** Actors send error messages to others by returning an error (see Errors)
 * from a message handler. Similar to exit messages, error messages usually
 * cause the receiving actor to terminate, unless a custom handler was
 * installed. The default handler is used as fallback if request is used
 * without error handler.
 */
alias ErrorHandler = void delegate(ref Actor self, ErrorMsg) @safe nothrow;

/** Bidirectional monitoring with a strong lifetime coupling is established by
 * calling a `LinkRequest` to an address. This will cause the runtime to send
 * an `ExitMsg` if either this or other dies. Per default, actors terminate
 * after receiving an `ExitMsg` unless the exit reason is exit_reason::normal.
 * This mechanism propagates failure states in an actor system. Linked actors
 * form a sub system in which an error causes all actors to fail collectively.
 */
alias ExitHandler = void delegate(ref Actor self, ExitMsg msg) @safe nothrow;

/// An exception has been thrown while processing a message.
alias ExceptionHandler = void delegate(ref Actor self, Exception e) @safe nothrow;

/** Actors can monitor the lifetime of other actors by sending a `MonitorRequest`
 * to an address. This will cause the runtime system to send a `DownMsg` for
 * other if it dies.
 *
 * Actors drop down messages unless they provide a custom handler.
 */
alias DownHandler = void delegate(ref Actor self, DownMsg msg) @safe nothrow;

void defaultHandler(ref Actor self, ref Variant msg) @safe nothrow {
}

/// Write the name of the actor and the message type to the console.
void logAndDropHandler(ref Actor self, ref Variant msg) @trusted nothrow {
    import std.stdio : writeln;

    try {
        writeln("UNKNOWN message sent to actor ", self.name);
        writeln(msg.toString);
    } catch (Exception e) {
    }
}

void defaultErrorHandler(ref Actor self, ErrorMsg msg) @safe nothrow {
    self.lastError = msg.reason;
    self.shutdown;
}

void defaultExitHandler(ref Actor self, ExitMsg msg) @safe nothrow {
    self.lastError = msg.reason;
    self.forceShutdown;
}

void defaultExceptionHandler(ref Actor self, Exception e) @safe nothrow {
    self.lastError = SystemError.runtimeError;
    // TODO: should log?
    self.forceShutdown;
}

// Write the name of the actor and the exception to stdout.
void logExceptionHandler(ref Actor self, Exception e) @safe nothrow {
    import std.stdio : writeln;

    self.lastError = SystemError.runtimeError;

    try {
        writeln("EXCEPTION thrown by actor ", self.name);
        writeln(e.msg);
        writeln("TERMINATING");
    } catch (Exception e) {
    }

    self.forceShutdown;
}

/// Timeout for an outstanding request.
struct ReplyHandlerTimeout {
    ulong id;
    SysTime timeout;
}

private enum ActorState {
    /// waiting to be started.
    waiting,
    /// active and processing messages.
    active,
    /// wait for all awaited responses to finish
    shutdown,
    /// discard also the awaite responses, just shutdown fast
    forceShutdown,
    /// in process of shutting down
    finishShutdown,
    /// stopped.
    stopped,
}

private struct AwaitReponse {
    Closure!(ReplyHandler, void*) behavior;
    ErrorHandler onError;
}

struct Actor {
    package RcAddress addr;
    // visible in the package for logging purpose.
    package ActorState state_;

    private {
        // TODO: rename to behavior.
        Closure!(MsgHandler, void*)[ulong] incoming;
        Closure!(RequestHandler, void*)[ulong] reqBehavior;

        // callbacks for awaited responses key:ed on their id.
        AwaitReponse[ulong] awaitedResponses;
        ReplyHandlerTimeout[] replyTimeouts;

        // important that it start at 1 because then zero is known to not be initialized.
        ulong nextReplyId = 1;

        /// Delayed messages ordered by their trigger time.
        DelayedMsg[] delayed;

        /// Used during shutdown to signal monitors and links why this actor is terminating.
        SystemError lastError;

        /// monitoring the actor lifetime.
        RcAddress[size_t] monitors;

        /// strong, bidirectional link of the actors lifetime.
        RcAddress[size_t] links;

        // Number of messages that has been processed.
        ulong messages_;

        /// System the actor belongs to.
        System* homeSystem_;

        string name_;

        ErrorHandler errorHandler_;

        /// callback when a link goes down.
        DownHandler downHandler_;

        ExitHandler exitHandler_;

        ExceptionHandler exceptionHandler_;

        DefaultHandler defaultHandler_;
    }

    invariant () {
        if (state_ != ActorState.waiting) {
            assert(!addr.empty);
            assert(errorHandler_);
            assert(exitHandler_);
            assert(exceptionHandler_);
            assert(defaultHandler_);
        }
    }

    this(RcAddress a) @trusted {
        addr = a;
        addr.setOpen;
        errorHandler_ = toDelegate(&defaultErrorHandler);
        downHandler_ = null;
        exitHandler_ = toDelegate(&defaultExitHandler);
        exceptionHandler_ = toDelegate(&defaultExceptionHandler);
        defaultHandler_ = toDelegate(&.defaultHandler);
    }

    RcAddress address() @safe nothrow @nogc {
        return addr;
    }

    ref RcAddress addressRef() @safe pure nothrow @nogcreturn  {
        return addr;
    }

    ref System homeSystem() @safe pure nothrow @nogc {
        return *homeSystem_;
    }

    /** Clean shutdown of the actor
     *
     * Stopping incoming messages from triggering new behavior and finish all
     * awaited respones.
     */
    void shutdown() @safe nothrow {
        if (state_.among(ActorState.waiting, ActorState.active))
            state_ = ActorState.shutdown;
    }

    /** Force an immediate shutdown.
     *
     * Stopping incoming messages from triggering new behavior and finish all
     * awaited respones.
     */
    void forceShutdown() @safe nothrow {
        if (state_.among(ActorState.waiting, ActorState.active, ActorState.shutdown))
            state_ = ActorState.forceShutdown;
    }

    ulong id() @safe pure nothrow const @nogc {
        return addr.id;
    }

    /// Returns: the name of the actor.
    string name() @safe pure nothrow const @nogc {
        return name_;
    }

    // dfmt off

    /// Set name name of the actor.
    void name(string n) @safe pure nothrow @nogc {
        this.name_ = n;
    }

    void errorHandler(ErrorHandler v) @safe pure nothrow @nogc {
        errorHandler_ = v;
    }

    void downHandler(DownHandler v) @safe pure nothrow @nogc {
        downHandler_ = v;
    }

    void exitHandler(ExitHandler v) @safe pure nothrow @nogc {
        exitHandler_ = v;
    }

    void exceptionHandler(ExceptionHandler v) @safe pure nothrow @nogc {
        exceptionHandler_ = v;
    }

    void defaultHandler(DefaultHandler v) @safe pure nothrow @nogc {
        defaultHandler_ = v;
    }

    // dfmt on

package:
    bool hasMessage() @safe pure nothrow const @nogc {
        return addr().hasMessage;
    }

    /// How long until a delayed message or a timeout fires.
    Duration nextTimeout(const SysTime now, const Duration default_) @safe pure nothrow const @nogc {
        return min(delayed.empty ? default_ : (delayed[0].triggerAt - now),
                replyTimeouts.empty ? default_ : (replyTimeouts[0].timeout - now));
    }

    /// Number of messages that has been processed.
    ulong messages() @safe pure nothrow const @nogc {
        return messages_;
    }

    void setHomeSystem(System* sys) @safe pure nothrow @nogc {
        homeSystem_ = sys;
    }

    void cleanupBehavior() @trusted nothrow {
        foreach (ref a; incoming.byValue) {
            try {
                a.free;
            } catch (Exception e) {
                // TODO: call exceptionHandler?
            }
        }
        incoming = null;
        foreach (ref a; reqBehavior.byValue) {
            try {
                a.free;
            } catch (Exception e) {
            }
        }
        reqBehavior = null;
    }

    void cleanupAwait() @trusted nothrow {
        foreach (ref a; awaitedResponses.byValue) {
            try {
                a.behavior.free;
            } catch (Exception e) {
            }
        }
        awaitedResponses = null;
    }

    bool isAlive() @safe pure nothrow const @nogc {
        final switch (state_) {
        case ActorState.waiting:
            goto case;
        case ActorState.active:
            goto case;
        case ActorState.shutdown:
            goto case;
        case ActorState.forceShutdown:
            goto case;
        case ActorState.finishShutdown:
            return true;
        case ActorState.stopped:
            return false;
        }
    }

    bool isAccepting() @safe pure nothrow const @nogc {
        final switch (state_) {
        case ActorState.waiting:
            goto case;
        case ActorState.active:
            return true;
        case ActorState.shutdown:
            goto case;
        case ActorState.forceShutdown:
            goto case;
        case ActorState.finishShutdown:
            goto case;
        case ActorState.stopped:
            return false;
        }
    }

    ulong replyId() @safe {
        return nextReplyId++;
    }

    void process(const SysTime now) @safe nothrow {
        messages_ = 0;

        // philosophy of the order is that a timeout should only trigger if it
        // is really required thus it is checked last.  This order then mean
        // that a request may have triggered a timeout but because
        // `processReply` is called before `checkReplyTimeout` it is *ignored*.
        // Thus "better to accept even if it is timeout rather than fail".
        try {
            processSystemMsg();
            processDelayed(now);
            processIncoming();
            processReply();
            checkReplyTimeout(now);
        } catch (Exception e) {
            exceptionHandler_(this, e);
        }

        final switch (state_) {
        case ActorState.waiting:
            state_ = ActorState.active;
            break;
        case ActorState.active:
            // self terminate if the actor has no behavior.
            if (incoming.empty && awaitedResponses.empty
                    && reqBehavior.empty)
                state_ = ActorState.forceShutdown;
            break;
        case ActorState.shutdown:
            if (awaitedResponses.empty)
                state_ = ActorState.finishShutdown;
            cleanupBehavior;
            break;
        case ActorState.forceShutdown:
            state_ = ActorState.finishShutdown;
            cleanupBehavior;
            break;
        case ActorState.finishShutdown:
            state_ = ActorState.stopped;
            addr.setClosed;
            addr.shutdown;

            sendToMonitors(DownMsg(addr, lastError));
            monitors = null;

            sendToLinks(ExitMsg(addr, lastError));
            links = null;

            delayed = null;
            replyTimeouts = null;
            cleanupAwait;
            break;
        case ActorState.stopped:
            break;
        }
    }

    void sendToMonitors(DownMsg msg) @trusted nothrow {
        // trusted. OK because the constness is just some weird thing with inout and byKey.
        foreach (ref a; monitors.byValue) {
            try {
                if (a.isOpen)
                    a.sysMsg.put(SystemMsg(msg));
                a.release;
            } catch (Exception e) {
            }
        }
    }

    void sendToLinks(ExitMsg msg) @trusted nothrow {
        // trusted. OK because the constness is just some weird thing with inout and byKey.
        foreach (ref a; links.byValue) {
            try {
                if (a.isOpen)
                    a.sysMsg.put(SystemMsg(msg));
                a.release;
            } catch (Exception e) {
            }
        }
    }

    void checkReplyTimeout(const SysTime now) @safe {
        if (replyTimeouts.empty)
            return;

        size_t removeTo;
        foreach (const i; 0 .. replyTimeouts.length) {
            if (now > replyTimeouts[i].timeout) {
                const id = replyTimeouts[i].id;
                if (auto v = id in awaitedResponses) {
                    messages_++;
                    v.onError(this, ErrorMsg(addr, SystemError.requestTimeout));
                    try {
                        () @trusted { v.behavior.free; }();
                    } catch (Exception e) {
                    }
                    awaitedResponses.remove(id);
                }
                removeTo = i + 1;
            } else {
                break;
            }
        }

        if (removeTo >= replyTimeouts.length) {
            replyTimeouts = null;
        } else if (removeTo != 0) {
            replyTimeouts = replyTimeouts[removeTo .. $];
        }
    }

    void processIncoming() @safe {
        if (addr.incoming.empty)
            return;
        messages_++;

        auto front = addr.incoming.pop;

        void doSend() {
            if (auto v = front.signature in incoming) {
                (*v)(front.data);
            } else {
                defaultHandler_(this, front.data);
            }
        }

        void doRequest() @trusted {
            auto um = front.data.get!(Tuple!(ulong, RcAddress, Variant));

            if (auto v = front.signature in reqBehavior) {
                (*v)(um[2], um[0], um[1]);
                //um[1].release;
            } else {
                defaultHandler_(this, um[2]);
            }

            //um = typeof(um).init;
            //.destroy(front);
        }

        final switch (front.type) {
        case MsgType.oneShot:
            doSend();
            break;
        case MsgType.request:
            doRequest();
            break;
        }
    }

    /** All system messages are handled.
     *
     * Assuming:
     *  * they are not heavy to process
     *  * very important that if there are any they should be handled as soon as possible
     *  * ignoring the case when there is a "storm" of system messages which
     *    "could" overload the actor system and lead to a crash. I classify this,
     *    for now, as intentional, malicious coding by the developer themself.
     *    External inputs that could trigger such a behavior should be controlled
     *    and limited. Other types of input such as a developer trying to break
     *    the actor system is out of scope.
     */
    void processSystemMsg() @safe {
        while (!addr.sysMsg.empty) {
            messages_++;
            auto front = addr.sysMsg.pop;

            front.match!((ref DownMsg a) {
                if (downHandler_)
                    downHandler_(this, a);
            }, (ref MonitorRequest a) {
                monitors[a.addr.toHash] = a.addr;
                a.addr.release;
            }, (ref DemonitorRequest a) {
                monitors.remove(a.addr.toHash);
                a.addr.release;
            }, (ref LinkRequest a) {
                links[a.addr.toHash] = a.addr;
                a.addr.release;
            }, (ref UnlinkRequest a) {
                links.remove(a.addr.toHash);
                a.addr.release;
            }, (ref ErrorMsg a) { errorHandler_(this, a); a.source.release; }, (ref ExitMsg a) {
                exitHandler_(this, a);
            }, (ref SystemExitMsg a) {
                final switch (a.reason) {
                case ExitReason.normal:
                    break;
                case ExitReason.unhandledException:
                    exitHandler_(this, ExitMsg.init);
                    break;
                case ExitReason.unknown:
                    exitHandler_(this, ExitMsg.init);
                    break;
                case ExitReason.userShutdown:
                    exitHandler_(this, ExitMsg.init);
                    break;
                case ExitReason.kill:
                    exitHandler_(this, ExitMsg.init);
                    // the user do NOT have an option here
                    this.forceShutdown;
                    break;
                }
            });

            .destroy(front);
        }
    }

    void processReply() @safe {
        if (addr.replies.empty)
            return;
        messages_++;

        auto front = addr.replies.pop;

        if (auto v = front.id in awaitedResponses) {
            // TODO: reduce the lookups on front.id
            v.behavior(front.data);
            try {
                () @trusted { v.behavior.free; }();
            } catch (Exception e) {
            }
            awaitedResponses.remove(front.id);
            removeReplyTimeout(front.id);
        } else {
            // TODO: should probably be SystemError.unexpectedResponse?
            defaultHandler_(this, front.data);
        }
    }

    void processDelayed(const SysTime now) @trusted {
        if (!addr.delayed.empty) {
            // count as a message because handling them are "expensive".
            // Ignoring the case that the message right away is moved to the
            // incoming queue. This lead to "double accounting" but ohh well.
            // Don't use delayedSend when you should have used send.
            messages_++;
            delayed ~= addr.delayed.pop;
            if (delayed.length > 1)
                schwartzSort!(a => a.triggerAt, (a, b) => a < b)(delayed);
        } else if (delayed.empty) {
            return;
        }

        size_t removeTo;
        foreach (const i; 0 .. delayed.length) {
            if (now > delayed[i].triggerAt) {
                addr.incoming.put(delayed[i].msg);
                removeTo = i + 1;
            } else {
                break;
            }
        }

        if (removeTo >= delayed.length) {
            delayed = null;
        } else if (removeTo != 0) {
            delayed = delayed[removeTo .. $];
        }
    }

    private void removeReplyTimeout(ulong id) @safe nothrow {
        import std.algorithm : remove;

        foreach (const i; 0 .. replyTimeouts.length) {
            if (replyTimeouts[i].id == id) {
                remove(replyTimeouts, i);
                break;
            }
        }
    }

    void register(ulong signature, Closure!(MsgHandler, void*) handler) @trusted {
        if (!isAccepting)
            return;

        if (auto v = signature in incoming) {
            try {
                v.free;
            } catch (Exception e) {
            }
        }
        incoming[signature] = handler;
    }

    void register(ulong signature, Closure!(RequestHandler, void*) handler) @trusted {
        if (!isAccepting)
            return;

        if (auto v = signature in reqBehavior) {
            try {
                v.free;
            } catch (Exception e) {
            }
        }
        reqBehavior[signature] = handler;
    }

    void register(ulong replyId, SysTime timeout, Closure!(ReplyHandler,
            void*) reply, ErrorHandler onError) @safe {
        if (!isAccepting)
            return;

        awaitedResponses[replyId] = AwaitReponse(reply, onError is null ? errorHandler_ : onError);
        replyTimeouts ~= ReplyHandlerTimeout(replyId, timeout);
        schwartzSort!(a => a.timeout, (a, b) => a < b)(replyTimeouts);
    }
}

struct Closure(Fn, CtxT) {
    alias FreeFn = void function(CtxT);

    Fn fn;
    CtxT ctx;
    FreeFn cleanup;

    this(Fn fn) {
        this.fn = fn;
    }

    this(Fn fn, CtxT* ctx, FreeFn cleanup) {
        this.fn = fn;
        this.ctx = ctx;
        this.cleanup = cleanup;
    }

    void opCall(Args...)(auto ref Args args) {
        assert(fn !is null);
        fn(ctx, args);
    }

    void free() {
        // will crash, on purpuse, if there is a ctx and no cleanup registered.
        // maybe a bad idea? dunno... lets see
        if (ctx)
            cleanup(ctx);
        ctx = CtxT.init;
    }
}

@("shall register a behavior to be called when msg received matching signature")
unittest {
    auto addr = makeAddress;
    auto actor = Actor(addr);

    bool processedIncoming;
    void fn(void* ctx, ref Variant msg) {
        processedIncoming = true;
    }

    actor.register(1, Closure!(MsgHandler, void*)(&fn));
    addr.incoming.put(Msg(MsgType.oneShot, 1, Variant(42)));

    actor.process(Clock.currTime);

    assert(processedIncoming);
}

private void cleanupCtx(CtxT)(void* ctx)
        if (is(CtxT == Tuple!T, T) || is(CtxT == void)) {
    import std.traits;
    import my.actor.typed;

    static if (!is(CtxT == void)) {
        // trust that any use of this also pass on the correct context type.
        auto userCtx = () @trusted { return cast(CtxT*) ctx; }();
        //*userCtx = CtxT.init;
        // release the context such as if it holds a rc object.
        alias Types = CtxT.Types;
        static foreach (const i; 0 .. CtxT.Types.length) {
            {
                alias T = CtxT.Types[i];
                alias UT = Unqual!T;
                pragma(msg, "cleanupCtx " ~ T.stringof);
                static if (!is(T == UT)) {
                    static assert(!is(UT == RcAddress),
                            "RcAddress must NEVER be const or immutable");
                    static assert(!is(UT : TypedAddress!M, M...),
                            "RcAddress must NEVER be const or immutable: " ~ T.stringof);
                }
                static if (is(Unqual!T == T)) {
                    //pragma(msg, "mutable " ~ T.stringof ~ " " ~ typeof((*userCtx)[i]).stringof);
                    static if (is(hasElaborateDestructor!T == T) && is(T == struct)) {
                        pragma(msg, "xdtor");
                        (*userCtx)[i].__xdtor;
                    } else {
                        writeln("init " ~ T.stringof);
                        pragma(msg, "init");
                        (*userCtx)[i] = T.init;
                    }
                } else {
                    pragma(msg, "smurf " ~ T[i].stringof);
                }

                static if (is(UT == RcAddress)) {
                    pragma(msg, "smurf1");
                    (*userCtx)[i].release;
                } else static if (is(UT : TypedAddress!M, M...)) {
                    pragma(msg, "smurf2");
                    (*userCtx)[i].address.release;
                }

                // TODO: add a version actor_ctx_diagnostic that prints when it is unable to deinit?
            }
        }
    }
}

@("shall default initialize when possible, skipping const/immutable")
unittest {
    {
        auto x = tuple(cast(const) 42, 43);
        alias T = typeof(x);
        //pragma(msg, T);
        cleanupCtx!T(cast(void*)&x);
        assert(x[0] == 42); // can't assign to const
        assert(x[1] == 0);
    }

    {
        import my.path : Path;

        auto x = tuple(Path.init, cast(const) Path("foo"));
        alias T = typeof(x);
        cleanupCtx!T(cast(void*)&x);
        assert(x[0] == Path.init);
        assert(x[1] == Path("foo"));
    }
}

package struct Action {
    Closure!(MsgHandler, void*) action;
    ulong signature;
}

/// An behavior for an actor when it receive a message of `signature`.
package auto makeAction(T, CtxT = void)(T handler) @safe
        if (isFunction!T || isFunctionPointer!T) {
    static if (is(CtxT == void))
        alias Params = Parameters!T;
    else {
        alias CtxParam = Parameters!T[0];
        alias Params = Parameters!T[1 .. $];
        checkMatchingCtx!(CtxParam, CtxT);
        checkRefForContext!handler;
    }

    alias HArgs = staticMap!(Unqual, Params);

    void fn(void* ctx, ref Variant msg) @trusted {
        static if (is(CtxT == void)) {
            handler(msg.get!(Tuple!HArgs).expand);
            //pragma(msg, "setHandler. reuse data");
        } else {
            auto userCtx = cast(CtxParam*) cast(CtxT*) ctx;
            handler(*userCtx, msg.get!(Tuple!HArgs).expand);
            //pragma(msg, "setHandler. reuse data");
        }
    }

    return Action(typeof(Action.action)(&fn, null, &cleanupCtx!CtxT), makeSignature!HArgs);
}

package Closure!(ReplyHandler, void*) makeReply(T, CtxT)(T handler) @safe {
    static if (is(CtxT == void))
        alias Params = Parameters!T;
    else {
        alias CtxParam = Parameters!T[0];
        alias Params = Parameters!T[1 .. $];
        checkMatchingCtx!(CtxParam, CtxT);
        checkRefForContext!handler;
    }

    alias HArgs = staticMap!(Unqual, Params);

    void fn(void* ctx, ref Variant msg) @trusted {
        static if (is(CtxT == void)) {
            handler(msg.get!(Tuple!HArgs).expand);
            //pragma(msg, "setHandler. reuse data");
        } else {
            auto userCtx = cast(CtxParam*) cast(CtxT*) ctx;
            handler(*userCtx, msg.get!(Tuple!HArgs).expand);
            //pragma(msg, "setHandler. reuse data");
        }
    }

    return typeof(return)(&fn, null, &cleanupCtx!CtxT);
}

package struct Request {
    Closure!(RequestHandler, void*) request;
    ulong signature;
}

private string locToString(Loc...)() {
    import std.conv : to;

    return Loc[0] ~ ":" ~ Loc[1].to!string ~ ":" ~ Loc[2].to!string;
}

/// Check that the context parameter is `ref` otherwise issue a warning.
package void checkRefForContext(alias handler)() {
    import std.traits : ParameterStorageClass, ParameterStorageClassTuple;

    alias CtxParam = ParameterStorageClassTuple!(typeof(handler))[0];

    static if (CtxParam != ParameterStorageClass.ref_) {
        pragma(msg, "INFO: handler type is " ~ typeof(handler).stringof);
        static assert(CtxParam == ParameterStorageClass.ref_,
                "The context must be `ref` to avoid unnecessary copying");
    }
}

package void checkMatchingCtx(CtxParam, CtxT)() {
    static if (!is(CtxT == CtxParam)) {
        static assert(__traits(compiles, { auto x = CtxParam(CtxT.init.expand); }),
                "mismatch between the context type " ~ CtxT.stringof
                ~ " and the first parameter " ~ CtxParam.stringof);
    }
}

package auto makeRequest(T, CtxT = void)(T handler) @safe {
    static assert(!is(ReturnType!T == void), "handler returns void, not allowed");

    alias RType = ReturnType!T;
    enum isReqResult = is(RType : RequestResult!ReqT, ReqT);
    enum isPromise = is(RType : Promise!PromT, PromT);

    static if (is(CtxT == void))
        alias Params = Parameters!T;
    else {
        alias CtxParam = Parameters!T[0];
        alias Params = Parameters!T[1 .. $];
        checkMatchingCtx!(CtxParam, CtxT);
        checkRefForContext!handler;
    }

    alias HArgs = staticMap!(Unqual, Params);

    void fn(void* rawCtx, ref Variant msg, ulong replyId, scope RcAddress replyTo) @trusted {
        static if (is(CtxT == void)) {
            auto r = handler(msg.get!(Tuple!HArgs).expand);
            //pragma(msg, "setHandler. reuse data");
        } else {
            auto ctx = cast(CtxParam*) cast(CtxT*) rawCtx;
            auto r = handler(*ctx, msg.get!(Tuple!HArgs).expand);
            //pragma(msg, "setHandler. reuse data");
            scope (exit)
                msg = typeof(msg).init;
        }

        static if (isReqResult) {
            r.value.match!((ErrorMsg a) {
                // TODO: replace null with the actor sending the message.
                sendSystemMsg(replyTo, a);
            }, (Promise!ReqT a) {
                assert(!a.data.empty, "the promise MUST be constructed before it is returned");
                a.data.replyId = replyId;
                a.data.replyTo = replyTo;
            }, (data) {
                // TODO: is this syntax for U one variable or variable. I want it to be variable.
                enum wrapInTuple = !is(typeof(data) : Tuple!U, U);
                if (replyTo().isOpen) {
                    static if (wrapInTuple)
                        replyTo().replies.put(Reply(replyId, Variant(tuple(data))));
                    else
                        replyTo().replies.put(Reply(replyId, Variant(data)));
                } else {
                }
            });
        } else static if (isPromise) {
            r.data.replyId = replyId;
            r.data.replyTo = replyTo;
        } else {
            // TODO: is this syntax for U one variable or variable. I want it to be variable.
            enum wrapInTuple = !is(RType : Tuple!U, U);
            if (replyTo().isOpen) {
                static if (wrapInTuple)
                    replyTo().replies.put(Reply(replyId, Variant(tuple(r))));
                else
                    replyTo().replies.put(Reply(replyId, Variant(r)));
            } else {
            }

            () @trusted {
                if (!replyTo.empty)
                    printf("e %lx %d\n", replyTo.toHash, replyTo.addr.refCount);
            }();
        }
    }

    return Request(typeof(Request.request)(&fn, null, &cleanupCtx!CtxT), makeSignature!HArgs);
}

@("shall link two actors lifetime")
unittest {
    int count;
    void countExits(ref Actor self, ExitMsg msg) @safe nothrow {
        count++;
        self.shutdown;
    }

    auto aa1 = Actor(makeAddress);
    auto a1 = build(&aa1).set((int x) {}).exitHandler_(&countExits).finalize;
    auto aa2 = Actor(makeAddress);
    auto a2 = build(&aa2).set((int x) {}).exitHandler_(&countExits).finalize;

    a1.linkTo(a2.address);
    a1.process(Clock.currTime);
    a2.process(Clock.currTime);

    assert(a1.isAlive);
    assert(a2.isAlive);

    sendExit(a1.address, ExitReason.userShutdown);
    foreach (_; 0 .. 3) {
        a1.process(Clock.currTime);
        a2.process(Clock.currTime);
    }

    assert(!a1.isAlive);
    assert(!a2.isAlive);
    assert(count == 2);
}

@("shall let one actor monitor the lifetime of the other one")
unittest {
    int count;
    void downMsg(ref Actor self, DownMsg msg) @safe nothrow {
        count++;
    }

    auto aa1 = Actor(makeAddress);
    auto a1 = build(&aa1).set((int x) {}).downHandler_(&downMsg).finalize;
    auto aa2 = Actor(makeAddress);
    auto a2 = build(&aa2).set((int x) {}).finalize;

    a1.monitor(a2.address);
    a1.process(Clock.currTime);
    a2.process(Clock.currTime);

    assert(a1.isAlive);
    assert(a2.isAlive);

    sendExit(a2.address, ExitReason.userShutdown);
    foreach (_; 0 .. 3) {
        a1.process(Clock.currTime);
        a2.process(Clock.currTime);
    }

    assert(a1.isAlive);
    assert(!a2.isAlive);
    assert(count == 1);
}

private struct BuildActor {
    import std.traits : isDelegate;

    Actor* actor;

    Actor* finalize() @safe {
        auto rval = actor;
        actor = null;
        return rval;
    }

    auto errorHandler(ErrorHandler a) {
        actor.errorHandler = a;
        return this;
    }

    auto downHandler_(DownHandler a) {
        actor.downHandler_ = a;
        return this;
    }

    auto exitHandler_(ExitHandler a) {
        actor.exitHandler_ = a;
        return this;
    }

    auto exceptionHandler_(ExceptionHandler a) {
        actor.exceptionHandler_ = a;
        return this;
    }

    auto defaultHandler_(DefaultHandler a) {
        actor.defaultHandler_ = a;
        return this;
    }

    auto set(BehaviorT)(BehaviorT behavior)
            if ((isFunction!BehaviorT || isFunctionPointer!BehaviorT)
                && !is(ReturnType!BehaviorT == void)) {
        auto act = makeRequest(behavior);
        actor.register(act.signature, act.request);
        return this;
    }

    auto set(BehaviorT, CT)(BehaviorT behavior, CT c)
            if ((isFunction!BehaviorT || isFunctionPointer!BehaviorT)
                && !is(ReturnType!BehaviorT == void)) {
        auto act = makeRequest!(BehaviorT, CT)(behavior);
        // for now just use the GC to allocate the context on.
        // TODO: use an allocator.
        act.request.ctx = cast(void*) new CT(c);
        actor.register(act.signature, act.request);
        return this;
    }

    auto set(BehaviorT)(BehaviorT behavior)
            if ((isFunction!BehaviorT || isFunctionPointer!BehaviorT)
                && is(ReturnType!BehaviorT == void)) {
        auto act = makeAction(behavior);
        actor.register(act.signature, act.action);
        return this;
    }

    auto set(BehaviorT, CT)(BehaviorT behavior, CT c)
            if ((isFunction!BehaviorT || isFunctionPointer!BehaviorT)
                && is(ReturnType!BehaviorT == void)) {
        auto act = makeAction!(BehaviorT, CT)(behavior);
        // for now just use the GC to allocate the context on.
        // TODO: use an allocator.
        act.action.ctx = cast(void*) new CT(c);
        actor.register(act.signature, act.action);
        return this;
    }
}

package BuildActor build(Actor* a) @safe {
    return BuildActor(a);
}

/// Implement an actor.
Actor* impl(Behavior...)(Actor* self, Behavior behaviors) {
    import my.actor.msg : isCapture, Capture;

    auto bactor = build(self);
    static foreach (const i; 0 .. Behavior.length) {
        {
            alias b = Behavior[i];

            static if (!isCapture!b) {
                static if (!(isFunction!(b) || isFunctionPointer!(b)))
                    static assert(0, "behavior may only be functions, not delgates: " ~ b.stringof);

                static if (i + 1 < Behavior.length && isCapture!(Behavior[i + 1])) {
                    bactor.set(behaviors[i], behaviors[i + 1]);
                } else
                    bactor.set(behaviors[i]);
            }
        }
    }

    return bactor.finalize;
}

@("build dynamic actor from functions")
unittest {
    static void fn3(int s) @safe {
    }

    static string fn4(int s) @safe {
        return "foo";
    }

    static Tuple!(int, string) fn5(const string s) @safe {
        return typeof(return)(42, "hej");
    }

    auto aa1 = Actor(makeAddress);
    auto a1 = build(&aa1).set(&fn3).set(&fn4).set(&fn5).finalize;
}

unittest {
    bool delayOk;
    static void fn1(ref Tuple!(bool*, "delayOk") c, const string s) @safe {
        *c.delayOk = true;
    }

    bool delayShouldNeverHappen;
    static void fn2(ref Tuple!(bool*, "delayShouldNeverHappen") c, int s) @safe {
        *c.delayShouldNeverHappen = true;
    }

    auto aa1 = Actor(makeAddress);
    auto actor = build(&aa1).set(&fn1, capture(&delayOk)).set(&fn2,
            capture(&delayShouldNeverHappen)).finalize;
    delayedSend(actor.address, Clock.currTime - 1.dur!"seconds", "foo");
    delayedSend(actor.address, Clock.currTime + 1.dur!"hours", 42);

    assert(!actor.addressRef.delayed.empty);
    assert(actor.addressRef.incoming.empty);
    assert(actor.addressRef.replies.empty);

    actor.process(Clock.currTime);

    assert(!actor.addressRef.delayed.empty);
    assert(actor.addressRef.incoming.empty);
    assert(actor.addressRef.replies.empty);

    actor.process(Clock.currTime);

    assert(actor.addressRef.delayed.empty);
    assert(actor.addressRef.incoming.empty);
    assert(actor.addressRef.replies.empty);

    assert(delayOk);
    assert(!delayShouldNeverHappen);
}

@("shall process a request->then chain")
unittest {
    // checking capture is correctly setup/teardown by using captured rc.

    auto rcReq = refCounted(42);
    bool calledOk;
    static string fn(ref Tuple!(bool*, "calledOk", RefCounted!int) ctx, const string s,
            const string b) {
        assert(2 == ctx[1].refCount);
        if (s == "apa")
            *ctx.calledOk = true;
        return "foo";
    }

    auto rcReply = refCounted(42);
    bool calledReply;
    static void reply(ref Tuple!(bool*, RefCounted!int) ctx, const string s) {
        *ctx[0] = s == "foo";
        assert(2 == ctx[1].refCount);
    }

    auto aa1 = Actor(makeAddress);
    auto actor = build(&aa1).set(&fn, capture(&calledOk, rcReq)).finalize;

    assert(2 == rcReq.refCount);
    assert(1 == rcReply.refCount);

    () @trusted {
        actor.request(actor.address, infTimeout).send("apa", "foo")
            .capture(&calledReply, rcReply).then(&reply);
    }();
    assert(2 == rcReply.refCount);

    assert(!actor.addr.incoming.empty);
    assert(actor.addr.replies.empty);

    actor.process(Clock.currTime);
    assert(actor.addr.incoming.empty);
    assert(actor.addr.replies.empty);

    assert(calledOk);
    assert(calledReply);

    assert(2 == rcReq.refCount);
    assert(1 == rcReply.refCount);
}

@("shall process a request->then chain using promises")
unittest {
    static struct A {
        string v;
    }

    static struct B {
        string v;
    }

    int calledOk;
    auto fn1p = makePromise!string;
    static RequestResult!string fn1(ref Capture!(int*, "calledOk", Promise!string, "p") c, A a) @trusted {
        if (a.v == "apa")
            (*c.calledOk)++;
        return typeof(return)(c.p);
    }

    auto fn2p = makePromise!string;
    static Promise!string fn2(ref Capture!(int*, "calledOk", Promise!string, "p") c, B a) {
        (*c.calledOk)++;
        return c.p;
    }

    int calledReply;
    static void reply(ref Tuple!(int*) ctx, const string s) {
        if (s == "foo")
            *ctx[0] += 1;
    }

    auto aa1 = Actor(makeAddress);
    auto actor = build(&aa1).set(&fn1, capture(&calledOk, fn1p)).set(&fn2,
            capture(&calledOk, fn2p)).finalize;

    actor.request(actor.address, infTimeout).send(A("apa")).capture(&calledReply).then(&reply);
    actor.request(actor.address, infTimeout).send(B("apa")).capture(&calledReply).then(&reply);

    actor.process(Clock.currTime);
    assert(calledOk == 1); // first request
    assert(calledReply == 0);

    fn1p.deliver("foo");

    assert(calledReply == 0);

    actor.process(Clock.currTime);
    assert(calledOk == 2); // second request triggered
    assert(calledReply == 1);

    fn2p.deliver("foo");
    actor.process(Clock.currTime);

    assert(calledReply == 2);
}

/// The timeout triggered.
class ScopedActorException : Exception {
    this(ScopedActorError err, string file = __FILE__, int line = __LINE__) @safe pure nothrow {
        super(null, file, line);
        error = err;
    }

    ScopedActorError error;
}

enum ScopedActorError : ubyte {
    none,
    // actor address is down
    down,
    // request timeout
    timeout,
    // the address where unable to process the received message
    unknownMsg,
    // some type of fatal error occured.
    fatal,
}

/** Intended to be used in a local scope by a user.
 *
 * `ScopedActor` is not thread safe.
 */
struct ScopedActor {
    import my.actor.typed : underlyingAddress;

    private {
        static struct Data {
            Actor self;
            ScopedActorError errSt;

            ~this() @safe {
                if (self.addr.empty)
                    return;

                while (self.isAlive)
                    self.process(Clock.currTime);
                self.process(Clock.currTime);
            }
        }

        RefCounted!Data data;
    }

    this(RcAddress addr) @safe {
        data = refCounted(Data(Actor(addr), ScopedActorError.none));
        data.self.name = "ScopedActor";
    }

    private void reset() @safe nothrow {
        data.errSt = ScopedActorError.none;
    }

    private void downHandler(ref Actor, DownMsg) @safe nothrow {
        data.errSt = ScopedActorError.down;
    }

    private void errorHandler(ref Actor, ErrorMsg msg) @safe nothrow {
        if (msg.reason == SystemError.requestTimeout)
            data.errSt = ScopedActorError.timeout;
        else
            data.errSt = ScopedActorError.fatal;
    }

    private void unknownMsgHandler(ref Actor a, ref Variant msg) @safe nothrow {
        logAndDropHandler(a, msg);
        data.errSt = ScopedActorError.unknownMsg;
    }

    SRequestSend request(TAddress)(TAddress requestTo, SysTime timeout) {
        reset;
        auto addr = underlyingAddress(requestTo);
        auto rs = .request(&data.self, addr, timeout);
        return SRequestSend(rs, this);
    }

    private static struct SRequestSend {
        RequestSend rs;
        ScopedActor self;

        SRequestSendThen send(Args...)(auto ref Args args) {
            return SRequestSendThen(.send(rs, args), self);
        }
    }

    private static struct SRequestSendThen {
        RequestSendThen rs;
        ScopedActor self;

        uint backoff;
        void dynIntervalSleep() @trusted {
            // +100 usecs "feels good", magic number. current OS and
            // implementation of message passing isn't that much faster than
            // 100us. A bit slow behavior, ehum, for a scoped actor is OK. They
            // aren't expected to be used for "time critical" sections.
            Thread.sleep(backoff.dur!"usecs");
            backoff = min(backoff + 100, 20000);
        }

        void then(T)(T handler, ErrorHandler onError = null) {
            scope (exit)
                demonitor(rs.rs.self, rs.rs.requestTo);
            monitor(rs.rs.self, rs.rs.requestTo);

            () @trusted { .thenUnsafe!(T, void)(rs, handler, null, onError); }();

            self.data.self.downHandler = &self.downHandler;
            self.data.self.defaultHandler = &self.unknownMsgHandler;
            self.data.self.errorHandler = &self.errorHandler;

            // TODO: this loop is stupid... should use a conditional variable
            // instead but that requires changing the mailbox. later
            do {
                rs.rs.self.process(Clock.currTime);
                // force the actor to be alive even though there are no behaviors.
                rs.rs.self.state_ = ActorState.waiting;

                if (self.data.errSt == ScopedActorError.none) {
                    dynIntervalSleep;
                    if (!rs.rs.requestTo.isOpen) {
                        self.data.errSt = ScopedActorError.down;
                    }
                } else {
                    throw new ScopedActorException(self.data.errSt);
                }
            }
            while (rs.rs.self.messages == 0);
        }
    }
}

ScopedActor scopedActor() @safe {
    return ScopedActor(makeAddress);
}

@(
        "scoped actor shall throw an exception if the actor that is sent a request terminates or is closed")
unittest {
    import my.actor.system;

    auto sys = makeSystem;

    auto a0 = sys.spawn((Actor* self) {
        return impl(self, (ref CSelf!() ctx, int x) {
            Thread.sleep(50.dur!"msecs");
            return 42;
        }, capture(self), (ref CSelf!() ctx, double x) {}, capture(self),
            (ref CSelf!() ctx, string x) { ctx.self.shutdown; return 42; }, capture(self));
    });

    {
        auto self = scopedActor;
        bool excThrown;
        auto stopAt = Clock.currTime + 1.dur!"seconds";
        while (!excThrown && Clock.currTime < stopAt) {
            try {
                self.request(a0, delay(1.dur!"nsecs")).send(42).then((int x) {});
            } catch (ScopedActorException e) {
                excThrown = e.error == ScopedActorError.timeout;
            } catch (Exception e) {
                logger.info(e.msg);
            }
        }
        assert(excThrown, "timeout did not trigger as expected");
    }
    logger.info(".....");

    //{
    //    auto self = scopedActor;
    //    bool excThrown;
    //    auto stopAt = Clock.currTime + 100.dur!"msecs";
    //    while (!excThrown && Clock.currTime < stopAt) {
    //        try {
    //            self.request(a0, delay(1.dur!"seconds")).send("hello").then((int x) {
    //            });
    //        } catch (ScopedActorException e) {
    //            excThrown = e.error == ScopedActorError.down;
    //        } catch (Exception e) {
    //            logger.info(e.msg);
    //        }
    //    }
    //    assert(excThrown, "detecting terminated actor did not trigger as expected");
    //}
}
