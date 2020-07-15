/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.file;

import my.path;

import std.file : mkdirRecurse, exists, copy, dirEntries, SpanMode;
import std.path : relativePath, buildPath, dirName;

void copyRecurse(Path src, Path dst) {
    foreach (a; dirEntries(src.toString, SpanMode.depth)) {
        const s = relativePath(a.name, src.toString);
        const d = buildPath(dst.toString, s);
        if (!exists(d.dirName)) {
            mkdirRecurse(d.dirName);
        }
        if (!a.isDir) {
            copy(a.name, d);
        }
    }
}

/// Make a file executable by all users on the system.
void setExecutable(Path p) {
    import core.sys.posix.sys.stat;
    import std.file : getAttributes, setAttributes;

    setAttributes(p.toString, getAttributes(p.toString) | S_IXUSR | S_IXGRP | S_IXOTH);
}

/// Check if a file is executable.
bool isExecutable(Path p) {
    import core.sys.posix.sys.stat;
    import std.file : getAttributes;

    // man 7 inode search for S_IFMT
    // S_ISUID     04000   set-user-ID bit
    // S_ISGID     02000   set-group-ID bit (see below)
    // S_ISVTX     01000   sticky bit (see below)
    //
    // S_IRWXU     00700   owner has read, write, and execute permission
    // S_IRUSR     00400   owner has read permission
    // S_IWUSR     00200   owner has write permission
    // S_IXUSR     00100   owner has execute permission
    //
    // S_IRWXG     00070   group has read, write, and execute permission
    // S_IRGRP     00040   group has read permission
    // S_IWGRP     00020   group has write permission
    // S_IXGRP     00010   group has execute permission
    //
    // S_IRWXO     00007   others (not in group) have read, write, and execute permission
    // S_IROTH     00004   others have read permission
    // S_IWOTH     00002   others have write permission
    // S_IXOTH     00001   others have execute permission

    const attrs = getAttributes(p.toString);
    return (attrs & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0;
}
