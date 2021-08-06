/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.msg;

import logger = std.experimental.logger;
import std.meta : staticMap, AliasSeq;
import std.traits : Unqual, Parameters, isFunction, isFunctionPointer;
import std.typecons : Tuple, tuple;
import std.variant : Variant;

public import std.datetime : SysTime, Duration, dur;

import my.actor.mailbox;
import my.actor.common : ExitReason, makeSignature, SystemError;
import my.actor.actor : Actor, makeAction, makeRequest, makeReply, makePromise,
    ErrorHandler, Promise, RequestResult;
import my.actor.system_msg;
import my.actor.typed : isTypedAddress, isTypedActor, isTypedActorImpl,
    typeCheckMsg, ParamsToTuple, ReturnToTupleOrVoid,
    underlyingActor, underlyingAddress, underlyingTypedAddress, underlyingWeakAddress;

SysTime infTimeout() @safe pure nothrow {
    return SysTime.max;
}

SysTime timeout(Duration d) @safe nothrow {
    import std.datetime : Clock;

    return Clock.currTime + d;
}

/// Code looks better if it says delay when using delayedSend.
alias delay = timeout;

enum isActor(T) = is(T == Actor*) || isTypedActor!T || isTypedActorImpl!T;
enum isAddress(T) = is(T == WeakAddress) || is(T == StrongAddress) || isTypedAddress!T;
enum isDynamicAddress(T) = is(T == WeakAddress) || is(T == StrongAddress);

/** Link the lifetime of `self` to the actor using `sendTo`.
 *
 * An `ExitMsg` is sent to `self` if `sendTo` is terminated and vice versa.
 *
 * `ExitMsg` triggers `exitHandler`.
 */
void linkTo(AddressT0, AddressT1)(AddressT0 self, AddressT1 sendTo) @safe
        if ((isActor!AddressT0 || isAddress!AddressT0) && (isActor!AddressT1
            || isAddress!AddressT1)) {
    import my.actor.mailbox : LinkRequest;

    auto self_ = underlyingAddress(self);
    auto addr = underlyingAddress(sendTo);

    if (self_.empty || addr.empty)
        return;

    sendSystemMsg(self_, LinkRequest(addr.weakRef));
    sendSystemMsg(addr, LinkRequest(self_.weakRef));
}

/// Remove the link between `self` and the actor using `sendTo`.
void unlinkTo(AddressT0, AddressT1)(AddressT0 self, AddressT1 sendTo) @safe
        if ((isActor!AddressT0 || isAddress!AddressT0) && (isActor!AddressT1
            || isAddress!AddressT1)) {
    import my.actor.mailbox : UnlinkRequest;

    auto self_ = underlyingAddress(self);
    auto addr = underlyingAddress(sendTo);

    if (self_.empty || addr.empty)
        return;

    sendSystemMsg(self_, UnlinkRequest(addr.weakRef));
    sendSystemMsg(addr, UnlinkRequest(self_.weakRef));
}

/** Actor `self` will receive a `DownMsg` when `sendTo` shutdown.
 *
 * `DownMsg` triggers `downHandler`.
 */
void monitor(AddressT0, AddressT1)(AddressT0 self, AddressT1 sendTo) @safe
        if ((isActor!AddressT0 || isAddress!AddressT0) && (isActor!AddressT1
            || isAddress!AddressT1)) {
    import my.actor.system_msg : MonitorRequest;

    auto self_ = underlyingAddress(self);
    auto addr = underlyingAddress(sendTo);

    if (self_.empty || addr.empty)
        return;

    sendSystemMsg(addr, MonitorRequest(self_.weakRef));
}

/// Remove `self` as a monitor of the actor using `sendTo`.
void demonitor(AddressT0, AddressT1)(AddressT0 self, AddressT1 sendTo) @safe
        if ((isActor!AddressT0 || isAddress!AddressT0) && (isActor!AddressT1
            || isAddress!AddressT1)) {
    import my.actor.system_msg : MonitorRequest;

    auto self_ = underlyingAddress(self);
    auto addr = underlyingAddress(sendTo);

    if (self_.empty || addr.empty)
        return;

    sendSystemMsg(addr, DemonitorRequest(self_.weakRef));
}

// Only send the message if the system message queue is empty.
package void sendSystemMsgIfEmpty(AddressT, T)(AddressT sendTo, T msg) @safe
        if (isAddress!AddressT)
in (!sendTo.empty, "cannot sent to empty address") {
    if (sendTo.empty)
        return;

    auto addr = underlyingAddress(sendTo);

    if (!addr.empty && addr.isOpen && addr.safeGet.empty!SystemMsg)
        addr.put(SystemMsg(msg));
}

