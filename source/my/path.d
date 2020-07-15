/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.path;

import std.range : isOutputRange, put;
import std.path : dirName, baseName, buildPath;

/// Tag a string as a path.
struct Path {
    private string value_;

    this(string s) @safe nothrow {
        const h = s.hashOf;
        if (auto v = h in pathCache) {
            value_ = *v;
        } else {
            pathCache[h] = s;
            value_ = s;
        }
    }

    bool empty() @safe pure nothrow const @nogc {
        return value_.length == 0;
    }

    bool opEquals(const string s) @safe pure nothrow const @nogc {
        return value_ == s;
    }

    bool opEquals(const Path s) @safe pure nothrow const @nogc {
        return value_ == s.value_;
    }

    size_t toHash() @safe pure nothrow const @nogc scope {
        return value_.hashOf;
    }

    Path opBinary(string op)(string rhs) @safe {
        static if (op == "~") {
            return Path(buildPath(value_, rhs));
        } else
            static assert(false, typeof(this).stringof ~ " does not have operator " ~ op);
    }

    void opOpAssign(string op)(string rhs) @safe nothrow {
        static if (op == "~=") {
            value_ = buildNormalizedPath(value_, rhs);
        } else
            static assert(false, typeof(this).stringof ~ " does not have operator " ~ op);
    }

    T opCast(T : string)() const {
        return value_;
    }

    string toString() @safe pure nothrow const @nogc {
        return value_;
    }

    void toString(Writer)(ref Writer w) const if (isOutputRange!(Writer, char)) {
        put(w, value_);
    }

    Path dirName() @safe const {
        return Path(value_.dirName);
    }

    string baseName() @safe const {
        return value_.baseName;
    }

    private static string fromCache(size_t h) {
        if (pathCache.length > 1024) {
            pathCache = null;
        }
        if (auto v = h in pathCache) {
            return *v;
        }
        return null;
    }
}

private {
    // Reduce memory usage by reusing paths.
    private string[size_t] pathCache;
}

/// The path is guaranteed to be the absolute path.
struct AbsolutePath {
    import std.path : buildNormalizedPath, absolutePath, expandTilde;

    private Path value_;

    this(AbsolutePath p) @safe pure nothrow @nogc {
        value_ = p.value_;
    }

    this(string p) @safe {
        this(Path(p));
    }

    this(Path p) @safe {
        value_ = Path(p.value_.expandTilde.absolutePath.buildNormalizedPath);
    }

    void opAssign(AbsolutePath p) @safe pure nothrow @nogc {
        value_ = p.value_;
    }

    Path opBinary(string op)(string rhs) @safe {
        static if (op == "~") {
            return AbsolutePath(buildPath(value_, rhs));
        } else
            static assert(false, typeof(this).stringof ~ " does not have operator " ~ op);
    }

    void opOpAssign(string op)(string rhs) @safe nothrow {
        static if (op == "~=") {
            value_ = AbsolutePath(buildPath(value_, rhs));
        } else
            static assert(false, typeof(this).stringof ~ " does not have operator " ~ op);
    }

    string opCast(T : string)() pure nothrow const @nogc {
        return value_;
    }

    bool opEquals(const string s) @safe pure nothrow const @nogc {
        return value_ == s;
    }

    bool opEquals(const Path s) @safe pure nothrow const @nogc {
        return value_ == s.value_;
    }

    bool opEquals(const AbsolutePath s) @safe pure nothrow const @nogc {
        return value_ == s.value_;
    }

    string toString() @safe pure nothrow const @nogc {
        return cast(string) value_;
    }

    void toString(Writer)(ref Writer w) const if (isOutputRange!(Writer, char)) {
        put(w, value_);
    }

    AbsolutePath dirName() @safe const {
        // avoid the expensive expansions and normalizations.
        AbsolutePath a;
        a.value_ = value_.dirName;
        return a;
    }

    string baseName() @safe const {
        return value_.baseName;
    }
}

@("shall always be the absolute path")
unittest {
    import std.algorithm : canFind;
    import std.path;
    import unit_threaded;

    AbsolutePath(Path("~/foo")).toString.canFind('~').shouldEqual(false);
    AbsolutePath(Path("foo")).toString.isAbsolute.shouldEqual(true);
}

@("shall expand . without any trailing /.")
unittest {
    import std.algorithm : canFind;
    import unit_threaded;

    AbsolutePath(Path(".")).toString.canFind('.').shouldBeFalse;
    AbsolutePath(Path(".")).toString.canFind('.').shouldBeFalse;
}
