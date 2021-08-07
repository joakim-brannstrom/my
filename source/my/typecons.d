/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.typecons;

/** Creates a copy c'tor for all members in the struct.
 *
 * This is only meant for structs where all members are to be copied. For anything more complex write a custom ctor.
 */
mixin template CopyCtor() {
    this(ref return scope typeof(this) rhs) @safe pure nothrow @nogc {
        import std.traits : FieldNameTuple;

        static foreach (Member; FieldNameTuple!(typeof(this))) {
            mixin(Member ~ " = rhs." ~ Member ~ ";");
        }
    }
}

@("shall create a copy constructor")
unittest {
    static struct A {
        int x;
        int y;

        mixin CopyCtor;
    }

    auto a = A(1, 2);
    auto b = a;
    assert(a == b);
}

/**
_Tuple of values, for example $(D Tuple!(int, string)) is a record that
stores an `int` and a `string`. `Tuple` can be used to bundle
values together, notably when returning multiple values from a
function. If `obj` is a `Tuple`, the individual members are
accessible with the syntax `obj[0]` for the first field, `obj[1]`
for the second, and so on.

See_Also: $(LREF tuple).

Params:
    Specs = A list of types (and optionally, member names) that the `Tuple` contains.
*/
template Tuple(Specs...) if (distinctFieldNames!(Specs)) {
    import std.meta : staticMap;

    // Parse (type,name) pairs (FieldSpecs) out of the specified
    // arguments. Some fields would have name, others not.
    template parseSpecs(Specs...) {
        static if (Specs.length == 0) {
            alias parseSpecs = AliasSeq!();
        } else static if (is(Specs[0])) {
            static if (is(typeof(Specs[1]) : string)) {
                alias parseSpecs = AliasSeq!(FieldSpec!(Specs[0 .. 2]), parseSpecs!(Specs[2 .. $]));
            } else {
                alias parseSpecs = AliasSeq!(FieldSpec!(Specs[0]), parseSpecs!(Specs[1 .. $]));
            }
        } else {
            static assert(0,
                    "Attempted to instantiate Tuple with an "
                    ~ "invalid argument: " ~ Specs[0].stringof);
        }
    }

    template FieldSpec(T, string s = "") {
        alias Type = T;
        alias name = s;
    }

    alias fieldSpecs = parseSpecs!Specs;

    // Used with staticMap.
    alias extractType(alias spec) = spec.Type;
    alias extractName(alias spec) = spec.name;

    // Generates named fields as follows:
    //    alias name_0 = Identity!(field[0]);
    //    alias name_1 = Identity!(field[1]);
    //      :
    // NOTE: field[k] is an expression (which yields a symbol of a
    //       variable) and can't be aliased directly.
    enum injectNamedFields = () {
        string decl = "";
        static foreach (i, val; fieldSpecs) {
            {
                immutable si = i.stringof;
                decl ~= "alias _" ~ si ~ " = Identity!(field[" ~ si ~ "]);";
                if (val.name.length != 0) {
                    decl ~= "alias " ~ val.name ~ " = _" ~ si ~ ";";
                }
            }
        }
        return decl;
    };

    // Returns Specs for a subtuple this[from .. to] preserving field
    // names if any.
    alias sliceSpecs(size_t from, size_t to) = staticMap!(expandSpec, fieldSpecs[from .. to]);

    template expandSpec(alias spec) {
        static if (spec.name.length == 0) {
            alias expandSpec = AliasSeq!(spec.Type);
        } else {
            alias expandSpec = AliasSeq!(spec.Type, spec.name);
        }
    }

    enum areCompatibleTuples(Tup1, Tup2, string op) = isTuple!(OriginalType!Tup2)
        && is(typeof((ref Tup1 tup1, ref Tup2 tup2) {
                static assert(tup1.field.length == tup2.field.length);
                static foreach (i; 0 .. Tup1.Types.length) {
                    {
                        auto lhs = typeof(tup1.field[i]).init;
                        auto rhs = typeof(tup2.field[i]).init;
                        static if (op == "=")
                            lhs = rhs;
                        else
                            auto result = mixin("lhs " ~ op ~ " rhs");
                    }
                }
            }));

    enum areBuildCompatibleTuples(Tup1, Tup2) = isTuple!Tup2 && is(typeof({
                static assert(Tup1.Types.length == Tup2.Types.length);
                static foreach (i; 0 .. Tup1.Types.length)
                    static assert(isBuildable!(Tup1.Types[i], Tup2.Types[i]));
            }));

    /+ Returns `true` iff a `T` can be initialized from a `U`. +/
    enum isBuildable(T, U) = is(typeof({ U u = U.init; T t = u; }));
    /+ Helper for partial instantiation +/
    template isBuildableFrom(U) {
        enum isBuildableFrom(T) = isBuildable!(T, U);
    }

    struct Tuple {
        /**
         * The types of the `Tuple`'s components.
         */
        alias Types = staticMap!(extractType, fieldSpecs);

        private alias _Fields = Specs;

        ///
        static if (Specs.length == 0)
            @safe unittest {
                import std.meta : AliasSeq;

                alias Fields = Tuple!(int, "id", string, float);
                static assert(is(Fields.Types == AliasSeq!(int, string, float)));
            }

        /**
         * The names of the `Tuple`'s components. Unnamed fields have empty names.
         */
        alias fieldNames = staticMap!(extractName, fieldSpecs);

        ///
        static if (Specs.length == 0)
            @safe unittest {
                import std.meta : AliasSeq;

                alias Fields = Tuple!(int, "id", string, float);
                static assert(Fields.fieldNames == AliasSeq!("id", "", ""));
            }

        /**
         * Use `t.expand` for a `Tuple` `t` to expand it into its
         * components. The result of `expand` acts as if the `Tuple`'s components
         * were listed as a list of values. (Ordinarily, a `Tuple` acts as a
         * single value.)
         */
        Types expand;
        mixin(injectNamedFields());

        ///
        static if (Specs.length == 0)
            @safe unittest {
                auto t1 = tuple(1, " hello ", 'a');
                assert(t1.toString() == `Tuple!(int, string, char)(1, " hello ", 'a')`);

                void takeSeveralTypes(int n, string s, bool b) {
                    assert(n == 4 && s == "test" && b == false);
                }

                auto t2 = tuple(4, "test", false);
                //t.expand acting as a list of values
                takeSeveralTypes(t2.expand);
            }

        static if (is(Specs)) {
            // This is mostly to make t[n] work.
            alias expand this;
        } else {
            @property ref inout(Tuple!Types) _Tuple_super() inout @trusted {
                static foreach (i; 0 .. Types.length) // Rely on the field layout
                {
                        static assert(typeof(return).init.tupleof[i].offsetof == expand[i].offsetof);
                    }
                return *cast(typeof(return)*)&(field[0]);
            }
            // This is mostly to make t[n] work.
            alias _Tuple_super this;
        }

        // backwards compatibility
        alias field = expand;

        /**
         * Constructor taking one value for each field.
         *
         * Params:
         *     values = A list of values that are either the same
         *              types as those given by the `Types` field
         *              of this `Tuple`, or can implicitly convert
         *              to those types. They must be in the same
         *              order as they appear in `Types`.
         */
        static if (Types.length > 0) {
            this(Types values) {
                field[] = values[];
            }
        }

        ///
        static if (Specs.length == 0)
            @safe unittest {
                alias ISD = Tuple!(int, string, double);
                auto tup = ISD(1, "test", 3.2);
                assert(tup.toString() == `Tuple!(int, string, double)(1, "test", 3.2)`);
            }

        /**
         * Constructor taking a compatible array.
         *
         * Params:
         *     values = A compatible static array to build the `Tuple` from.
         *              Array slices are not supported.
         */
        this(U, size_t n)(U[n] values)
                if (n == Types.length && allSatisfy!(isBuildableFrom!U, Types)) {
            static foreach (i; 0 .. Types.length) {
                field[i] = values[i];
            }
        }

        ///
        static if (Specs.length == 0)
            @safe unittest {
                int[2] ints;
                Tuple!(int, int) t = ints;
            }

        /**
         * Constructor taking a compatible `Tuple`. Two `Tuple`s are compatible
         * $(B iff) they are both of the same length, and, for each type `T` on the
         * left-hand side, the corresponding type `U` on the right-hand side can
         * implicitly convert to `T`.
         *
         * Params:
         *     another = A compatible `Tuple` to build from. Its type must be
         *               compatible with the target `Tuple`'s type.
         */
        this(U)(U another) if (areBuildCompatibleTuples!(typeof(this), U)) {
            field[] = another.field[];
        }

        ///
        static if (Specs.length == 0)
            @safe unittest {
                alias IntVec = Tuple!(int, int, int);
                alias DubVec = Tuple!(double, double, double);

                IntVec iv = tuple(1, 1, 1);

                //Ok, int can implicitly convert to double
                DubVec dv = iv;
                //Error: double cannot implicitly convert to int
                //IntVec iv2 = dv;
            }

        /**
         * Comparison for equality. Two `Tuple`s are considered equal
         * $(B iff) they fulfill the following criteria:
         *
         * $(UL
         *   $(LI Each `Tuple` is the same length.)
         *   $(LI For each type `T` on the left-hand side and each type
         *        `U` on the right-hand side, values of type `T` can be
         *        compared with values of type `U`.)
         *   $(LI For each value `v1` on the left-hand side and each value
         *        `v2` on the right-hand side, the expression `v1 == v2` is
         *        true.))
         *
         * Params:
         *     rhs = The `Tuple` to compare against. It must meeting the criteria
         *           for comparison between `Tuple`s.
         *
         * Returns:
         *     true if both `Tuple`s are equal, otherwise false.
         */
        bool opEquals(R)(R rhs) if (areCompatibleTuples!(typeof(this), R, "==")) {
            return field[] == rhs.field[];
        }

        /// ditto
        bool opEquals(R)(R rhs) const 
                if (areCompatibleTuples!(typeof(this), R, "==")) {
            return field[] == rhs.field[];
        }

        /// ditto
        bool opEquals(R...)(auto ref R rhs)
                if (R.length > 1 && areCompatibleTuples!(typeof(this), Tuple!R, "==")) {
            static foreach (i; 0 .. Types.length)
                if (field[i] != rhs[i])
                    return false;

            return true;
        }

        ///
        static if (Specs.length == 0)
            @safe unittest {
                Tuple!(int, string) t1 = tuple(1, "test");
                Tuple!(double, string) t2 = tuple(1.0, "test");
                //Ok, int can be compared with double and
                //both have a value of 1
                assert(t1 == t2);
            }

        /**
         * Comparison for ordering.
         *
         * Params:
         *     rhs = The `Tuple` to compare against. It must meet the criteria
         *           for comparison between `Tuple`s.
         *
         * Returns:
         * For any values `v1` contained by the left-hand side tuple and any
         * values `v2` contained by the right-hand side:
         *
         * 0 if `v1 == v2` for all members or the following value for the
         * first position were the mentioned criteria is not satisfied:
         *
         * $(UL
         *   $(LI NaN, in case one of the operands is a NaN.)
         *   $(LI A negative number if the expression `v1 < v2` is true.)
         *   $(LI A positive number if the expression `v1 > v2` is true.))
         */
        auto opCmp(R)(R rhs) if (areCompatibleTuples!(typeof(this), R, "<")) {
            static foreach (i; 0 .. Types.length) {
                if (field[i] != rhs.field[i]) {
                    import std.math.traits : isNaN;

                    static if (isFloatingPoint!(Types[i])) {
                        if (isNaN(field[i]))
                            return float.nan;
                    }
                    static if (isFloatingPoint!(typeof(rhs.field[i]))) {
                        if (isNaN(rhs.field[i]))
                            return float.nan;
                    }
                    static if (is(typeof(field[i].opCmp(rhs.field[i])))
                            && isFloatingPoint!(typeof(field[i].opCmp(rhs.field[i])))) {
                        if (isNaN(field[i].opCmp(rhs.field[i])))
                            return float.nan;
                    }

                    return field[i] < rhs.field[i] ? -1 : 1;
                }
            }
            return 0;
        }

        /// ditto
        auto opCmp(R)(R rhs) const if (areCompatibleTuples!(typeof(this), R, "<")) {
            static foreach (i; 0 .. Types.length) {
                if (field[i] != rhs.field[i]) {
                    import std.math.traits : isNaN;

                    static if (isFloatingPoint!(Types[i])) {
                        if (isNaN(field[i]))
                            return float.nan;
                    }
                    static if (isFloatingPoint!(typeof(rhs.field[i]))) {
                        if (isNaN(rhs.field[i]))
                            return float.nan;
                    }
                    static if (is(typeof(field[i].opCmp(rhs.field[i])))
                            && isFloatingPoint!(typeof(field[i].opCmp(rhs.field[i])))) {
                        if (isNaN(field[i].opCmp(rhs.field[i])))
                            return float.nan;
                    }

                    return field[i] < rhs.field[i] ? -1 : 1;
                }
            }
            return 0;
        }

        /**
            The first `v1` for which `v1 > v2` is true determines
            the result. This could lead to unexpected behaviour.
         */
        static if (Specs.length == 0)
            @safe unittest {
                auto tup1 = tuple(1, 1, 1);
                auto tup2 = tuple(1, 100, 100);
                assert(tup1 < tup2);

                //Only the first result matters for comparison
                tup1[0] = 2;
                assert(tup1 > tup2);
            }

        /**
         Concatenate Tuples.
         Tuple concatenation is only allowed if all named fields are distinct (no named field of this tuple occurs in `t`
         and no named field of `t` occurs in this tuple).

         Params:
             t = The `Tuple` to concatenate with

         Returns: A concatenation of this tuple and `t`
         */
        auto opBinary(string op, T)(auto ref T t)
                if (op == "~" && !(is(T : U[], U) && isTuple!U)) {
            static if (isTuple!T) {
                static assert(distinctFieldNames!(_Fields, T._Fields),
                        "Cannot concatenate tuples with duplicate fields: "
                        ~ fieldNames.stringof ~ " - " ~ T.fieldNames.stringof);
                return Tuple!(_Fields, T._Fields)(expand, t.expand);
            } else {
                return Tuple!(_Fields, T)(expand, t);
            }
        }

        /// ditto
        auto opBinaryRight(string op, T)(auto ref T t)
                if (op == "~" && !(is(T : U[], U) && isTuple!U)) {
            static if (isTuple!T) {
                static assert(distinctFieldNames!(_Fields, T._Fields),
                        "Cannot concatenate tuples with duplicate fields: "
                        ~ T.stringof ~ " - " ~ fieldNames.fieldNames.stringof);
                return Tuple!(T._Fields, _Fields)(t.expand, expand);
            } else {
                return Tuple!(T, _Fields)(t, expand);
            }
        }

        /**
         * Assignment from another `Tuple`.
         *
         * Params:
         *     rhs = The source `Tuple` to assign from. Each element of the
         *           source `Tuple` must be implicitly assignable to each
         *           respective element of the target `Tuple`.
         */
        ref Tuple opAssign(R)(auto ref R rhs)
                if (areCompatibleTuples!(typeof(this), R, "=")) {
            import std.algorithm.mutation : swap;

            static if (is(R : Tuple!Types) && !__traits(isRef, rhs) && isTuple!R) {
                if (__ctfe) {
                    // Cannot use swap at compile time
                    field[] = rhs.field[];
                } else {
                    // Use swap-and-destroy to optimize rvalue assignment
                    swap!(Tuple!Types)(this, rhs);
                }
            } else {
                // Do not swap; opAssign should be called on the fields.
                field[] = rhs.field[];
            }
            return this;
        }

        /**
         * Renames the elements of a $(LREF Tuple).
         *
         * `rename` uses the passed `names` and returns a new
         * $(LREF Tuple) using these names, with the content
         * unchanged.
         * If fewer names are passed than there are members
         * of the $(LREF Tuple) then those trailing members are unchanged.
         * An empty string will remove the name for that member.
         * It is an compile-time error to pass more names than
         * there are members of the $(LREF Tuple).
         */
        ref rename(names...)() inout return 
                if (names.length == 0 || allSatisfy!(isSomeString, typeof(names))) {
            import std.algorithm.comparison : equal;

            // to circumvent https://issues.dlang.org/show_bug.cgi?id=16418
            static if (names.length == 0 || equal([names], [fieldNames]))
                return this;
            else {
                enum nT = Types.length;
                enum nN = names.length;
                static assert(nN <= nT, "Cannot have more names than tuple members");
                alias allNames = AliasSeq!(names, fieldNames[nN .. $]);

                import std.meta : Alias, aliasSeqOf;

                template GetItem(size_t idx) {
                    import std.array : empty;

                    static if (idx < nT)
                        alias GetItem = Alias!(Types[idx]);
                    else static if (allNames[idx - nT].empty)
                        alias GetItem = AliasSeq!();
                    else
                        alias GetItem = Alias!(allNames[idx - nT]);
                }

                import std.range : roundRobin, iota;

                alias NewTupleT = Tuple!(staticMap!(GetItem,
                        aliasSeqOf!(roundRobin(iota(nT), iota(nT, 2 * nT)))));
                return *(() @trusted => cast(NewTupleT*)&this)();
            }
        }

        ///
        static if (Specs.length == 0)
            @safe unittest {
                auto t0 = tuple(4, "hello");

                auto t0Named = t0.rename!("val", "tag");
                assert(t0Named.val == 4);
                assert(t0Named.tag == "hello");

                Tuple!(float, "dat", size_t[2], "pos") t1;
                t1.pos = [2, 1];
                auto t1Named = t1.rename!"height";
                t1Named.height = 3.4f;
                assert(t1Named.height == 3.4f);
                assert(t1Named.pos == [2, 1]);
                t1Named.rename!"altitude".altitude = 5;
                assert(t1Named.height == 5);

                Tuple!(int, "a", int, int, "c") t2;
                t2 = tuple(3, 4, 5);
                auto t2Named = t2.rename!("", "b");
                // "a" no longer has a name
                static assert(!__traits(hasMember, typeof(t2Named), "a"));
                assert(t2Named[0] == 3);
                assert(t2Named.b == 4);
                assert(t2Named.c == 5);

                // not allowed to specify more names than the tuple has members
                static assert(!__traits(compiles, t2.rename!("a", "b", "c", "d")));

                // use it in a range pipeline
                import std.range : iota, zip;
                import std.algorithm.iteration : map, sum;

                auto res = zip(iota(1, 4), iota(10, 13)).map!(t => t.rename!("a", "b"))
                    .map!(t => t.a * t.b)
                    .sum;
                assert(res == 68);

                const tup = Tuple!(int, "a", int, "b")(2, 3);
                const renamed = tup.rename!("c", "d");
                assert(renamed.c + renamed.d == 5);
            }

        /**
         * Overload of $(LREF _rename) that takes an associative array
         * `translate` as a template parameter, where the keys are
         * either the names or indices of the members to be changed
         * and the new names are the corresponding values.
         * Every key in `translate` must be the name of a member of the
         * $(LREF tuple).
         * The same rules for empty strings apply as for the variadic
         * template overload of $(LREF _rename).
        */
        ref rename(alias translate)() inout 
                if (is(typeof(translate) : V[K], V, K) && isSomeString!V
                    && (isSomeString!K || is(K : size_t))) {
            import std.meta : aliasSeqOf;
            import std.range : ElementType;

            static if (isSomeString!(ElementType!(typeof(translate.keys)))) {
                {
                    import std.conv : to;
                    import std.algorithm.iteration : filter;
                    import std.algorithm.searching : canFind;

                    enum notFound = translate.keys.filter!(k => fieldNames.canFind(k) == -1);
                    static assert(notFound.empty,
                            "Cannot find members " ~ notFound.to!string ~ " in type " ~ typeof(this)
                            .stringof);
                }
                return this.rename!(aliasSeqOf!({
                        import std.array : empty;

                        auto names = [fieldNames];
                        foreach (ref n; names)
                            if (!n.empty)
                                if (auto p = n in translate)
                                    n = *p;
                        return names;
                    }()));
            } else {
                {
                    import std.algorithm.iteration : filter;
                    import std.conv : to;

                    enum invalid = translate.keys.filter!(k => k < 0 || k >= this.length);
                    static assert(invalid.empty, "Indices " ~ invalid.to!string
                            ~ " are out of bounds for tuple with length " ~ this.length.to!string);
                }
                return this.rename!(aliasSeqOf!({
                        auto names = [fieldNames];
                        foreach (k, v; translate)
                            names[k] = v;
                        return names;
                    }()));
            }
        }

        ///
        static if (Specs.length == 0)
            @safe unittest {
                //replacing names by their current name

                Tuple!(float, "dat", size_t[2], "pos") t1;
                t1.pos = [2, 1];
                auto t1Named = t1.rename!(["dat": "height"]);
                t1Named.height = 3.4;
                assert(t1Named.pos == [2, 1]);
                t1Named.rename!(["height": "altitude"]).altitude = 5;
                assert(t1Named.height == 5);

                Tuple!(int, "a", int, "b") t2;
                t2 = tuple(3, 4);
                auto t2Named = t2.rename!(["a": "b", "b": "c"]);
                assert(t2Named.b == 3);
                assert(t2Named.c == 4);

                const t3 = Tuple!(int, "a", int, "b")(3, 4);
                const t3Named = t3.rename!(["a": "b", "b": "c"]);
                assert(t3Named.b == 3);
                assert(t3Named.c == 4);
            }

        ///
        static if (Specs.length == 0)
            @safe unittest {
                //replace names by their position

                Tuple!(float, "dat", size_t[2], "pos") t1;
                t1.pos = [2, 1];
                auto t1Named = t1.rename!([0: "height"]);
                t1Named.height = 3.4;
                assert(t1Named.pos == [2, 1]);
                t1Named.rename!([0: "altitude"]).altitude = 5;
                assert(t1Named.height == 5);

                Tuple!(int, "a", int, "b", int, "c") t2;
                t2 = tuple(3, 4, 5);
                auto t2Named = t2.rename!([0: "c", 2: "a"]);
                assert(t2Named.a == 5);
                assert(t2Named.b == 4);
                assert(t2Named.c == 3);
            }

        static if (Specs.length == 0)
            @safe unittest {
                //check that empty translations work fine
                enum string[string] a0 = null;
                enum string[int] a1 = null;
                Tuple!(float, "a", float, "b") t0;

                auto t1 = t0.rename!a0;

                t1.a = 3;
                t1.b = 4;
                auto t2 = t0.rename!a1;
                t2.a = 3;
                t2.b = 4;
                auto t3 = t0.rename;
                t3.a = 3;
                t3.b = 4;
            }

        /**
         * Takes a slice by-reference of this `Tuple`.
         *
         * Params:
         *     from = A `size_t` designating the starting position of the slice.
         *     to = A `size_t` designating the ending position (exclusive) of the slice.
         *
         * Returns:
         *     A new `Tuple` that is a slice from `[from, to$(RPAREN)` of the original.
         *     It has the same types and values as the range `[from, to$(RPAREN)` in
         *     the original.
         */
        @property ref inout(Tuple!(sliceSpecs!(from, to))) slice(size_t from, size_t to)() inout @trusted
                if (from <= to && to <= Types.length) {
            static assert((typeof(this).alignof % typeof(return).alignof == 0)
                    && (expand[from].offsetof % typeof(return).alignof == 0),
                    "Slicing by reference is impossible because of an alignment mistmatch"
                    ~ " (See https://issues.dlang.org/show_bug.cgi?id=15645).");

            return *cast(typeof(return)*)&(field[from]);
        }

        ///
        static if (Specs.length == 0)
            @safe unittest {
                Tuple!(int, string, float, double) a;
                a[1] = "abc";
                a[2] = 4.5;
                auto s = a.slice!(1, 3);
                static assert(is(typeof(s) == Tuple!(string, float)));
                assert(s[0] == "abc" && s[1] == 4.5);

                // https://issues.dlang.org/show_bug.cgi?id=15645
                Tuple!(int, short, bool, double) b;
                static assert(!__traits(compiles, b.slice!(2, 4)));
            }

        /**
            Creates a hash of this `Tuple`.

            Returns:
                A `size_t` representing the hash of this `Tuple`.
         */
        size_t toHash() const nothrow @safe {
            size_t h = 0;
            static foreach (i, T; Types) {
                {
                    static if (__traits(compiles, h = .hashOf(field[i])))
                        const k = .hashOf(field[i]);
                    else {
                        // Workaround for when .hashOf is not both @safe and nothrow.
                        static if (is(T : shared U, U) && __traits(compiles,
                                (U* a)nothrow @safe => .hashOf(*a))
                                && !__traits(hasMember, T, "toHash")) // BUG: Improperly casts away `shared`!
                            const k = .hashOf(*(() @trusted => cast(U*)&field[i])());
                        else // BUG: Improperly casts away `shared`!
                            const k = typeid(T).getHash(
                                    (() @trusted => cast(const void*)&field[i])());
                    }
                    static if (i == 0)
                        h = k;
                    else // As in boost::hash_combine
                        // https://www.boost.org/doc/libs/1_55_0/doc/html/hash/reference.html#boost.hash_combine
                        h ^= k + 0x9e3779b9 + (h << 6) + (h >>> 2);
                }
            }
            return h;
        }

        /**
         * Converts to string.
         *
         * Returns:
         *     The string representation of this `Tuple`.
         */
        string toString()() const {
            import std.array : appender;

            auto app = appender!string();
            this.toString((const(char)[] chunk) => app ~= chunk);
            return app.data;
        }

        import std.format.spec : FormatSpec;

        /**
         * Formats `Tuple` with either `%s`, `%(inner%)` or `%(inner%|sep%)`.
         *
         * $(TABLE2 Formats supported by Tuple,
         * $(THEAD Format, Description)
         * $(TROW $(P `%s`), $(P Format like `Tuple!(types)(elements formatted with %s each)`.))
         * $(TROW $(P `%(inner%)`), $(P The format `inner` is applied the expanded `Tuple`$(COMMA) so
         *      it may contain as many formats as the `Tuple` has fields.))
         * $(TROW $(P `%(inner%|sep%)`), $(P The format `inner` is one format$(COMMA) that is applied
         *      on all fields of the `Tuple`. The inner format must be compatible to all
         *      of them.)))
         *
         * Params:
         *     sink = A `char` accepting delegate
         *     fmt = A $(REF FormatSpec, std,format)
         */
        void toString(DG)(scope DG sink) const {
            auto f = FormatSpec!char();
            toString(sink, f);
        }

        /// ditto
        void toString(DG, Char)(scope DG sink, scope const ref FormatSpec!Char fmt) const {
            import std.format : format, FormatException;
            import std.format.write : formattedWrite;
            import std.range : only;

            if (fmt.nested) {
                if (fmt.sep) {
                    foreach (i, Type; Types) {
                        static if (i > 0) {
                            sink(fmt.sep);
                        }
                        // TODO: Change this once formattedWrite() works for shared objects.
                        static if (is(Type == class) && is(Type == shared)) {
                            sink(Type.stringof);
                        } else {
                            formattedWrite(sink, fmt.nested, this.field[i]);
                        }
                    }
                } else {
                    formattedWrite(sink, fmt.nested, staticMap!(sharedToString, this.expand));
                }
            } else if (fmt.spec == 's') {
                enum header = Unqual!(typeof(this)).stringof ~ "(", footer = ")", separator = ", ";
                sink(header);
                foreach (i, Type; Types) {
                    static if (i > 0) {
                        sink(separator);
                    }
                    // TODO: Change this once format() works for shared objects.
                    static if (is(Type == class) && is(Type == shared)) {
                        sink(Type.stringof);
                    } else {
                        sink(format!("%(%s%)")(only(field[i])));
                    }
                }
                sink(footer);
            } else {
                const spec = fmt.spec;
                throw new FormatException(
                        "Expected '%s' or '%(...%)' or '%(...%|...%)' format specifier for type '" ~ Unqual!(typeof(this))
                        .stringof ~ "', not '%" ~ spec ~ "'.");
            }
        }

        ///
        static if (Types.length == 0)
            @safe unittest {
                import std.format : format;

                Tuple!(int, double)[3] tupList = [
                    tuple(1, 1.0), tuple(2, 4.0), tuple(3, 9.0)
                ];

                // Default format
                assert(format("%s", tuple("a", 1)) == `Tuple!(string, int)("a", 1)`);

                // One Format for each individual component
                assert(format("%(%#x v %.4f w %#x%)", tuple(1, 1.0, 10)) == `0x1 v 1.0000 w 0xa`);
                assert(format("%#x v %.4f w %#x", tuple(1, 1.0, 10).expand) == `0x1 v 1.0000 w 0xa`);

                // One Format for all components
                assert(format("%(>%s<%| & %)", tuple("abc", 1, 2.3, [4,
                            5])) == `>abc< & >1< & >2.3< & >[4, 5]<`);

                // Array of Tuples
                assert(format("%(%(f(%d) = %.1f%);  %)",
                        tupList) == `f(1) = 1.0;  f(2) = 4.0;  f(3) = 9.0`);
            }

        ///
        static if (Types.length == 0)
            @safe unittest {
                import std.exception : assertThrown;
                import std.format : format, FormatException;

                // Error: %( %) missing.
                assertThrown!FormatException(format("%d, %f", tuple(1, 2.0)) == `1, 2.0`);

                // Error: %( %| %) missing.
                assertThrown!FormatException(format("%d", tuple(1, 2)) == `1, 2`);

                // Error: %d inadequate for double
                assertThrown!FormatException(format("%(%d%|, %)", tuple(1, 2.0)) == `1, 2.0`);
            }
    }
}

