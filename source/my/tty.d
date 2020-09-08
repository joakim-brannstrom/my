/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Module to manipulate a file descriptor that point to a tty.
*/
module my.tty;

/// Set the terminal to cbreak mode which mean it is change from line mode to
/// character mode.
void setCBreak(int fd) {
    import core.sys.posix.termios;

    termios mode;
    if (tcgetattr(fd, &mode) == 0) {
        mode.c_lflag = mode.c_lflag & ~(ECHO | ICANON);
        mode.c_cc[VMIN] = 1;
        mode.c_cc[VTIME] = 0;
        tcsetattr(fd, TCSAFLUSH, &mode);
    }
}