package void sendSystemMsg(AddressT, T)(AddressT sendTo, T msg) @safe
        if (isAddress!AddressT)
in (!sendTo.empty, "cannot sent to empty address") {
    if (sendTo.empty)
        return;

    auto addr = underlyingAddress(sendTo);
    static assert(is(typeof(addr) == StrongAddress), "address is " ~ typeof(addr).stringof);

    if (!addr.empty && addr.isOpen)
        addr.trustedGet.put(SystemMsg(msg));
}

/// Trigger the message in the future.
void delayedSend(AddressT, Args...)(AddressT sendTo, SysTime delayTo, auto ref Args args) @trusted
        if (is(AddressT == WeakAddress) || is(AddressT == StrongAddress) || is(AddressT == Actor*)) {
    alias UArgs = staticMap!(Unqual, Args);
    auto addr = underlyingAddress(sendTo);
    if (!addr.empty && addr.isOpen)
        addr.put(DelayedMsg(Msg(MsgType.oneShot, makeSignature!UArgs,
                Variant(Tuple!UArgs(args))), delayTo));
}

void sendExit(WeakAddress sendTo, const ExitReason reason) @safe {
    import my.actor.system_msg : SystemExitMsg;

    sendSystemMsg(sendTo, SystemExitMsg(reason));
}

// TODO: add verification that args do not have interior pointers
void send(AddressT, Args...)(AddressT sendTo, auto ref Args args) @trusted
        if (isDynamicAddress!AddressT || is(AddressT == Actor*)) {
    alias UArgs = staticMap!(Unqual, Args);
    auto addr = underlyingAddress(sendTo);
    if (!addr.empty && addr.isOpen)
        addr.put(Msg(MsgType.oneShot, makeSignature!UArgs, Variant(Tuple!UArgs(args))));
}

package struct RequestSend {
    Actor* self;
    WeakAddress requestTo;
    SysTime timeout;
    ulong replyId;

    /// Copy constructor
    this(ref return scope typeof(this) rhs) @safe pure nothrow @nogc {
        self = rhs.self;
        requestTo = rhs.requestTo;
        timeout = rhs.timeout;
        replyId = rhs.replyId;
    }

    @disable this(this);
}

package struct RequestSendThen {
    RequestSend rs;
    Msg msg;

    @disable this(this);

    /// Copy constructor
    this(ref return typeof(this) rhs) {
        rs = rhs.rs;
        msg = rhs.msg;
    }
}

RequestSend request(ActorT)(ActorT self, WeakAddress requestTo, SysTime timeout)
        if (is(ActorT == Actor*)) {
    return RequestSend(self, requestTo, timeout, self.replyId);
}

RequestSendThen send(Args...)(RequestSend r, auto ref Args args) {
    alias UArgs = staticMap!(Unqual, Args);

    auto replyTo = r.self.addr.weakRef;

    () @trusted { logger.info(r.self.addr, " ", replyTo); }();

    // dfmt off
    auto msg = Msg(
        MsgType.request,
        makeSignature!UArgs,
        () @trusted {
        return Variant(Tuple!(ulong, WeakAddress, Variant)(r.replyId, replyTo, Variant(Tuple!UArgs(args))));
        }()
    );
    // dfmt on

    return () @trusted { return RequestSendThen(r, msg); }();
}

private struct ThenContext(Captures...) {
    alias Ctx = Tuple!Captures;

    RequestSendThen r;
    Ctx* ctx;

    void then(T)(T handler, ErrorHandler onError = null)
            if (isFunction!T || isFunctionPointer!T) {
        thenUnsafe!(T, Ctx)(r, handler, cast(void*) ctx, onError);
        ctx = null;
    }
}

// allows delegates but the context for them may be corrupted by the GC if they
// are used in another thread thus use of `thenUnsafe` must ensure it is not
// escaped.
package void thenUnsafe(T, CtxT = void)(scope RequestSendThen r, T handler,
        void* ctx, ErrorHandler onError = null) @trusted {
    auto requestTo = r.rs.requestTo.lock;
    if (!requestTo)
        return; // TODO: should probably be an error sent via onError.

    if (!requestTo.trustedGet.isOpen) {
        if (onError)
            onError(*r.rs.self, ErrorMsg(r.rs.requestTo, SystemError.requestReceiverDown));
        return;
    }

    // why is this inferred as scoped?
    SysTime timeout = () @trusted { return r.rs.timeout; }();

    // first register a handler for the message.
    // this order ensure that there is always a handler that can receive the message.

    () @safe {
        auto reply = makeReply!(T, CtxT)(handler);
        reply.ctx = ctx;
        // TODO: compiler bug? how can SysTime be inferred to being scoped?
        SysTime timeout = () @trusted { return r.rs.timeout; }();
        r.rs.self.register(r.rs.replyId, timeout, reply, onError);
    }();

    // then send it
    requestTo.trustedGet.put(r.msg);
}