///
@safe unittest {
    Tuple!(int, int) point;
    // assign coordinates
    point[0] = 5;
    point[1] = 6;
    // read coordinates
    auto x = point[0];
    auto y = point[1];
}

/**
    `Tuple` members can be named. It is legal to mix named and unnamed
    members. The method above is still applicable to all fields.
 */
@safe unittest {
    alias Entry = Tuple!(int, "index", string, "value");
    Entry e;
    e.index = 4;
    e.value = "Hello";
    assert(e[1] == "Hello");
    assert(e[0] == 4);
}

/**
    A `Tuple` with named fields is a distinct type from a `Tuple` with unnamed
    fields, i.e. each naming imparts a separate type for the `Tuple`. Two
    `Tuple`s differing in naming only are still distinct, even though they
    might have the same structure.
 */
@safe unittest {
    Tuple!(int, "x", int, "y") point1;
    Tuple!(int, int) point2;
    assert(!is(typeof(point1) == typeof(point2)));
}

/// Use tuples as ranges
@safe unittest {
    import std.algorithm.iteration : sum;
    import std.range : only;

    auto t = tuple(1, 2);
    assert(t.expand.only.sum == 3);
}

// https://issues.dlang.org/show_bug.cgi?id=4582
@safe unittest {
    static assert(!__traits(compiles, Tuple!(string, "id", int, "id")));
    static assert(!__traits(compiles, Tuple!(string, "str", int, "i", string, "str", float)));
}

