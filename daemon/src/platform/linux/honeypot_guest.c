/* Guest-only listener. One connection at a time, fixed buffers, no logging of
 * peer data, filesystem lookup, subprocess, or authentication mechanism. */
#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <time.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static long long millis(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * 1000LL + now.tv_nsec / 1000000;
}

static void respond(int fd, int web) {
    const char *reply = "SSH-2.0-Hampanel_Decoy\r\n";
    if (web) {
        char buf[4097];
        size_t used = 0;
        long long deadline = millis() + 2000;
        struct pollfd peer = {.fd = fd, .events = POLLIN};
        while (used < sizeof(buf) - 1) {
            int remaining = (int)(deadline - millis());
            if (remaining <= 0 || poll(&peer, 1, remaining) <= 0) return;
            ssize_t n = recv(fd, buf + used, sizeof(buf) - 1 - used, MSG_DONTWAIT);
            if (n <= 0) return;
            used += (size_t)n;
            buf[used] = 0;
            if (strstr(buf, "\r\n\r\n")) break;
        }
        if (!strstr(buf, "\r\n\r\n")) return;
        reply = strncmp(buf, "GET / ", 6) == 0 ?
            "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<title>Service status</title><p>Service online.</p>\n" :
            "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    }
    (void)send(fd, reply, strlen(reply), MSG_NOSIGNAL | MSG_DONTWAIT);
    shutdown(fd, SHUT_WR);
}

int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "web") && strcmp(argv[1], "ssh"))) return 2;
    int web = !strcmp(argv[1], "web");
    int server = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(web ? 8080 : 2222)};
    if (server < 0 || bind(server, (void *)&addr, sizeof(addr)) || listen(server, 16)) return 1;
    puts("[decoy] listener ready"); fflush(stdout);
    for (;;) {
        int fd = accept(server, NULL, NULL);
        if (fd < 0) { if (errno == EINTR) continue; return 1; }

        respond(fd, web);
        close(fd);

    }
}
