// Run a command with a wall-time limit and a resident-memory cap, then write its peak RSS
// (wait4 ru_maxrss), wall time, exit status and the reason it was killed (if any) to STATSFILE.
// Usage: rsscap STATSFILE TIMEOUT_S RSSCAP_MB cmd args...   (RSSCAP_MB 0 = no cap)
// Replaces maxrss + timeout(1): the command is exec'd in the forked child, and env, taskset and
// setarch all exec in place, so the child's pid is the benchmark's and its RSS can be polled directly
// (/proc/<pid>/statm every POLL_MS ms, default 100). SPD3 keeps a 64-byte shadow entry per byte address, so a
// tool run can outgrow the machine; the cap kills it first (SIGKILL) and the run is scored as killed=rss.
// Between polls the parent waits for SIGCHLD (sigtimedwait), so the wall time stops within microseconds of the
// child's exit rather than at the next poll.
// Exit status is the child's (128+signal if it died of one).
#define _GNU_SOURCE
#ifndef POLL_MS
#define POLL_MS 100
#endif
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

static long rss_kb(pid_t p) {
  char path[64];
  snprintf(path, sizeof path, "/proc/%d/statm", (int)p);
  FILE *f = fopen(path, "r");
  if (!f) return 0;
  long size = 0, res = 0;
  if (fscanf(f, "%ld %ld", &size, &res) != 2) res = 0;
  fclose(f);
  return res * (sysconf(_SC_PAGESIZE) / 1024);
}

int main(int argc, char **argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: rsscap STATSFILE TIMEOUT_S RSSCAP_MB cmd args...\n");
    return 2;
  }
  double limit = atof(argv[2]);
  long cap_kb = atol(argv[3]) * 1024;
  sigset_t chld, old;
  sigemptyset(&chld);
  sigaddset(&chld, SIGCHLD);
  sigprocmask(SIG_BLOCK, &chld, &old);  // blocked, so an exit before the wait stays pending
  const struct timespec poll = {POLL_MS / 1000, POLL_MS % 1000 * 1000000L};
  double t0 = now();
  pid_t p = fork();
  if (p < 0) {
    perror("fork");
    return 2;
  }
  if (p == 0) {
    sigprocmask(SIG_SETMASK, &old, NULL);  // the mask survives exec; give the command the caller's
    execvp(argv[4], argv + 4);
    perror("execvp");
    _exit(127);
  }
  const char *killed = "none";
  long peak_polled = 0;
  int st = 0;
  struct rusage ru;
  for (;;) {
    pid_t w = wait4(p, &st, WNOHANG, &ru);
    if (w == p) break;
    if (w < 0) {
      perror("wait4");
      return 2;
    }
    long r = rss_kb(p);
    if (r > peak_polled) peak_polled = r;
    if (*killed == 'n' && cap_kb > 0 && r > cap_kb) {
      killed = "rss";
      kill(p, SIGKILL);
    } else if (*killed == 'n' && now() - t0 > limit) {
      killed = "timeout";
      kill(p, SIGKILL);
    }
    sigtimedwait(&chld, NULL, &poll);
  }
  double wall = now() - t0;
  int rc = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
  FILE *f = fopen(argv[1], "w");
  if (!f) {
    perror(argv[1]);
    return 2;
  }
  fprintf(f, "wall_s %.4f\nmaxrss_kb %ld\nrc %d\nkilled %s\npolled_rss_kb %ld\n", wall, ru.ru_maxrss, rc, killed,
          peak_polled);
  fclose(f);
  return rc;
}