/// Concatenate tuples
@safe unittest {
    import std.meta : AliasSeq;

    auto t = tuple(1, "2") ~ tuple(ushort(42), true);
    static assert(is(t.Types == AliasSeq!(int, string, ushort, bool)));
    assert(t[1] == "2");
    assert(t[2] == 42);
    assert(t[3] == true);
}

// https://issues.dlang.org/show_bug.cgi?id=14637
// tuple concat
@safe unittest {
    auto t = tuple!"foo"(1.0) ~ tuple!"bar"("3");
    static assert(is(t.Types == AliasSeq!(double, string)));
    static assert(t.fieldNames == tuple("foo", "bar"));
    assert(t.foo == 1.0);
    assert(t.bar == "3");
}

// https://issues.dlang.org/show_bug.cgi?id=18824
// tuple concat
@safe unittest {
    alias Type = Tuple!(int, string);
    Type[] arr;
    auto t = tuple(2, "s");
    // Test opBinaryRight
    arr = arr ~ t;
    // Test opBinary
    arr = t ~ arr;
    static assert(is(typeof(arr) == Type[]));
    immutable Type[] b;
    auto c = b ~ t;
    static assert(is(typeof(c) == immutable(Type)[]));
}

// tuple concat
@safe unittest {
    auto t = tuple!"foo"(1.0) ~ "3";
    static assert(is(t.Types == AliasSeq!(double, string)));
    assert(t.foo == 1.0);
    assert(t[1] == "3");
}

