/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

A RAII vector that uses GC memory. It is not meant to be performant but rather
convenient. The intention is to support put/pop for front and back and
convenient range operations.
*/
module my.container.vector;

struct Vector(T) {
    T[] data;

    void putFront(T a) {
        data = [a] ~ data;
    }

    void put(T a) {
        data ~= a;
    }

    void popBack() {
        data = data[0 .. $ - 1];
    }

    T back() {
        return data[$ - 1];
    }

    T opIndex(size_t index) {
        return data[index];
    }

    T front() {
        assert(!empty, "Can't get front of an empty range");
        return data[0];
    }

    void popFront() {
        assert(!empty, "Can't pop front of an empty range");
        data = data[1 .. $];
    }

    bool empty() {
        return data.length == 0;
    }
}

@("shall put/pop")
unittest {
    Vector!int v;
    v.put(1);
    v.put(2);

    assert(v.front == 1);
    assert(v.back == 2);
    v.popBack;
    assert(v.front == 1);
    assert(v.back == 1);
}

@("shall put/pop")
unittest {
    Vector!int v;
    v.put(1);
    v.put(2);

    assert(v.front == 1);
    assert(v.back == 2);
    v.popFront;
    assert(v.front == 2);
    assert(v.back == 2);
}
