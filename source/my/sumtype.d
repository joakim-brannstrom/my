/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.sumtype;

public import sumtype;

/** Check if an instance of a sumtype contains the specific type.
 *
 * This is from the D forum by Paul Backus, the author of sumtype.
 *
 * Example:
 * ---
 * assert(someType.contains!int);
 * ---
 *
 */
bool contains(T, ST)(ST st) if (isSumType!ST) {
    return st.match!(value =>  is(typeof(value) == T));
}

@("shall match the sumtype")
unittest {
    alias T = SumType!(int, bool, char);
    auto a = T(true);
    assert(a.contains!bool);
    assert(!a.contains!int);
}
