/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Trim the heap size by periodically force the GC to collect unused memory, free
it and then tell malloc to further free it back to the OS.
*/
module my.gc.memfree;

import std.concurrency : send, spawn, receiveTimeout, Tid;
import std.typecons : SafeRefCounted;

import my.libc;

/// Returns: a started instance of MemFree.
MemFree memFree() @trusted {
    return MemFree(true);
}

/** Reduces the used memory by the GC and free the heap to the OS.
 *
 * To avoid calling this too often the struct have a timer to ensure it is
 * callled at most ones every minute.
 *
 * TODO: maybe add functionality to call it more often when above e.g. 50% memory usage?
 */
struct MemFree {
    private static struct Data {
        bool isRunning;
        Tid bg;
    }

    private SafeRefCounted!Data data;

    this(bool startNow) @safe nothrow {
        try {
            if (startNow)
                start;
        } catch(Exception e) {
        }
    }

    ~this() @trusted nothrow {
        if (!data.refCountedStore.isInitialized || !data.isRunning)
            return;

        scope (exit)
            data.isRunning = false;
        try {
            send(data.bg, Msg.stop);
        } catch(Exception e) {
        }
    }

    /** Start a background thread to do the work.
     *
     * It terminates when the destructor is called.
     */
    void start() @trusted {
        data = Data(true, spawn(&tick));
    }

}

private:

enum Msg {
    stop,
}

void tick() nothrow {
    import core.time : dur;
    import core.memory : GC;

    const tickInterval = 1.dur!"minutes";

    bool running = true;
    while (running) {
        try {
            receiveTimeout(tickInterval, (Msg x) { running = false; });
        } catch (Exception e) {
            running = false;
        }

        GC.collect;
        GC.minimize;
        malloc_trim(0);
    }
}
