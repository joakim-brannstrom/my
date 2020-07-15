/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module config;

public import logger = std.experimental.logger;
public import std;

public import unit_threaded.assertions;

string appPath() {
    foreach (a; ["../build/app"].filter!(a => exists(a)))
        return a.absolutePath;
    assert(0, "unable to find an app binary");
}

auto executeApp(string[] args, string workDir) {
    return execute([appPath] ~ args, null, Config.none, size_t.max, workDir);
}

/// Path to where data used for integration tests exists
string testData() {
    return "testdata".absolutePath;
}

string inTestData(string p) {
    return buildPath(testData, p);
}

string tmpDir() {
    return "build/test".absolutePath;
}

TestArea makeTestArea(string testName, string file = __FILE__, int line = __LINE__) {
    return TestArea(testName, file, line);
}

struct TestArea {
    const string sandboxPath;
    private int commandLogCnt;

    this(string testName, string file, int line) {
        sandboxPath = buildPath(tmpDir, testName ~ file.baseName ~ line.to!string).absolutePath;

        if (exists(sandboxPath)) {
            rmdirRecurse(sandboxPath);
        }
        mkdirRecurse(sandboxPath);
    }

    auto exec(Args...)(auto ref Args args_) {
        string[] args;
        static foreach (a; args_)
            args ~= a;
        auto res = executeApp(args, sandboxPath);
        try {
            auto fout = File(inSandboxPath(format("command%s.log", commandLogCnt++)), "w");
            fout.writefln("%-(%s %)", args);
            fout.write(res.output);
        } catch (Exception e) {
        }
        return res;
    }

    string inSandboxPath(in string fileName) @safe pure nothrow const {
        import std.path : buildPath;

        return buildPath(sandboxPath, fileName);
    }
}
