/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.system;

import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import logger = std.experimental.logger;
import std.algorithm : min, max;
import std.datetime : dur, Clock, Duration;
import std.parallelism : Task, TaskPool, task;
import std.traits : Parameters, ReturnType;

import my.optional;

public import my.actor.typed;
public import my.actor.actor : Actor, build, makePromise, Promise, scopedActor, impl;
public import my.actor.mailbox : Address, makeAddress2, WeakAddress;
public import my.actor.msg;
import my.actor.common;
import my.actor.memory : ActorAlloc;

System makeSystem(TaskPool pool) @safe {
    return System(pool, false);
}

System makeSystem() @safe {
    return System(new TaskPool, true);
}

struct SystemConfig {
    static struct Scheduler {
        // number of messages each actor is allowed to consume per scheduled run.
        Optional!ulong maxThroughput;
        // how long a worker sleeps before polling the actor queue.
        Optional!Duration pollInterval;
    }

    Scheduler scheduler;
}

struct System {
    import std.functional : forward;

    private {
        bool running;
        bool ownsPool;
        TaskPool pool;
        Backend bg;
    }

    @disable this(this);

    this(TaskPool pool, bool ownsPool) @safe {
        this(SystemConfig.init, pool, ownsPool);
    }

    /**
     * Params:
     *  pool = thread pool to use for scheduling actors.
     */
    this(SystemConfig conf, TaskPool pool, bool ownsPool) @safe {
        this.pool = pool;
        this.ownsPool = ownsPool;
        this.bg = Backend(new Scheduler(conf.scheduler, pool));

        this.running = true;
        this.bg.start(pool, pool.size);
    }

    ~this() @safe {
        shutdown;
    }

    void shutdown() @safe {
        if (!running)
            return;

        bg.shutdown;
        if (ownsPool)
            pool.finish(true);
        pool = null;

        running = false;
    }

    /// spawn dynamic actor.
    WeakAddress spawn(Fn, Args...)(Fn fn, auto ref Args args)
            if (is(Parameters!Fn[0] == Actor*) && is(ReturnType!Fn == Actor*)) {
        auto actor = bg.alloc.make(makeAddress2);
        return schedule(fn(actor, forward!args));
    }

    /// spawn typed actor.
    auto spawn(Fn, Args...)(Fn fn, auto ref Args args)
            if (isTypedActorImpl!(Parameters!(Fn)[0])) {
        alias ActorT = TypedActor!(Parameters!(Fn)[0].AllowedMessages);
        auto actor = bg.alloc.make(makeAddress2);
        auto impl = fn(ActorT.Impl(actor), forward!args);
        schedule(actor);
        return impl.address;
    }

    // schedule an actor for execution in the thread pool.
    // Returns: the address of the actor.
    private WeakAddress schedule(Actor* actor) @safe {
        actor.setHomeSystem(&this);
        bg.scheduler.putWaiting(actor);
        return actor.address;
    }
}

@("shall start an actor system, execute an actor and shutdown")
@safe unittest {
    auto sys = makeSystem;

    int hasExecutedWith42;
    static void fn(ref Capture!(int*, "hasExecutedWith42") c, int x) {
        if (x == 42)
            (*c.hasExecutedWith42)++;
    }

    auto addr = sys.spawn((Actor* a) => build(a).set(&fn, capture(&hasExecutedWith42)).finalize);
    send(addr, 42);
    send(addr, 43);

    const failAfter = Clock.currTime + 3.dur!"seconds";
    const start = Clock.currTime;
    while (hasExecutedWith42 == 0 && Clock.currTime < failAfter) {
    }
    const td = Clock.currTime - start;

    assert(hasExecutedWith42 == 1);
    assert(td < 3.dur!"seconds");
}

@("shall be possible to send a message to self during construction")
unittest {
    auto sys = makeSystem;

    int hasExecutedWith42;
    static void fn(ref Capture!(int*, "hasExecutedWith42") c, int x) {
        if (x == 42)
            (*c.hasExecutedWith42)++;
    }

    auto addr = sys.spawn((Actor* self) {
        send(self, 42);
        return impl(self, &fn, capture(&hasExecutedWith42));
    });
    send(addr, 42);
    send(addr, 43);

    const failAfter = Clock.currTime + 3.dur!"seconds";
    while (hasExecutedWith42 < 2 && Clock.currTime < failAfter) {
    }

    assert(hasExecutedWith42 == 2);
}