// tuple concat
@safe unittest {
    auto t = "2" ~ tuple!"foo"(1.0);
    static assert(is(t.Types == AliasSeq!(string, double)));
    assert(t.foo == 1.0);
    assert(t[0] == "2");
}

// tuple concat
@safe unittest {
    auto t = "2" ~ tuple!"foo"(1.0) ~ tuple(42, 3.0f) ~ real(1) ~ "a";
    static assert(is(t.Types == AliasSeq!(string, double, int, float, real, string)));
    assert(t.foo == 1.0);
    assert(t[0] == "2");
    assert(t[1] == 1.0);
    assert(t[2] == 42);
    assert(t[3] == 3.0f);
    assert(t[4] == 1.0);
    assert(t[5] == "a");
}

// ensure that concatenation of tuples with non-distinct fields is forbidden
@safe unittest {
    static assert(!__traits(compiles, tuple!("a")(0) ~ tuple!("a")("1")));
    static assert(!__traits(compiles, tuple!("a", "b")(0, 1) ~ tuple!("b", "a")("3", 1)));
    static assert(!__traits(compiles, tuple!("a")(0) ~ tuple!("b", "a")("3", 1)));
    static assert(!__traits(compiles, tuple!("a1", "a")(1.0, 0) ~ tuple!("a2", "a")("3", 0)));
}

