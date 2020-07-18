/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This module contains functions to extract XDG variables to either what they are
configured or the fallback according to the standard at [XDG Base Directory
Specification](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html).
*/
module my.xdg;

import my.path;

/** Extracts the directory to use for program runtime data for the current user.
 *
 * The fallback is used when the variable is not set. This is common on e.g.
 * older versions of Linux such as CentOS6.
 *
 * From the specification:
 *
 * $XDG_RUNTIME_DIR defines the base directory relative to which user-specific
 * non-essential runtime files and other file objects (such as sockets, named
 * pipes, ...) should be stored. The directory MUST be owned by the user, and
 * he MUST be the only one having read and write access to it. Its Unix access
 * mode MUST be 0700.
 *
 * The lifetime of the directory MUST be bound to the user being logged in. It
 * MUST be created when the user first logs in and if the user fully logs out
 * the directory MUST be removed. If the user logs in more than once he should
 * get pointed to the same directory, and it is mandatory that the directory
 * continues to exist from his first login to his last logout on the system,
 * and not removed in between. Files in the directory MUST not survive reboot
 * or a full logout/login cycle.
 *
 * The directory MUST be on a local file system and not shared with any other
 * system. The directory MUST by fully-featured by the standards of the
 * operating system. More specifically, on Unix-like operating systems AF_UNIX
 * sockets, symbolic links, hard links, proper permissions, file locking,
 * sparse files, memory mapping, file change notifications, a reliable hard
 * link count must be supported, and no restrictions on the file name character
 * set should be imposed. Files in this directory MAY be subjected to periodic
 * clean-up. To ensure that your files are not removed, they should have their
 * access time timestamp modified at least once every 6 hours of monotonic time
 * or the 'sticky' bit should be set on the file.
 *
 * If $XDG_RUNTIME_DIR is not set applications should fall back to a
 * replacement directory with similar capabilities and print a warning message.
 * Applications should use this directory for communication and synchronization
 * purposes and should not place larger files in it, since it might reside in
 * runtime memory and cannot necessarily be swapped out to disk.
 */
Path xdgRuntimeDir(Path fallback) {
    import std.process : environment;

    return Path(environment.get("XDG_RUNTIME_DIR", fallback));
}