@("shall spawn two typed actors which are connected, execute and shutdow")
@safe unittest {
    import std.typecons : Tuple;

    auto sys = makeSystem;

    alias A1 = typedActor!(int function(int), string function(int, int));
    alias A2 = typedActor!(int function(int));

    auto spawnA1(A1.Impl self) {
        return my.actor.typed.impl(self, (int a) { return a + 10; }, (int a, int b) => "hej");
    }

    auto a1 = sys.spawn(&spawnA1);

    // final result from A2's continuation.
    auto spawnA2(A2.Impl self) {
        return my.actor.typed.impl(self, (ref Capture!(A2.Impl, "self", A1.Address, "a1") c, int x) {
            auto p = makePromise!int;
            // dfmt off
            c.self.request(c.a1, infTimeout)
                .send(x + 10)
                .capture(p)
                .then((ref Tuple!(Promise!int, "p") ctx, int a) { ctx.p.deliver(a); });
            // dfmt on
            return p;
        }, capture(self, a1));
    }

    auto a2 = sys.spawn(&spawnA2);

    auto self = scopedActor;
    int ok;
    // start msg to a2 which pass it on to a1.
    self.request(a2, infTimeout).send(10).then((int x) { ok = x; });

    assert(ok == 30);
}

private:
@safe:

struct Backend {
    Scheduler scheduler;
    ActorAlloc alloc;

    void start(TaskPool pool, ulong workers) {
        scheduler.start(pool, workers, &alloc);
    }

    void shutdown() {
        import core.memory : GC;
        import my.libc : malloc_trim;

        scheduler.shutdown;
        scheduler = null;
        //() @trusted { .destroy(scheduler); GC.collect; malloc_trim(0); }();
        () @trusted { .destroy(scheduler); }();
        () @trusted { GC.collect; }();
        () @trusted { malloc_trim(0); }();
    }
}

/** Schedule actors for execution.
 *
 * A worker pop an actor, execute it and then put it back for later scheduling.
 *
 * A watcher monitors inactive actors for either messages to have arrived or
 * timeouts to trigger. They are then moved back to the waiting queue. The
 * workers are notified that there are actors waiting to be executed.
 */
class Scheduler {
    import core.atomic : atomicOp, atomicLoad;

    SystemConfig.Scheduler conf;

    ActorAlloc* alloc;

    /// Workers will shutdown cleanly if it is false.
    bool isActive;

    /// Watcher will shutdown cleanly if this is false.
    bool isWatcher;

    // Workers waiting to be activated
    Mutex waitingWorkerMtx;
    Condition waitingWorker;

    // actors waiting to be executed by a worker.
    Queue!(Actor*) waiting;
    shared ulong approxWaiting;

    // Actors waiting for messages to arrive thus they are inactive.
    Queue!(Actor*) inactive;
    shared ulong approxInactive;

    Task!(worker, Scheduler, const ulong)*[] workers;
    Task!(watchInactive, Scheduler)* watcher;

    this(SystemConfig.Scheduler conf, TaskPool pool) {
        this.conf = conf;
        this.isActive = true;
        this.isWatcher = true;
        this.waiting = typeof(waiting)(new Mutex);
        this.inactive = typeof(inactive)(new Mutex);

        this.waitingWorkerMtx = new Mutex;
        this.waitingWorker = new Condition(this.waitingWorkerMtx);
    }

    void wakeup() @trusted {
        synchronized (waitingWorkerMtx) {
            waitingWorker.notify;
        }
    }

    void wait(Duration w) @trusted {
        synchronized (waitingWorkerMtx) {
            waitingWorker.wait(w);
        }
    }

    /// check the inactive actors for activity.
    private static void watchInactive(Scheduler sched) {
        const maxThroughput = sched.conf.maxThroughput.orElse(50UL);
        const shutdownPoll = sched.conf.pollInterval.orElse(20.dur!"msecs");

        const minPoll = 100.dur!"usecs";
        const stepPoll = minPoll;
        const maxPoll = sched.conf.pollInterval.orElse(10.dur!"msecs");

        Duration pollInterval = minPoll;

        while (sched.isActive) {
            const runActors = atomicLoad(sched.approxInactive);
            ulong inactive;
            Duration nextPoll = pollInterval;

            foreach (_; 0 .. runActors) {
                if (auto a = sched.inactive.pop.unsafeMove) {
                    atomicOp!"-="(sched.approxInactive, 1UL);

                    void moveToWaiting() {
                        sched.putWaiting(a);
                    }

                    if (a.hasMessage) {
                        moveToWaiting;
                    } else {
                        const t = a.nextTimeout(Clock.currTime, maxPoll);

                        if (t < minPoll) {
                            moveToWaiting;
                        } else {
                            sched.putInactive(a);
                            nextPoll = inactive == 0 ? t : min(nextPoll, t);
                            inactive++;
                        }
                    }
                }
            }

            if (inactive != 0) {
                pollInterval = max(minPoll, nextPoll);
            }

            if (inactive == runActors) {
                () @trusted { Thread.sleep(pollInterval); }();
                pollInterval = min(maxPoll, pollInterval);
            } else {
                sched.wakeup;
                pollInterval = minPoll;
            }
        }

        while (sched.isWatcher) {
            if (auto a = sched.inactive.pop.unsafeMove) {
                sched.waiting.put(a);
                sched.wakeup;
            } else {
                () @trusted { Thread.sleep(shutdownPoll); }();
            }
        }
    }