// Ensure that Tuple comparison with non-const opEquals works
@safe unittest {
    static struct Bad {
        int a;

        bool opEquals(Bad b) {
            return a == b.a;
        }
    }

    auto t = Tuple!(int, Bad, string)(1, Bad(1), "asdf");

    //Error: mutable method Bad.opEquals is not callable using a const object
    assert(t == AliasSeq!(1, Bad(1), "asdf"));
}

// Ensure Tuple.toHash works
@safe unittest {
    Tuple!(int, int) point;
    assert(point.toHash == typeof(point).init.toHash);
    assert(tuple(1, 2) != point);
    assert(tuple(1, 2) == tuple(1, 2));
    point[0] = 1;
    assert(tuple(1, 2) != point);
    point[1] = 2;
    assert(tuple(1, 2) == point);
}

@safe @betterC unittest {
    auto t = tuple(1, 2);
    assert(t == tuple(1, 2));
    auto t3 = tuple(1, 'd');
}

// https://issues.dlang.org/show_bug.cgi?id=20850
// Assignment to enum tuple
@safe unittest {
    enum T : Tuple!(int*) {
        a = T(null)
    }

    T t;
    t = T.a;
}

// https://issues.dlang.org/show_bug.cgi?id=13663
@safe unittest {
    auto t = tuple(real.nan);
    assert(!(t > t));
    assert(!(t < t));
    assert(!(t == t));
}

