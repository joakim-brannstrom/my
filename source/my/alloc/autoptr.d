/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.alloc.autoptr;

public import autoptr.intrusive_ptr;
public import autoptr.rc_ptr;
public import autoptr.shared_ptr;
public import autoptr.unique_ptr;

import std.traits : isDynamicArray;

auto trustedGet(Ptr)(ref scope Ptr ptr) @trusted
        if (is(Ptr.ElementType == class) || is(Ptr.ElementType == interface)
            || isDynamicArray!(Ptr.ElementType)) {
    return ptr.get();
}

ref auto trustedGet(Ptr)(ref scope Ptr ptr) @trusted
        if (!is(Ptr.ElementType == class) && !is(Ptr.ElementType == interface)
            && !isDynamicArray!(Ptr.ElementType)) {
    return ptr.get();
}