    private static void worker(Scheduler sched, const ulong id) {
        import my.actor.msg : sendSystemMsgIfEmpty;
        import my.actor.common : ExitReason;
        import my.actor.mailbox : SystemExitMsg;

        const maxThroughput = sched.conf.maxThroughput.orElse(50UL);
        const pollInterval = sched.conf.pollInterval.orElse(50.dur!"msecs");
        const inactiveLimit = min(500.dur!"msecs", pollInterval * 3);

        while (sched.isActive) {
            const runActors = atomicLoad(sched.approxWaiting);
            ulong consecutiveInactive;

            foreach (_; 0 .. runActors) {
                // reduce clock polling
                const now = Clock.currTime;
                //writefln("mark %s %s %s", now, lastActive, (now - lastActive));
                if (auto ctx = sched.pop) {
                    atomicOp!"-="(sched.approxWaiting, 1);

                    ulong msgs;
                    ulong totalMsgs;
                    do {
                        ctx.process(now);
                        msgs = ctx.messages;
                        totalMsgs += msgs;
                        //writefln("%s tick %s %s", id, ctx.actor.name, msgs);
                    }
                    while (totalMsgs < maxThroughput && msgs != 0);

                    //writefln("%s done %s %s", id, ctx.actor.name, totalMsgs);

                    if (totalMsgs == 0) {
                        sched.putInactive(ctx);
                        consecutiveInactive++;
                    } else {
                        consecutiveInactive = 0;
                        sched.putWaiting(ctx);
                    }

                    // nice logging. logg this to the actor framework or something
                    //writeln(ctx.actor, " ", totalMsgs, " ", ctx.isAlive, " ", ctx.actor.addr.isOpen, " ", ctx.actor.state_);
                    //() @trusted {
                    //writeln(*ctx.actor);
                    //}();
                } else {
                    sched.wait(pollInterval);
                    //writefln("%s short sleep", id);
                }
            }

            // sleep if it is detected that actors are not sending messages
            if (consecutiveInactive == runActors) {
                sched.wait(inactiveLimit);
                //writefln("%s long sleep", id);
            }
        }

        while (!sched.waiting.empty) {
            const sleepAfter = atomicLoad(sched.approxWaiting) + 1;
            for (size_t i; i < sleepAfter; ++i) {
                if (auto ctx = sched.pop) {
                    sendSystemMsgIfEmpty(ctx.address, SystemExitMsg(ExitReason.kill));
                    ctx.process(Clock.currTime);
                    sched.putWaiting(ctx);
                }
            }

            () @trusted { Thread.sleep(pollInterval); }();
        }
    }

    /// Start the workers.
    void start(TaskPool pool, const ulong nr, ActorAlloc* alloc) {
        this.alloc = alloc;
        foreach (const id; 0 .. nr) {
            auto t = task!worker(this, id);
            workers ~= t;
            pool.put(t);
        }
        watcher = task!watchInactive(this);
        watcher.executeInNewThread(Thread.PRIORITY_MIN);
    }

    void shutdown() {
        isActive = false;
        foreach (a; workers) {
            try {
                a.yieldForce;
            } catch (Exception e) {
                // TODO: log exceptions?
            }
        }

        isWatcher = false;
        try {
            watcher.yieldForce;
        } catch (Exception e) {
        }
    }

    Actor* pop() {
        return waiting.pop.unsafeMove;
    }

    void putWaiting(Actor* a) @safe {
        if (a.isAlive) {
            waiting.put(a);
            atomicOp!"+="(approxWaiting, 1);
        } else {
            // TODO: should terminated actors be logged?
            alloc.dispose(a);
        }
    }

    void putInactive(Actor* a) @safe {
        inactive.put(a);
        atomicOp!"+="(approxInactive, 1);
    }
}