@safe unittest {
    struct S {
        float opCmp(S s) {
            return float.nan;
        }

        bool opEquals(S s) {
            return false;
        }
    }

    auto t = tuple(S());
    assert(!(t > t));
    assert(!(t < t));
    assert(!(t == t));
}

// https://issues.dlang.org/show_bug.cgi?id=8015
@safe unittest {
    struct MyStruct {
        string str;
        @property string toStr() {
            return str;
        }

        alias toStr this;
    }

    Tuple!(MyStruct) t;
}

/**
    Constructs a $(LREF Tuple) object instantiated and initialized according to
    the given arguments.

    Params:
        Names = An optional list of strings naming each successive field of the `Tuple`
                or a list of types that the elements are being casted to.
                For a list of names,
                each name matches up with the corresponding field given by `Args`.
                A name does not have to be provided for every field, but as
                the names must proceed in order, it is not possible to skip
                one field and name the next after it.
                For a list of types,
                there must be exactly as many types as parameters.
*/
template tuple(Names...) {
    /**
    Params:
        args = Values to initialize the `Tuple` with. The `Tuple`'s type will
               be inferred from the types of the values given.

    Returns:
        A new `Tuple` with its type inferred from the arguments given.
     */
    auto tuple(Args...)(Args args) {
        static if (Names.length == 0) {
            // No specified names, just infer types from Args...
            return Tuple!Args(args);
        } else static if (!is(typeof(Names[0]) : string)) {
            // Names[0] isn't a string, must be explicit types.
            return Tuple!Names(args);
        } else {
            // Names[0] is a string, so must be specifying names.
            static assert(Names.length == Args.length, "Insufficient number of names given.");

            // Interleave(a, b).and(c, d) == (a, c, b, d)
            // This is to get the interleaving of types and names for Tuple
            // e.g. Tuple!(int, "x", string, "y")
            template Interleave(A...) {
                template and(B...) if (B.length == 1) {
                    alias and = AliasSeq!(A[0], B[0]);
                }

                template and(B...) if (B.length != 1) {
                    alias and = AliasSeq!(A[0], B[0], Interleave!(A[1 .. $]).and!(B[1 .. $]));
                }
            }

            return Tuple!(Interleave!(Args).and!(Names))(args);
        }
    }
}