void then(T, CtxT = void)(scope RequestSendThen r, T handler, ErrorHandler onError = null) @trusted
        if (isFunction!T || isFunctionPointer!T) {
    thenUnsafe!(T, CtxT)(r, handler, null, onError);
}

void send(T, Args...)(T sendTo, auto ref Args args)
        if ((isTypedAddress!T || isTypedActorImpl!T) && typeCheckMsg!(T, void, Args)) {
    send(underlyingAddress(sendTo), args);
}

void delayedSend(T, Args...)(T sendTo, SysTime delayTo, auto ref Args args)
        if ((isTypedAddress!T || isTypedActorImpl!T) && typeCheckMsg!(T, void, Args)) {
    delayedSend(underlyingAddress(sendTo), delayTo, args);
}

private struct TypedRequestSend(TAddress) {
    alias TypeAddress = TAddress;
    RequestSend rs;
}

TypedRequestSend!TAddress request(TActor, TAddress)(ref TActor self, TAddress sendTo,
        SysTime timeout)
        if (isActor!TActor && (isTypedActorImpl!TAddress || isTypedAddress!TAddress)) {
    return typeof(return)(.request(underlyingActor(self), underlyingWeakAddress(sendTo), timeout));
}

private struct TypedRequestSendThen(TAddress, Params_...) {
    alias TypeAddress = TAddress;
    alias Params = Params_;
    RequestSendThen rs;

    /// Copy constructor
    this(ref return scope typeof(this) rhs) {
        rs = rhs.rs;
    }

    @disable this(this);
}

auto send(TR, Args...)(scope TR tr, auto ref Args args)
        if (is(TR == TypedRequestSend!TAddress, TAddress)) {
    return TypedRequestSendThen!(TR.TypeAddress, Args)(send(tr.rs, args));
}

void then(TR, T, CtxT = void)(scope TR tr, T handler, ErrorHandler onError = null)
        if ((isFunction!T || isFunctionPointer!T) && is(TR : TypedRequestSendThen!(TAddress,
            Params), TAddress, Params...) && typeCheckMsg!(TAddress,
            ParamsToTuple!(Parameters!T), Params)) {
    then(tr.rs, handler, onError);
}

private struct TypedThenContext(TR, Captures...) {
    import my.actor.actor : checkRefForContext, checkMatchingCtx;

    alias Ctx = Tuple!Captures;

    TR r;
    Ctx* ctx;

    void then(T)(T handler, ErrorHandler onError = null)
            if ((isFunction!T || isFunctionPointer!T) && typeCheckMsg!(TR.TypeAddress,
                ParamsToTuple!(Parameters!T[1 .. $]), TR.Params)) {
        // better error message for the user by checking in the body instead of
        // the constraint because the constraint gagges the static assert
        // messages.
        checkMatchingCtx!(Parameters!T[0], Ctx);
        checkRefForContext!handler;
        .thenUnsafe!(T, Ctx)(r.rs, handler, cast(void*) ctx, onError);
        ctx = null;
    }
}

alias Capture(T...) = Tuple!T;
enum isCapture(T) = is(T == Tuple!U, U);
enum isFirstParamCtx(Fn, CtxT) = is(Parameters!Fn[0] == CtxT);

/// Convenient function for capturing the actor itself when spawning.
alias CSelf(T = Actor*) = Capture!(T, "self");

Capture!T capture(T...)(auto ref T args)
        if (!is(T[0] == RequestSendThen)
            && !is(T[0] == TypedRequestSendThen!(TAddress, Params), TAddress, Params...)) {
    return Tuple!T(args);
}

auto capture(Captures...)(RequestSendThen r, auto ref Captures captures) {
    // TODO: how to read the identifiers from captures? Using
    // ParameterIdentifierTuple didn't work.
    auto ctx = new Tuple!Captures(captures);
    return ThenContext!Captures(r, ctx);
}

auto capture(TR, Captures...)(TR r, auto ref Captures captures)
        if (is(TR : TypedRequestSendThen!(TAddress, Params), TAddress, Params...)) {
    auto ctx = new Tuple!Captures(captures);
    return TypedThenContext!(TR, Captures)(r, ctx);
}