///
@safe unittest {
    auto value = tuple(5, 6.7, "hello");
    assert(value[0] == 5);
    assert(value[1] == 6.7);
    assert(value[2] == "hello");

    // Field names can be provided.
    auto entry = tuple!("index", "value")(4, "Hello");
    assert(entry.index == 4);
    assert(entry.value == "Hello");
}

/**
    Returns `true` if and only if `T` is an instance of `std.typecons.Tuple`.

    Params:
        T = The type to check.

    Returns:
        true if `T` is a `Tuple` type, false otherwise.
 */
enum isTuple(T) = __traits(compiles, {
        void f(Specs...)(Tuple!Specs tup) {
        }

        f(T.init);
    });

///
@safe unittest {
    static assert(isTuple!(Tuple!()));
    static assert(isTuple!(Tuple!(int)));
    static assert(isTuple!(Tuple!(int, real, string)));
    static assert(isTuple!(Tuple!(int, "x", real, "y")));
    static assert(isTuple!(Tuple!(int, Tuple!(real), string)));
}

@safe unittest {
    static assert(isTuple!(const Tuple!(int)));
    static assert(isTuple!(immutable Tuple!(int)));

    static assert(!isTuple!(int));
    static assert(!isTuple!(const int));

    struct S {
    }

    static assert(!isTuple!(S));
}
